"""Item registry: every reminder / event / saved note the agent made, its current state and history.

This is what lets a later message ("never mind", "I'll do it tomorrow") act on an earlier item:
the open items of a conversation are shown to the model with numbers it can refer to.
"""
from __future__ import annotations

import json
import time
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

from .config import Config
from .gate import normalize_handle
from .models import DB, utcnow
from .schemas import CommandResult, Event

OPEN = ("proposed", "planned", "active")
# command purpose → item status after the Mac reports done
DONE_STATUS = {"create": "active", "cancel": "cancelled"}


def chat_key(ev: Event) -> str:
    """One key per conversation. 1:1 chats key on the person (iMessage and SMS threads merge)."""
    if ev.source == "mail":
        return "mail:" + normalize_handle(ev.sender_handle)
    if ev.chat_id and ";+;" in ev.chat_id:  # group chat
        return ev.chat_id
    return normalize_handle(ev.sender_handle) or (ev.chat_id or "")


def new_item_id() -> str:
    return f"itm_{int(time.time() * 1000):013x}{uuid.uuid4().hex[:8]}"


class Items:
    def __init__(self, db: DB, cfg: Config):
        self.db = db
        self.cfg = cfg

    # ---- rows ----------------------------------------------------------------------------
    @staticmethod
    def _decode(row: dict[str, Any] | None) -> dict[str, Any] | None:
        if row:
            row["state"] = json.loads(row["state"])
        return row

    def get(self, item_id: str | None) -> dict[str, Any] | None:
        return self._decode(self.db.one("SELECT * FROM items WHERE item_id=?", (item_id,))) if item_id else None

    def create(self, *, event_id: str, seq: int, kind: str, collection: str | None, chat: str, person: str | None,
               title: str, state: dict, tag: str, status: str) -> str:
        iid = new_item_id()
        now = utcnow()
        self.db.execute(
            """INSERT INTO items (item_id, origin_event_id, seq, kind, collection, chat_key, person, title, state,
                                  tag, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (iid, event_id, seq, kind, collection, chat, person, title, json.dumps(state), tag, status, now, now),
        )
        self.log(iid, event_id, "proposed" if status == "proposed" else "planned", {"title": title})
        return iid

    def update(self, item_id: str, **fields: Any) -> None:
        if "state" in fields:
            fields["state"] = json.dumps(fields["state"])
        fields["updated_at"] = utcnow()
        cols = ", ".join(f"{k}=?" for k in fields)
        self.db.execute(f"UPDATE items SET {cols} WHERE item_id=?", (*fields.values(), item_id))

    def log(self, item_id: str, event_id: str | None, action: str, detail: Any = None) -> None:
        self.db.execute("INSERT INTO item_log (item_id, event_id, action, detail, at) VALUES (?,?,?,?,?)",
                        (item_id, event_id, action, json.dumps(detail, default=str), utcnow()))

    def history(self, item_id: str) -> list[dict[str, Any]]:
        rows = self.db.all("SELECT * FROM item_log WHERE item_id=? ORDER BY id", (item_id,))
        for r in rows:
            r["detail"] = json.loads(r["detail"]) if r["detail"] else None
        return rows

    # ---- queries -----------------------------------------------------------------------------
    def open_for(self, key: str, now: datetime) -> list[dict[str, Any]]:
        """Items a new message in this conversation may refer to, oldest first."""
        since = (now - timedelta(days=self.cfg.rules.open_item_days)).astimezone(timezone.utc).isoformat()
        rows = self.db.all(
            f"""SELECT * FROM items WHERE chat_key=? AND status IN ({",".join("?" * len(OPEN))})
                AND updated_at >= ? ORDER BY created_at LIMIT 25""",
            (key, *OPEN, since),
        )
        return [self._decode(r) for r in rows]

    def listing(self, *, statuses: tuple[str, ...] = ("planned", "active", "completed"),
                collection: str | None | bool = False, limit: int = 500) -> list[dict[str, Any]]:
        """collection=False → all; None → to-dos/events only; "key" → that collection; True → any collection."""
        where = [f"status IN ({','.join('?' * len(statuses))})"]
        params: list[Any] = list(statuses)
        if collection is None:
            where.append("collection IS NULL")
        elif collection is True:
            where.append("collection IS NOT NULL")
        elif collection:
            where.append("collection = ?")
            params.append(collection)
        rows = self.db.all(f"SELECT * FROM items WHERE {' AND '.join(where)} ORDER BY created_at DESC LIMIT ?",
                           (*params, limit))
        return [self._decode(r) for r in rows]

    # ---- command results ------------------------------------------------------------------------
    def on_result(self, cmd: dict[str, Any], res: CommandResult) -> None:
        item = self.get(cmd.get("item_id"))
        if not item:
            return
        purpose = cmd.get("purpose") or "create"
        if res.status == "failed":
            if purpose == "create":
                self.update(item["item_id"], status="failed")
            self.log(item["item_id"], cmd["event_id"], "failed", {"op": cmd["op"], "error": res.error})
            return
        fields: dict[str, Any] = {}
        if res.apple_item_id and cmd["op"] != "delete_item":
            fields["apple_item_id"] = res.apple_item_id
        meta = cmd.get("meta") or {}
        if purpose in ("update", "complete") or (purpose == "undo" and cmd["op"] == "update_item"):
            changes = cmd["payload"].get("changes", {})
            state = {**item["state"], **{k: v for k, v in changes.items() if k != "completed"}}
            fields["state"] = state
            if "title" in changes:
                fields["title"] = changes["title"]
            if "completed" in changes:
                fields["status"] = "completed" if changes["completed"] else "active"
            action = {"complete": "completed", "update": "updated"}.get(purpose, "restored")
            self.log(item["item_id"], cmd["event_id"], action, {"changes": changes})
        elif purpose == "undo" and cmd["op"] == "delete_item":
            fields["status"] = "undone"
            self.log(item["item_id"], cmd["event_id"], "undone", None)
        elif purpose == "undo":  # re-created after an undone cancel
            fields["status"] = "active"
            self.log(item["item_id"], cmd["event_id"], "restored", None)
        else:
            fields["status"] = DONE_STATUS.get(purpose, item["status"])
            self.log(item["item_id"], cmd["event_id"], {"create": "created", "cancel": "cancelled"}[purpose],
                     {"via": meta.get("why")} if meta.get("why") else None)
        self.update(item["item_id"], **fields)

    # ---- migration ------------------------------------------------------------------------------
    def backfill(self) -> int:
        """v0.2 → v0.3: build registry rows for items created before it existed."""
        if self.db.kv_get("items_backfilled"):
            return 0
        n = 0
        rows = self.db.all("""SELECT c.*, e.sender_handle, e.chat_id, e.source, e.sender_label, e.generation AS egen
                              FROM commands c JOIN events e ON e.event_id=c.event_id
                              WHERE c.op IN ('create_reminder','create_event') AND c.item_id IS NULL
                              ORDER BY c.rowid""")
        for r in rows:
            p = json.loads(r["payload"])
            undone = self.db.one("SELECT 1 FROM commands WHERE undo_of=? AND status='done'", (r["command_id"],))
            status = ("undone" if undone else {"done": "active", "failed": "failed", "held": "proposed",
                                               "cancelled": "rejected"}.get(r["status"], "planned"))
            ev = Event(event_id=r["event_id"], source=r["source"], sender_handle=r["sender_handle"] or "",
                       chat_id=r["chat_id"], received_at=datetime.now(timezone.utc), text="x")
            kind = "reminder" if r["op"] == "create_reminder" else "event"
            iid = self.create(event_id=r["event_id"], seq=r["seq"], kind=kind, collection=None, chat=chat_key(ev),
                              person=r["sender_label"], title=p.get("title", ""), state=state_from_payload(r["op"], p),
                              tag=p.get("tag", ""), status=status)
            if r["apple_item_id"]:
                self.update(iid, apple_item_id=r["apple_item_id"])
            self.db.update_command(r["command_id"], item_id=iid)
            n += 1
        self.db.kv_set("items_backfilled", True)
        return n


STATE_KEYS = ("list", "calendar", "due", "due_time", "alert", "start", "end", "all_day", "location", "url",
              "notes", "alert_minutes_before", "create_list_if_missing")


def state_from_payload(op: str, payload: dict[str, Any]) -> dict[str, Any]:
    return {k: payload[k] for k in STATE_KEYS if k in payload}


def create_payload(item: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """Rebuild a create command from an item (used to restore an item whose cancel was undone)."""
    st = item["state"]
    if item["kind"] == "reminder":
        keys = ("list", "create_list_if_missing", "due", "due_time", "alert", "notes", "url")
        return "create_reminder", {"title": item["title"], **{k: st.get(k) for k in keys}, "tag": item["tag"]}
    keys = ("calendar", "start", "end", "all_day", "location", "alert_minutes_before", "notes", "url")
    return "create_event", {"title": item["title"], **{k: st.get(k) for k in keys}, "tag": item["tag"]}
