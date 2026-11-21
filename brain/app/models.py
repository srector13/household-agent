"""SQLite storage: events, per-step trace log, command queue, alerts, key/value state."""
from __future__ import annotations

import json
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL,
    sender_handle TEXT,
    sender_label TEXT,
    chat_id TEXT,
    is_from_me INTEGER NOT NULL DEFAULT 0,
    received_at TEXT NOT NULL,
    subject TEXT,
    text TEXT NOT NULL,
    recent_context TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL,
    reason TEXT,
    prompt_version TEXT,
    extraction TEXT,
    confidence REAL,
    actionable INTEGER,
    extract_ms INTEGER,
    attempts INTEGER NOT NULL DEFAULT 0,
    generation INTEGER NOT NULL DEFAULT 0,   -- bumped by retry / reprocess
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_status ON events(status);
CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at);

CREATE TABLE IF NOT EXISTS trace (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL,
    step TEXT NOT NULL,
    data TEXT,
    duration_ms INTEGER,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trace_event ON trace(event_id);

CREATE TABLE IF NOT EXISTS commands (
    command_id TEXT PRIMARY KEY,
    event_id TEXT NOT NULL,
    seq INTEGER NOT NULL DEFAULT 0,
    generation INTEGER NOT NULL DEFAULT 0,
    op TEXT NOT NULL,
    payload TEXT NOT NULL,
    status TEXT NOT NULL,          -- held | pending | sent | done | failed | cancelled
    apple_item_id TEXT,
    error TEXT,
    undo_of TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    sent_at TEXT,
    completed_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_commands_status ON commands(status);
CREATE INDEX IF NOT EXISTS idx_commands_event ON commands(event_id);

CREATE TABLE IF NOT EXISTS alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    message TEXT NOT NULL,
    delivered INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS items (
    item_id TEXT PRIMARY KEY,
    origin_event_id TEXT NOT NULL,
    seq INTEGER NOT NULL DEFAULT 0,
    kind TEXT NOT NULL,              -- reminder | event
    collection TEXT,                 -- null = a to-do / calendar event
    chat_key TEXT,                   -- conversation it belongs to (handle, group chat id, or mail sender)
    person TEXT,
    title TEXT NOT NULL,
    state TEXT NOT NULL,             -- current fields (list/calendar, due, alert, start, end, url, notes…)
    tag TEXT NOT NULL,
    apple_item_id TEXT,
    status TEXT NOT NULL,            -- proposed | planned | active | completed | cancelled | undone | rejected | failed
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_items_chat ON items(chat_key, status);

CREATE TABLE IF NOT EXISTS item_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id TEXT NOT NULL,
    event_id TEXT,
    action TEXT NOT NULL,            -- created | updated | completed | cancelled | undone | restored | failed …
    detail TEXT,
    at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_item_log_item ON item_log(item_id);

CREATE TABLE IF NOT EXISTS kv (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

# Event statuses
RECEIVED = "received"        # stored, waiting for extraction (also: LLM was unreachable)
SKIPPED = "skipped"          # gate or model said not actionable
NEEDS_REVIEW = "needs_review"
QUEUED = "queued"            # commands waiting for the mac-agent
DONE = "done"
FAILED = "failed"
REJECTED = "rejected"
UNDOING = "undoing"
UNDONE = "undone"

TERMINAL_OK = {DONE, SKIPPED, UNDONE, REJECTED}


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def new_command_id() -> str:
    # time-ordered, ULID-ish
    return f"cmd_{int(time.time() * 1000):013x}{uuid.uuid4().hex[:12]}"


class DB:
    def __init__(self, path: str):
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock:
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.execute("PRAGMA foreign_keys=ON")
            self.conn.executescript(SCHEMA)
            self._migrate()

    def _migrate(self) -> None:
        icols = {r[1] for r in self.conn.execute("PRAGMA table_info(items)")}
        if "category" not in icols:   # todo | event | collection | promise | waiting
            self.conn.execute("ALTER TABLE items ADD COLUMN category TEXT")
            self.conn.execute("""UPDATE items SET category = CASE WHEN collection IS NOT NULL THEN 'collection'
                                 WHEN kind='event' THEN 'event' ELSE 'todo' END""")
        if "missing" not in icols:    # consecutive completion-sync reports saying it's gone
            self.conn.execute("ALTER TABLE items ADD COLUMN missing INTEGER NOT NULL DEFAULT 0")
        if "completed_at" not in icols:
            self.conn.execute("ALTER TABLE items ADD COLUMN completed_at TEXT")
        ecols = {r[1] for r in self.conn.execute("PRAGMA table_info(events)")}
        if "open_refs" not in ecols:
            self.conn.execute("ALTER TABLE events ADD COLUMN open_refs TEXT")
        cols = {r[1] for r in self.conn.execute("PRAGMA table_info(commands)")}
        for col, ddl in (("item_id", "TEXT"), ("purpose", "TEXT NOT NULL DEFAULT 'create'"), ("meta", "TEXT")):
            if col not in cols:
                self.conn.execute(f"ALTER TABLE commands ADD COLUMN {col} {ddl}")
        if "purpose" not in cols:
            # v0.2 rows: delete_item was only ever used for undo / start-over.
            self.conn.execute("UPDATE commands SET purpose='undo' WHERE undo_of IS NOT NULL")

    # ---- low level -------------------------------------------------------
    def execute(self, sql: str, params: tuple | dict = ()) -> sqlite3.Cursor:
        with self.lock:
            return self.conn.execute(sql, params)

    def one(self, sql: str, params: tuple | dict = ()) -> dict[str, Any] | None:
        with self.lock:
            row = self.conn.execute(sql, params).fetchone()
        return dict(row) if row else None

    def all(self, sql: str, params: tuple | dict = ()) -> list[dict[str, Any]]:
        with self.lock:
            return [dict(r) for r in self.conn.execute(sql, params).fetchall()]

    # ---- events ------------------------------------------------------------
    def insert_event(self, ev: dict[str, Any], status: str) -> bool:
        """Insert; returns False if event_id already exists (idempotency)."""
        now = utcnow()
        with self.lock:
            cur = self.conn.execute(
                """INSERT OR IGNORE INTO events
                (event_id, source, sender_handle, sender_label, chat_id, is_from_me, received_at,
                 subject, text, recent_context, status, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    ev["event_id"], ev["source"], ev.get("sender_handle"), ev.get("sender_label"),
                    ev.get("chat_id"), int(bool(ev.get("is_from_me"))), ev["received_at"],
                    ev.get("subject"), ev["text"], json.dumps(ev.get("recent_context") or []),
                    status, now, now,
                ),
            )
            return cur.rowcount == 1

    def get_event(self, event_id: str) -> dict[str, Any] | None:
        row = self.one("SELECT * FROM events WHERE event_id=?", (event_id,))
        if row:
            row["recent_context"] = json.loads(row["recent_context"] or "[]")
            row["extraction"] = json.loads(row["extraction"]) if row["extraction"] else None
        return row

    def update_event(self, event_id: str, **fields: Any) -> None:
        if not fields:
            return
        fields["updated_at"] = utcnow()
        if "extraction" in fields and not isinstance(fields["extraction"], (str, type(None))):
            fields["extraction"] = json.dumps(fields["extraction"])
        cols = ", ".join(f"{k}=?" for k in fields)
        self.execute(f"UPDATE events SET {cols} WHERE event_id=?", (*fields.values(), event_id))

    def recent_events(self, limit: int = 100, status: str | None = None) -> list[dict[str, Any]]:
        if status:
            rows = self.all("SELECT * FROM events WHERE status=? ORDER BY id DESC LIMIT ?", (status, limit))
        else:
            rows = self.all("SELECT * FROM events ORDER BY id DESC LIMIT ?", (limit,))
        for r in rows:
            r["recent_context"] = json.loads(r["recent_context"] or "[]")
            r["extraction"] = json.loads(r["extraction"]) if r["extraction"] else None
        return rows

    # ---- trace -------------------------------------------------------------
    def trace(self, event_id: str, step: str, data: Any = None, duration_ms: int | None = None) -> None:
        self.execute(
            "INSERT INTO trace (event_id, step, data, duration_ms, created_at) VALUES (?,?,?,?,?)",
            (event_id, step, json.dumps(data, default=str) if data is not None else None, duration_ms, utcnow()),
        )

    def get_trace(self, event_id: str) -> list[dict[str, Any]]:
        rows = self.all("SELECT * FROM trace WHERE event_id=? ORDER BY id", (event_id,))
        for r in rows:
            r["data"] = json.loads(r["data"]) if r["data"] else None
        return rows

    # ---- commands ------------------------------------------------------------
    def insert_command(
        self, event_id: str, op: str, payload: dict, status: str, seq: int = 0,
        undo_of: str | None = None, generation: int = 0, item_id: str | None = None,
        purpose: str = "create", meta: dict | None = None,
    ) -> str:
        cid = new_command_id()
        self.execute(
            """INSERT INTO commands (command_id, event_id, seq, generation, op, payload, status, undo_of, created_at,
                                     item_id, purpose, meta)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
            (cid, event_id, seq, generation, op, json.dumps(payload), status, undo_of, utcnow(),
             item_id, purpose, json.dumps(meta) if meta is not None else None),
        )
        return cid

    def get_command(self, command_id: str) -> dict[str, Any] | None:
        row = self.one("SELECT * FROM commands WHERE command_id=?", (command_id,))
        if row:
            row["payload"] = json.loads(row["payload"])
            row["meta"] = json.loads(row["meta"]) if row.get("meta") else None
        return row

    def commands_for_event(self, event_id: str) -> list[dict[str, Any]]:
        rows = self.all("SELECT * FROM commands WHERE event_id=? ORDER BY rowid", (event_id,))
        for r in rows:
            r["payload"] = json.loads(r["payload"])
            r["meta"] = json.loads(r["meta"]) if r.get("meta") else None
        return rows

    def update_command(self, command_id: str, **fields: Any) -> None:
        cols = ", ".join(f"{k}=?" for k in fields)
        self.execute(f"UPDATE commands SET {cols} WHERE command_id=?", (*fields.values(), command_id))

    # ---- kv ------------------------------------------------------------------
    def kv_get(self, key: str, default: Any = None) -> Any:
        row = self.one("SELECT value FROM kv WHERE key=?", (key,))
        return json.loads(row["value"]) if row else default

    def kv_set(self, key: str, value: Any) -> None:
        self.execute(
            "INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, json.dumps(value, default=str)),
        )

    # ---- alerts -------------------------------------------------------------
    def insert_alert(self, kind: str, message: str, delivered: bool) -> None:
        self.execute(
            "INSERT INTO alerts (kind, message, delivered, created_at) VALUES (?,?,?,?)",
            (kind, message, int(delivered), utcnow()),
        )

    # ---- maintenance ----------------------------------------------------------
    def backup(self, dest: str) -> None:
        Path(dest).parent.mkdir(parents=True, exist_ok=True)
        target = sqlite3.connect(dest)
        try:
            with self.lock:
                self.conn.backup(target)
        finally:
            target.close()
