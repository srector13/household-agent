"""IMAP IDLE listener (phase 5): new mail from allowlisted senders → the same pipeline.

One thread per folder (IDLE watches a single selected mailbox). Messages are fetched with
BODY.PEEK so nothing is marked read. On first run (or UIDVALIDITY change) we start from the
newest UID — no backfill.
"""
from __future__ import annotations

import asyncio
import email
import email.policy
import hashlib
import html
import logging
import re
import threading
import time
from datetime import datetime, timezone
from email.message import EmailMessage
from email.utils import parseaddr, parsedate_to_datetime
from html.parser import HTMLParser
from typing import Any

from .config import Config
from .gate import allowlist_label
from .models import DB
from .schemas import Event

log = logging.getLogger("brain.mail")
IDLE_RENEW_S = 20 * 60
MAX_TEXT = 4000


# ---- parsing (pure functions, unit-tested) ---------------------------------------
class _HTMLText(HTMLParser):
    BLOCK = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "table", "blockquote"}

    def __init__(self) -> None:
        super().__init__()
        self.out: list[str] = []
        self.skip = 0
        self.quote_depth = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("style", "script", "head"):
            self.skip += 1
        if tag == "blockquote" or "gmail_quote" in (a.get("class") or "") or a.get("id") == "divRplyFwdMsg":
            self.quote_depth += 1
        if tag in self.BLOCK:
            self.out.append("\n")

    def handle_endtag(self, tag):
        if tag in ("style", "script", "head"):
            self.skip = max(0, self.skip - 1)
        if tag == "blockquote":
            self.quote_depth = max(0, self.quote_depth - 1)
        if tag in self.BLOCK:
            self.out.append("\n")

    def handle_data(self, data):
        if not self.skip and not self.quote_depth:
            self.out.append(data)


def html_to_text(s: str) -> str:
    p = _HTMLText()
    p.feed(s)
    text = html.unescape("".join(p.out))
    text = re.sub(r"[ \t\xa0]+", " ", text)
    return re.sub(r"\n\s*\n+", "\n\n", text).strip()


QUOTE_HEADERS = [
    re.compile(r"^On .{5,200}(wrote|écrit|schrieb):?\s*$", re.I),
    re.compile(r"^-{2,}\s*Original Message\s*-{2,}", re.I),
    re.compile(r"^-{2,}\s*Forwarded message\s*-{2,}", re.I),
    re.compile(r"^From:\s.+", re.I),  # Outlook-style reply header block
    re.compile(r"^_{10,}\s*$"),
]
SIGNATURE = [
    re.compile(r"^--\s*$"),
    re.compile(r"^Sent from my (iPhone|iPad|Android|mobile)", re.I),
    re.compile(r"^Get Outlook for ", re.I),
]


def strip_quoted(text: str) -> str:
    lines = text.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith(">"):
            continue
        if any(p.match(s) for p in SIGNATURE):
            break
        # A "From:" line only starts a quote block if followed by Sent:/Date: soon after.
        if QUOTE_HEADERS[3].match(s):
            nxt = " ".join(l.strip() for l in lines[i + 1:i + 4])
            if re.search(r"\b(Sent|Date):", nxt, re.I):
                break
            out.append(line)
            continue
        if any(p.match(s) for j, p in enumerate(QUOTE_HEADERS) if j != 3):
            break
        out.append(line)
    text = "\n".join(out)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return text[:MAX_TEXT]


def _body_text(msg: EmailMessage) -> str:
    part = msg.get_body(preferencelist=("plain",))
    if part is not None:
        try:
            return part.get_content()
        except (LookupError, UnicodeDecodeError):
            pass
    part = msg.get_body(preferencelist=("html",))
    if part is not None:
        try:
            return html_to_text(part.get_content())
        except (LookupError, UnicodeDecodeError):
            pass
    return ""


def parse_message(raw: bytes, *, fallback_id: str) -> dict[str, Any]:
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    assert isinstance(msg, EmailMessage)
    sender = parseaddr(str(msg.get("From", "")))[1].lower()
    mid = str(msg.get("Message-ID", "")).strip().strip("<>")
    mid = re.sub(r"[^\w.@+\-=]", "", mid)[:200]
    try:
        received = parsedate_to_datetime(str(msg["Date"])) if msg.get("Date") else None
    except (TypeError, ValueError):
        received = None
    if received is None or received.tzinfo is None:
        received = datetime.now(timezone.utc)
    return {
        "event_id": f"mail:{mid or hashlib.sha1(fallback_id.encode()).hexdigest()[:20]}",
        "sender": sender,
        "subject": str(msg.get("Subject", "")).strip() or None,
        "received_at": received,
        "text": strip_quoted(_body_text(msg)),
    }


