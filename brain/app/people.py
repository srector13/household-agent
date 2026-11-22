"""People: contact photos (from the Mac's Contacts) and one page per person."""
from __future__ import annotations

import base64
import hashlib
import json
import re
from datetime import datetime, timezone
from typing import Any

from pydantic import BaseModel, Field

from .config import Config
from .gate import normalize_handle
from .models import DB, utcnow

SCHEMA = """
CREATE TABLE IF NOT EXISTS avatars (
    handle TEXT PRIMARY KEY,
    key TEXT NOT NULL,
    name TEXT,
    image BLOB,
    image_hash TEXT,
    updated_at TEXT NOT NULL
);
"""
MAX_IMAGE = 200 * 1024


class AvatarIn(BaseModel):
    handle: str
    name: str | None = None
    image: str | None = None      # base64 JPEG
    image_hash: str | None = None


class AvatarReport(BaseModel):
    people: list[AvatarIn] = Field(default_factory=list, max_length=200)


def key_for(s: str) -> str:
    return hashlib.sha1(s.encode()).hexdigest()[:16]


def slug(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-") or "someone"


class People:
    def __init__(self, cfg: Config, db: DB):
        self.cfg = cfg
        self.db = db
        with db.lock:
            db.conn.executescript(SCHEMA)
        self._cache: dict[str, dict] | None = None

    # ---- avatars ------------------------------------------------------------------------------
    def store_avatars(self, report: AvatarReport) -> int:
        n = 0
        for p in report.people:
            h = normalize_handle(p.handle)
            img = None
            if p.image:
                try:
                    img = base64.b64decode(p.image, validate=True)
                except ValueError:
                    img = None
                if img and (len(img) > MAX_IMAGE or not img[:3] == b"\xff\xd8\xff"):
                    img = None  # only reasonably sized JPEGs
            self.db.execute(
                """INSERT INTO avatars (handle, key, name, image, image_hash, updated_at) VALUES (?,?,?,?,?,?)
                   ON CONFLICT(handle) DO UPDATE SET name=excluded.name, image=excluded.image,
                   image_hash=excluded.image_hash, updated_at=excluded.updated_at""",
                (h, key_for(h), (p.name or "").strip() or None, img, p.image_hash if img else None, utcnow()))
            n += 1
        self._cache = None
        return n

    def _avatars(self) -> dict[str, dict]:
        if self._cache is None:
            rows = self.db.all("SELECT handle, key, name, image IS NOT NULL AS has_image, image_hash FROM avatars")
            self._cache = {r["handle"]: r for r in rows}
        return self._cache

    def image(self, key: str) -> tuple[bytes, str] | None:
        row = self.db.one("SELECT image, image_hash FROM avatars WHERE key=? AND image IS NOT NULL", (key,))
        return (row["image"], row["image_hash"] or "") if row else None

    def avatar_url(self, handle: str | None) -> str | None:
        if not handle:
            return None
        a = self._avatars().get(normalize_handle(handle))
        return f"/avatars/{a['key']}.jpg?v={(a['image_hash'] or '')[:8]}" if a and a["has_image"] else None

    def contact_name(self, handle: str | None) -> str | None:
        a = self._avatars().get(normalize_handle(handle)) if handle else None
        return a["name"] if a else None

    def photo_for_label(self, label: str | None) -> str | None:
        for e in self.cfg.watch.imessage.allow:
            if e.label == label and e.handle:
                return self.avatar_url(e.handle)
        return None

    # ---- people ---------------------------------------------------------------------------------
    def roster(self) -> list[dict[str, Any]]:
        """Everyone you watch, plus people who only come up in items (e.g. "Mom" in a gift idea)."""
        out, labels = [], set()
        for e in self.cfg.watch.imessage.allow:
            if e.is_me:
                continue
            ident = e.handle or e.chat_id or e.label or "?"
            label = e.label or self.contact_name(e.handle) or e.handle or e.chat_id
            labels.add(label)
            out.append({"key": ("h-" if e.handle else "c-") + key_for(normalize_handle(e.handle) if e.handle else ident),
                        "label": label, "handle": e.handle, "chat_id": e.chat_id, "group": bool(e.chat_id),
                        "photo": self.avatar_url(e.handle), "contact_name": self.contact_name(e.handle),
                        "enabled": e.enabled})
        for r in self.db.all("""SELECT person, COUNT(*) n FROM items WHERE person IS NOT NULL AND person != 'Me'
                                AND status IN ('planned','active','completed') GROUP BY person ORDER BY n DESC"""):
            if r["person"] not in labels:
                labels.add(r["person"])
                out.append({"key": "p-" + slug(r["person"]), "label": r["person"], "handle": None, "chat_id": None,
                            "group": False, "photo": None, "contact_name": None, "enabled": True, "mentioned": True})
        for p in out:
            p.update(self._counts(p["label"]))
            p["last"] = self._last_message(p)
        out.sort(key=lambda p: (p.get("mentioned", False), -(datetime.fromisoformat(p["last"]).timestamp() if p["last"] else 0)))
        return out

    def _counts(self, label: str) -> dict[str, int]:
        rows = self.db.all("""SELECT category, collection, COUNT(*) n FROM items WHERE person=? AND status IN ('planned','active')
                              GROUP BY category, collection""", (label,))
        c = {"promises": 0, "waiting": 0, "gifts": 0, "facts": 0, "todos": 0}
        for r in rows:
            if r["collection"] == "gift_ideas":
                c["gifts"] += r["n"]
            elif r["collection"] == "about_person":
                c["facts"] += r["n"]
            elif r["category"] == "promise":
                c["promises"] += r["n"]
            elif r["category"] == "waiting":
                c["waiting"] += r["n"]
            elif r["category"] in ("todo", "event"):
                c["todos"] += r["n"]
        return c

    def _messages_sql(self, p: dict) -> tuple[str, tuple] | None:
        if p.get("chat_id"):
            return "chat_id = ?", (p["chat_id"],)
        if p.get("handle"):
            h = normalize_handle(p["handle"])
            # handles are stored as sent by the agent; match the common formats
            return "(sender_handle = ? OR sender_handle = ? OR sender_handle = ?)", (h, h.lstrip("+"), h[2:] if h.startswith("+1") else h)
        return None

    def _last_message(self, p: dict) -> str | None:
        q = self._messages_sql(p)
        if not q:
            return None
        row = self.db.one(f"SELECT MAX(received_at) t FROM events WHERE {q[0]}", q[1])
        return row["t"] if row else None

    def find(self, key: str) -> dict[str, Any] | None:
        return next((p for p in self.roster() if p["key"] == key), None)

    def detail(self, p: dict[str, Any], items) -> dict[str, Any]:
        label = p["label"]

        def q(where: str, params: tuple = (), statuses=("planned", "active")) -> list[dict]:
            rows = self.db.all(f"""SELECT * FROM items WHERE person=? AND status IN ({','.join('?' * len(statuses))})
                                   AND {where} ORDER BY created_at DESC LIMIT 50""", (label, *statuses, *params))
            return [items._decode(r) for r in rows]

        other_cols = q("collection IS NOT NULL AND collection NOT IN ('gift_ideas','about_person')")
        msgs = []
        mq = self._messages_sql(p)
        if mq:
            msgs = self.db.all(f"""SELECT event_id, text, is_from_me, received_at, status, subject FROM events
                                   WHERE {mq[0]} ORDER BY id DESC LIMIT 15""", mq[1])
        return {
            "promises": q("category='promise'"),
            "waiting": q("category='waiting'"),
            "todos": q("category IN ('todo','event') AND collection IS NULL"),
            "gifts": q("collection='gift_ideas'"),
            "facts": q("collection='about_person'"),
            "other": other_cols,
            "done": q("collection IS NULL", (), statuses=("completed",))[:8],
            "messages": msgs,
        }
