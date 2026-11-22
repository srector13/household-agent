"""Web Push (VAPID) to the installed iPhone app — iOS 16.4+ home-screen web apps over HTTPS.

Notifications replace Discord for day-to-day things: the morning three, the evening recap,
review requests, follow-ups, new items, the weekly review, and "something broke".
Each push may also set the app-icon badge.
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
from datetime import datetime, timezone
from typing import Any, Callable
from urllib.parse import urlparse

from .config import Config
from .models import DB, utcnow

log = logging.getLogger("brain.push")

SCHEMA = """
CREATE TABLE IF NOT EXISTS push_subs (
    endpoint TEXT PRIMARY KEY,
    keys TEXT NOT NULL,
    user_agent TEXT,
    created_at TEXT NOT NULL,
    last_ok TEXT,
    failures INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS push_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL, title TEXT, body TEXT, sent INTEGER NOT NULL DEFAULT 0, skipped TEXT, at TEXT NOT NULL
);
"""
# kinds that may interrupt during quiet hours (problems you'd want to know about now)
URGENT = {"system", "focus"}  # bypass quiet hours (focus: you started the timer)


def _b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


class Push:
    def __init__(self, cfg: Config, db: DB, sender: Callable | None = None):
        self.cfg = cfg
        self.db = db
        with db.lock:
            db.conn.executescript(SCHEMA)
            cols = {r[1] for r in db.conn.execute("PRAGMA table_info(push_log)")}
            if "url" not in cols:  # v0.9 → v0.10: the app's notification feed opens the right screen
                db.conn.execute("ALTER TABLE push_log ADD COLUMN url TEXT")
        self._sender = sender  # injectable for tests: (subscription, data, private_pem, claims) -> status code
        self.badge_fn: Callable[[], int] | None = None
        self._pending: dict[str, dict[str, Any]] = {}
        self._keys()

    # ---- keys ------------------------------------------------------------------------------
    def _keys(self) -> dict[str, str]:
        keys = self.db.kv_get("vapid")
        if keys:
            return keys
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        priv = ec.generate_private_key(ec.SECP256R1())
        pem = priv.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                 serialization.NoEncryption()).decode()
        pub = priv.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        keys = {"private_pem": pem, "public_key": _b64url(pub)}
        self.db.kv_set("vapid", keys)
        return keys

    @property
    def public_key(self) -> str:
        return self._keys()["public_key"]

    def _claims(self) -> dict[str, str]:
        url = self.cfg.dashboard.public_url
        sub = url if urlparse(url).scheme == "https" else "mailto:second-brain@example.com"
        return {"sub": sub}

    # ---- subscriptions -------------------------------------------------------------------------
    def subscribe(self, sub: dict[str, Any], user_agent: str | None) -> None:
        endpoint = sub.get("endpoint")
        keys = sub.get("keys") or {}
        if not endpoint or not keys.get("p256dh") or not keys.get("auth"):
            raise ValueError("invalid subscription")
        self.db.execute(
            """INSERT INTO push_subs (endpoint, keys, user_agent, created_at) VALUES (?,?,?,?)
               ON CONFLICT(endpoint) DO UPDATE SET keys=excluded.keys, failures=0""",
            (endpoint, json.dumps(keys), (user_agent or "")[:200], utcnow()))

    def unsubscribe(self, endpoint: str | None = None) -> None:
        if endpoint:
            self.db.execute("DELETE FROM push_subs WHERE endpoint=?", (endpoint,))
        else:
            self.db.execute("DELETE FROM push_subs")

    def devices(self) -> list[dict[str, Any]]:
        return self.db.all("SELECT endpoint, user_agent, created_at, last_ok, failures FROM push_subs ORDER BY created_at")

    # ---- sending -------------------------------------------------------------------------------
    def _quiet(self) -> bool:
        p = self.cfg.push
        if not p.quiet_start or not p.quiet_end:
            return False
        hm = datetime.now(self.cfg.tz).strftime("%H:%M")
        return (p.quiet_start <= hm or hm < p.quiet_end) if p.quiet_start > p.quiet_end else (p.quiet_start <= hm < p.quiet_end)

    def _allowed(self, kind: str) -> str | None:
        p = self.cfg.push
        if not p.enabled:
            return "push off"
        if kind != "test" and not getattr(p, kind, True):
            return f"{kind} notifications off"
        if kind not in URGENT and kind != "test" and self._quiet():
            return "quiet hours"
        return None

    async def send(self, kind: str, title: str, body: str, *, url: str = "/", tag: str | None = None) -> int:
        """Send to every subscribed device. Returns how many accepted it."""
        skip = self._allowed(kind)
        subs = self.db.all("SELECT * FROM push_subs")
        if skip or not subs:
            self.db.execute("INSERT INTO push_log (kind, title, body, sent, skipped, at, url) VALUES (?,?,?,?,?,?,?)",
                            (kind, title, body, 0, skip or "no devices", utcnow(), url))
            return 0
        badge = None
        if self.badge_fn:
            try:
                badge = int(self.badge_fn())
            except Exception:  # noqa: BLE001
                badge = None
        payload = json.dumps({"title": title, "body": body[:240], "url": url, "tag": tag or kind, "badge": badge})
        keys = self._keys()
        ok = 0
        for s in subs:
            sub = {"endpoint": s["endpoint"], "keys": json.loads(s["keys"])}
            try:
                status = await asyncio.to_thread(self._deliver, sub, payload, keys["private_pem"])
            except Exception as e:  # noqa: BLE001
                log.warning("push to %s failed: %r", s["endpoint"][:40], e)
                status = 0
            if status in (404, 410):  # the device unsubscribed / app removed
                self.db.execute("DELETE FROM push_subs WHERE endpoint=?", (s["endpoint"],))
            elif 200 <= status < 300:
                ok += 1
                self.db.execute("UPDATE push_subs SET last_ok=?, failures=0 WHERE endpoint=?", (utcnow(), s["endpoint"]))
            else:
                self.db.execute("UPDATE push_subs SET failures=failures+1 WHERE endpoint=?", (s["endpoint"],))
        self.db.execute("INSERT INTO push_log (kind, title, body, sent, skipped, at, url) VALUES (?,?,?,?,?,?,?)",
                        (kind, title, body, ok, None, utcnow(), url))
        return ok

    def _deliver(self, sub: dict, payload: str, private_pem: str) -> int:
        if self._sender:
            return self._sender(sub, payload, private_pem, self._claims())
        from py_vapid import Vapid
        from pywebpush import WebPushException, webpush
        try:
            # pass a key object: a raw PEM string is mistaken for a file path / base64 DER by pywebpush
            r = webpush(subscription_info=sub, data=payload, vapid_private_key=Vapid.from_pem(private_pem.encode()),
                        vapid_claims=dict(self._claims()), ttl=6 * 3600, timeout=10)
            return getattr(r, "status_code", 201)
        except WebPushException as e:
            return getattr(e.response, "status_code", 0) if e.response is not None else 0

    # ---- coalescing: several items from one message → one notification ------------------------
    def added(self, event_id: str, line: str, *, url: str, title: str) -> None:
        """Queue "added X" for a message; sent ~3 s later together with its siblings."""
        p = self._pending.setdefault(event_id, {"lines": [], "title": title, "url": url, "task": None})
        p["lines"].append(line)
        if p["task"] is None:
            try:
                p["task"] = asyncio.get_running_loop().create_task(self._flush(event_id))
            except RuntimeError:
                pass

    async def _flush(self, event_id: str, delay: float = 3.0) -> None:
        await asyncio.sleep(delay)
        p = self._pending.pop(event_id, None)
        if not p:
            return
        lines = p["lines"]
        title = p["title"] if len(lines) == 1 else f"Added {len(lines)} things"
        await self.send("new_items", title, "\n".join(lines), url=p["url"], tag=f"added:{event_id}")

    def recent_log(self, limit: int = 20) -> list[dict[str, Any]]:
        return self.db.all("SELECT * FROM push_log ORDER BY id DESC LIMIT ?", (limit,))