# ---- listener -------------------------------------------------------------------------
class MailListener:
    def __init__(self, cfg: Config, db: DB, pipeline, health, loop: asyncio.AbstractEventLoop):
        self.cfg = cfg
        self.mc = cfg.watch.mail
        self.db = db
        self.pipeline = pipeline
        self.health = health
        self.loop = loop
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._clients: dict[str, Any] = {}
        health.mail_status = {"enabled": True, "state": "starting", "folders": {}}

    def start(self) -> None:
        for folder in self.mc.folders:
            t = threading.Thread(target=self._run, args=(folder,), name=f"imap-{folder}", daemon=True)
            t.start()
            self._threads.append(t)

    def stop(self) -> None:
        self._stop.set()
        for c in list(self._clients.values()):
            try:
                c.idle_done()
            except Exception:  # noqa: BLE001
                pass

    def _status(self, folder: str, state: str, error: str | None = None) -> None:
        st = self.health.mail_status
        st["folders"][folder] = {"state": state, "error": error, "at": time.time()}
        states = {f["state"] for f in st["folders"].values()}
        st["state"] = "error" if "error" in states else ("idle" if states == {"idle"} else state)
        st["error"] = error

    def _run(self, folder: str) -> None:
        backoff = 5
        while not self._stop.is_set():
            try:
                self._session(folder)
                backoff = 5
            except Exception as e:  # noqa: BLE001 — reconnect on any drop
                log.warning("IMAP %s: %r — reconnecting in %ss", folder, e, backoff)
                self._status(folder, "error", repr(e)[:300])
                self._stop.wait(backoff)
                backoff = min(backoff * 2, 300)

    def _session(self, folder: str) -> None:
        from imapclient import IMAPClient

        self._status(folder, "connecting")
        with IMAPClient(self.mc.host, port=self.mc.port, ssl=True, timeout=60) as c:
            self._clients[folder] = c
            c.login(self.mc.username, self.mc.password or "")
            info = c.select_folder(folder, readonly=True)
            uidvalidity = int(info[b"UIDVALIDITY"])
            key = f"mail:{folder}"
            state = self.db.kv_get(key)
            if not state or state.get("uidvalidity") != uidvalidity:
                uids = c.search(["ALL"])
                state = {"uidvalidity": uidvalidity, "last_uid": max(uids) if uids else 0}
                self.db.kv_set(key, state)
                log.info("IMAP %s: starting after UID %s (no backfill)", folder, state["last_uid"])
            self._fetch_new(c, folder, key, state)
            while not self._stop.is_set():
                self._status(folder, "idle")
                c.idle()
                started = time.time()
                try:
                    responses: list = []
                    while not self._stop.is_set() and time.time() - started < IDLE_RENEW_S:
                        responses = c.idle_check(timeout=30)
                        if any(r[1] == b"EXISTS" for r in responses if isinstance(r, tuple) and len(r) > 1):
                            break
                finally:
                    c.idle_done()
                self._fetch_new(c, folder, key, state)

    def _fetch_new(self, c, folder: str, key: str, state: dict[str, Any]) -> None:
        uids = [u for u in c.search(["UID", f"{state['last_uid'] + 1}:*"]) if u > state["last_uid"]]
        if not uids:
            return
        envs = c.fetch(uids, ["ENVELOPE"])
        for uid in sorted(uids):
            env = envs.get(uid, {}).get(b"ENVELOPE")
            sender = ""
            if env and env.from_:
                a = env.from_[0]
                sender = f"{(a.mailbox or b'').decode(errors='replace')}@{(a.host or b'').decode(errors='replace')}".lower()
            probe = Event(event_id="probe", source="mail", sender_handle=sender,
                          received_at=datetime.now(timezone.utc), text="")
            if allowlist_label(self.cfg, probe)[0]:
                raw = c.fetch([uid], ["BODY.PEEK[]"])[uid][b"BODY[]"]
                self._submit(raw, fallback_id=f"{folder}:{state['uidvalidity']}:{uid}")
            state["last_uid"] = uid
            self.db.kv_set(key, state)

    def _submit(self, raw: bytes, *, fallback_id: str) -> None:
        m = parse_message(raw, fallback_id=fallback_id)
        if not m["text"] and not m["subject"]:
            return
        ev = Event(event_id=m["event_id"], source="mail", sender_handle=m["sender"],
                   received_at=m["received_at"], text=m["text"] or m["subject"] or "", subject=m["subject"])
        fut = asyncio.run_coroutine_threadsafe(self.pipeline.ingest(ev), self.loop)
        res = fut.result(timeout=60)
        self.health.mail_status["last_message_at"] = datetime.now(timezone.utc).isoformat()
        log.info("mail %s → %s", m["event_id"], res.get("status"))
