"""The processing pipeline: ingest → allowlist → gate → extract → plan → queue."""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Any

from . import models as m
from .commands import Bus, CommandQueue
from .config import Config
from .extract import LLMClient, LLMError, LLMUnavailable, PromptTemplate, extract
from .gate import allowlist_label, gate, sounds_like_commitment
from .heartbeat import Alerter, Health
from .items import Items, chat_key, create_payload
from .models import DB
from .planner import Plan, plan
from .schemas import Event, Extraction

log = logging.getLogger("brain.pipeline")


class ActionError(Exception):
    """User-facing error for dashboard actions."""


class Pipeline:
    def __init__(self, cfg: Config, db: DB, llm: LLMClient, queue: CommandQueue, bus: Bus,
                 alerter: Alerter, health: Health, prompt: PromptTemplate | None = None):
        self.cfg = cfg
        self.db = db
        self.llm = llm
        self.queue = queue
        self.bus = bus
        self.alerter = alerter
        self.health = health
        self.prompt = prompt or PromptTemplate.load()
        self._sem = asyncio.Semaphore(2)
        self._inflight: set[str] = set()
        self._tasks: set[asyncio.Task] = set()
        self.items = Items(db, cfg)
        queue.items = self.items
        n = self.items.backfill()
        if n:
            log.info("item registry: backfilled %d existing items", n)

    # ---- helpers ---------------------------------------------------------------
    def _set(self, event_id: str, **fields: Any) -> None:
        self.db.update_event(event_id, **fields)
        self.bus.publish({"event_id": event_id, "status": fields.get("status")})

    @staticmethod
    def row_to_event(row: dict[str, Any]) -> Event:
        return Event(
            event_id=row["event_id"], source=row["source"], sender_handle=row["sender_handle"] or "",
            sender_label=row["sender_label"], chat_id=row["chat_id"], is_from_me=bool(row["is_from_me"]),
            received_at=datetime.fromisoformat(row["received_at"]), text=row["text"],
            recent_context=row["recent_context"] if isinstance(row["recent_context"], list)
            else json.loads(row["recent_context"] or "[]"),
            subject=row.get("subject"),
        )

    def submit(self, event_id: str) -> None:
        """Process in the background."""
        t = asyncio.create_task(self.process(event_id))
        self._tasks.add(t)
        t.add_done_callback(self._tasks.discard)

    # ---- 1-3: ingest, allowlist, gate --------------------------------------------
    async def ingest(self, ev: Event, *, sync: bool = False) -> dict[str, Any]:
        allowed, label = allowlist_label(self.cfg, ev)
        if not allowed:
            # Privacy: nothing about non-allowlisted messages is stored.
            return {"status": "ignored", "event_id": ev.event_id}
        ev = ev.model_copy(update={"sender_label": label})
        if ev.received_at.tzinfo is None:
            ev = ev.model_copy(update={"received_at": ev.received_at.replace(tzinfo=self.cfg.tz)})
        data = ev.model_dump(mode="json")
        if not self.db.insert_event(data, m.RECEIVED):
            return {"status": "duplicate", "event_id": ev.event_id}
        self.db.trace(ev.event_id, "ingest", {"source": ev.source, "chars": len(ev.text),
                                              "context_lines": len(ev.recent_context)})
        self.db.trace(ev.event_id, "allowlist", {"allowed": True, "label": label})
        reason = gate(self.cfg, ev) or self._duplicate(ev)
        if reason == "from_me":
            # My own reply can still move/finish/cancel something open here, or be a new promise.
            has_open = self.cfg.rules.self_updates and bool(self.items.open_for(chat_key(ev), datetime.now(timezone.utc)))
            promise = self.cfg.rules.track_promises and sounds_like_commitment(ev.text)
            if has_open or promise:
                reason = gate(self.cfg, ev.model_copy(update={"is_from_me": False}))
        self.db.trace(ev.event_id, "gate", {"decision": "skip" if reason else "pass", "reason": reason,
                                            "from_me": ev.is_from_me})
        if reason:
            self._set(ev.event_id, status=m.SKIPPED, reason=reason)
            return {"status": "accepted", "event_id": ev.event_id, "result": m.SKIPPED, "reason": reason}
        self.bus.publish({"event_id": ev.event_id, "status": m.RECEIVED})
        if sync:
            await self.process(ev.event_id)
            row = self.db.get_event(ev.event_id)
            return {"status": "accepted", "event_id": ev.event_id, "result": row["status"], "reason": row["reason"]}
        self.submit(ev.event_id)
        return {"status": "accepted", "event_id": ev.event_id}

    def _duplicate(self, ev: Event) -> str | None:
        """Texting yourself stores the message twice (sent + received copy): skip the echo."""
        text = (ev.text or "").strip()
        if not text:
            return None
        rows = self.db.all(
            """SELECT event_id, received_at, chat_id, sender_handle FROM events
               WHERE text = ? AND event_id != ? ORDER BY id DESC LIMIT 5""", (ev.text, ev.event_id))
        for r in rows:
            same_chat = (r["chat_id"] and r["chat_id"] == ev.chat_id) or (r["sender_handle"] == ev.sender_handle)
            if same_chat and abs((datetime.fromisoformat(r["received_at"]) - ev.received_at).total_seconds()) <= 120:
                return "duplicate"
        return None

    # ---- 4-6: extract, plan, queue -------------------------------------------------
    async def process(self, event_id: str) -> None:
        if event_id in self._inflight:
            return
        self._inflight.add(event_id)
        try:
            async with self._sem:
                await self._process(event_id)
        finally:
            self._inflight.discard(event_id)

    async def _process(self, event_id: str) -> None:
        row = self.db.get_event(event_id)
        if not row or row["status"] != m.RECEIVED:
            return
        ev = self.row_to_event(row)
        self.db.update_event(event_id, attempts=row["attempts"] + 1)
        open_items = self.items.open_for(chat_key(ev), datetime.now(timezone.utc))
        try:
            # Resolve relative dates against when the message arrived, not when we got to it.
            res = await extract(self.cfg, self.llm, self.prompt, ev, ev.received_at, open_items)
        except LLMUnavailable as e:
            self.db.trace(event_id, "extract_error", {"error": str(e), "retry": True})
            self.db.update_event(event_id, last_error=str(e))
            await self.health.llm_failed(str(e))
            return
        except LLMError as e:
            await self.health.llm_ok()
            self.db.trace(event_id, "extract_error", {
                "error": str(e), "retry": False, "prompt": getattr(e, "messages", None),
                "raw": getattr(e, "raw", None),
            }, getattr(e, "duration_ms", None))
            self._set(event_id, status=m.FAILED, reason="extraction error", last_error=str(e),
                      prompt_version=self.prompt.version)
            return
        await self.health.llm_ok()
        ex = res.extraction
        self.db.trace(event_id, "extract", {
            "prompt_version": res.prompt_version, "prompt": res.messages, "raw": res.raw,
            "parsed": ex.model_dump(), "open_items": [it["item_id"] for it in open_items],
        }, res.duration_ms)
        self.db.update_event(
            event_id, extraction=ex.model_dump(), confidence=ex.confidence, actionable=int(ex.actionable),
            extract_ms=res.duration_ms, prompt_version=res.prompt_version, last_error=None,
        )
        self.db.update_event(event_id, open_refs=json.dumps([it["item_id"] for it in open_items]))
        await self._apply_plan(ev, ex, open_items=open_items)

    def _open_refs(self, row: dict[str, Any]) -> list[dict]:
        """The open items exactly as numbered for this event's extraction."""
        ids = json.loads(row.get("open_refs") or "[]")
        return [it for it in (self.items.get(i) for i in ids) if it]

    async def _apply_plan(self, ev: Event, ex: Extraction, *, force: bool = False,
                          open_items: list[dict] | None = None) -> Plan:
        p = plan(self.cfg, ev, ex, datetime.now(timezone.utc), force=force, open_items=open_items)
        self.db.trace(ev.event_id, "plan", {
            "commands": [c.model_dump(exclude_none=True) for c in p.commands], "review_reasons": p.review_reasons,
            "skipped": p.skipped, "forced": force,
        })
        if not p.commands and not p.review_reasons:
            self._set(ev.event_id, status=m.SKIPPED, reason="; ".join(p.skipped) or "not actionable")
            return p
        status = "held" if p.needs_review else "pending"
        gen = self.db.get_event(ev.event_id)["generation"]
        key = chat_key(ev)
        ids, direct = [], []
        for i, c in enumerate(p.commands):
            item_id = c.item_id
            if c.new_item:
                ni = c.new_item
                item_id = self.items.create(event_id=ev.event_id, seq=ni["seq"], kind=ni["kind"],
                                            collection=ni["collection"], chat=key, person=ni["person"],
                                            title=ni["title"], state=ni["state"], tag=ni["tag"],
                                            status="proposed" if p.needs_review else "planned",
                                            category=ni.get("category"))
            elif not p.needs_review and self._edit_proposed(ev, c):
                direct.append(c.meta.get("title") if c.meta else c.item_id)
                continue
            ids.append(self.db.insert_command(ev.event_id, c.op, c.payload, status, seq=i, generation=gen,
                                              item_id=item_id, purpose=c.purpose, meta=c.meta))
        self.db.trace(ev.event_id, "queue", {"command_ids": ids, "status": status,
                                             **({"edited_pending_review": direct} if direct else {})})
        if not ids and direct:
            self._set(ev.event_id, status=m.DONE, reason="changed an item that is still waiting for review")
            return p
        if p.needs_review:
            reason = "; ".join(p.review_reasons)
            self._set(ev.event_id, status=m.NEEDS_REVIEW, reason=reason)
            link = f"{self.cfg.dashboard.public_url.rstrip('/')}/events/{ev.event_id}"
            titles = ", ".join(_describe_cmd(c) for c in p.commands) or "(no items)"
            await self.alerter.send(
                "needs_review",
                f"📝 Needs review — {ev.sender_label or ev.sender_handle}: “{ev.text[:200]}”\n"
                f"Proposed: {titles}\nWhy: {reason}\nApprove/reject: {link}",
            )
        else:
            self._set(ev.event_id, status=m.QUEUED, reason=None)
            await self.queue.wake()
        return p

    def _edit_proposed(self, ev: Event, c) -> bool:
        """An item still waiting for review is changed in place instead of via the Mac."""
        item = self.items.get(c.item_id)
        if not item or item["status"] != "proposed":
            return False
        held = self.db.one("SELECT command_id FROM commands WHERE item_id=? AND status='held' "
                           "AND op IN ('create_reminder','create_event')", (item["item_id"],))
        if not held:
            return False
        cmd = self.db.get_command(held["command_id"])
        if c.purpose in ("cancel", "complete"):
            self.db.update_command(cmd["command_id"], status="cancelled", completed_at=m.utcnow())
            self.items.update(item["item_id"], status="cancelled")
            self.items.log(item["item_id"], ev.event_id, "cancelled", {"before_approval": True})
            origin = self.db.get_event(cmd["event_id"])
            if origin and origin["status"] == m.NEEDS_REVIEW and not any(
                    x["status"] == "held" for x in self.db.commands_for_event(cmd["event_id"])):
                self._set(cmd["event_id"], status=m.SKIPPED, reason=f"cancelled by a later message ({ev.event_id})")
            return True
        changes = {k: v for k, v in c.payload.get("changes", {}).items() if k != "completed"}
        self.db.update_command(cmd["command_id"], payload=json.dumps({**cmd["payload"], **changes}))
        self.items.update(item["item_id"], state={**item["state"], **changes},
                          **({"title": changes["title"]} if "title" in changes else {}))
        self.items.log(item["item_id"], ev.event_id, "updated", {"changes": changes, "before_approval": True})
        return True

    # ---- dashboard actions -----------------------------------------------------------
    def _require(self, event_id: str) -> dict[str, Any]:
        row = self.db.get_event(event_id)
        if not row:
            raise ActionError("unknown event")
        return row

    async def approve(self, event_id: str) -> None:
        row = self._require(event_id)
        if row["status"] != m.NEEDS_REVIEW:
            raise ActionError(f"event is {row['status']}, not needs_review")
        held = [c for c in self.db.commands_for_event(event_id) if c["status"] == "held"]
        if not held:
            raise ActionError("nothing to approve — use “Reprocess with edits” to add items")
        for c in held:
            fields: dict[str, Any] = {"status": "pending"}
            item = self.items.get(c["item_id"])
            if item and item["status"] == "proposed":
                self.items.update(item["item_id"], status="planned")
            if (c["op"] == "create_reminder" and not (c["meta"] or {}).get("collection")
                    and c["payload"].get("list") != self.cfg.rules.reminder_list):
                # The list may have been changed in Settings while this waited for review.
                fields["payload"] = json.dumps({**c["payload"], "list": self.cfg.rules.reminder_list})
            self.db.update_command(c["command_id"], **fields)
        self.db.trace(event_id, "review", {"decision": "approved", "command_ids": [c["command_id"] for c in held]})
        self._set(event_id, status=m.QUEUED, reason="approved")
        await self.queue.wake()

    async def reject(self, event_id: str) -> None:
        row = self._require(event_id)
        if row["status"] != m.NEEDS_REVIEW:
            raise ActionError(f"event is {row['status']}, not needs_review")
        self._cancel_open(event_id, item_status="rejected")
        self.db.trace(event_id, "review", {"decision": "rejected"})
        self._set(event_id, status=m.REJECTED, reason="rejected in dashboard")

    def _cancel_open(self, event_id: str, item_status: str = "undone") -> None:
        for c in self.db.commands_for_event(event_id):
            # Never cancel queued inverses: they clean up items that already exist.
            if c["status"] in ("held", "pending") and not c["undo_of"]:
                self.db.update_command(c["command_id"], status="cancelled", completed_at=m.utcnow())
                if c["op"] in ("create_reminder", "create_event") and c["item_id"]:
                    self.items.update(c["item_id"], status=item_status)
                    self.items.log(c["item_id"], event_id, item_status, None)

    def _queue_inverses(self, event_id: str, generation: int, why: str) -> list[str]:
        """Queue the opposite of everything this event did on the Mac (newest first)."""
        cmds = [c for c in self.db.commands_for_event(event_id) if c["generation"] == generation]
        already = {c["undo_of"] for c in cmds if c["undo_of"] and c["status"] != "failed"}
        ids = []
        for c in reversed(cmds):
            if c["undo_of"] or c["status"] != "done" or c["command_id"] in already:
                continue
            item = self.items.get(c["item_id"])
            apple = (item or {}).get("apple_item_id") or c["apple_item_id"] or c["payload"].get("apple_item_id")
            tag = (item or {}).get("tag") or c["payload"].get("tag")
            kind = (item or {}).get("kind") or ("event" if c["op"] == "create_event" else "reminder")
            if c["op"] in ("create_reminder", "create_event"):
                op, payload = "delete_item", {"apple_item_id": apple, "tag": tag, "kind": kind}
            elif c["op"] == "update_item":
                prev = (c["meta"] or {}).get("previous")
                if not prev:
                    continue
                op, payload = "update_item", {"apple_item_id": apple, "tag": tag, "kind": kind, "changes": prev,
                                              "notes_append": f"↩︎ Change undone ({why})"}
            elif c["op"] == "delete_item" and c["purpose"] == "cancel" and item:
                op, payload = create_payload(item)
            else:
                continue
            ids.append(self.db.insert_command(event_id, op, payload, "pending", seq=c["seq"],
                                              undo_of=c["command_id"], generation=generation,
                                              item_id=c["item_id"], purpose="undo"))
        return ids

    async def undo(self, event_id: str) -> None:
        row = self._require(event_id)
        self._cancel_open(event_id)
        ids = self._queue_inverses(event_id, row["generation"], "undo")
        if not ids:
            raise ActionError("nothing has been done on the Mac yet to undo")
        self.db.trace(event_id, "undo", {"command_ids": ids})
        self._set(event_id, status=m.UNDOING, reason="undo requested")
        await self.queue.wake()

    def _start_over(self, row: dict[str, Any]) -> int:
        """Cancel open commands, delete items the previous plan created, bump the generation.

        Deletes are queued before the new plan's creates, and the agent runs commands in order,
        so a re-created item with the same [ha:] tag is never mistaken for the old one.
        """
        event_id = row["event_id"]
        self._cancel_open(event_id)
        ids = self._queue_inverses(event_id, row["generation"], "re-run")
        if ids:
            self.db.trace(event_id, "undo", {"command_ids": ids, "why": "start over"})
        gen = row["generation"] + 1
        self.db.update_event(event_id, generation=gen)
        return gen

    async def retry(self, event_id: str) -> None:
        """Re-run extraction from scratch (current prompt version)."""
        row = self._require(event_id)
        if event_id in self._inflight:
            raise ActionError("already processing")
        self._start_over(row)
        self.db.trace(event_id, "retry", {"previous_status": row["status"]})
        self._set(event_id, status=m.RECEIVED, reason="retry")
        await self.queue.wake()
        await self.process(event_id)

    async def reprocess_with(self, event_id: str, extraction_json: str) -> None:
        """Human-edited extraction → plan (no confidence gate) → queue. Previous items are undone."""
        row = self._require(event_id)
        try:
            ex = Extraction.model_validate(json.loads(extraction_json))
        except Exception as e:  # noqa: BLE001 — shown to the user
            raise ActionError(f"invalid extraction JSON: {e}") from e
        self._start_over(row)
        self.db.trace(event_id, "edit", {"extraction": ex.model_dump()})
        self.db.update_event(event_id, extraction=ex.model_dump(), confidence=ex.confidence,
                             actionable=int(ex.actionable))
        await self._apply_plan(self.row_to_event(row), ex, force=True, open_items=self._open_refs(row))

    # ---- background ------------------------------------------------------------------
    async def retry_received(self) -> None:
        cutoff = (datetime.now(timezone.utc) - timedelta(seconds=20)).isoformat()
        rows = self.db.all(
            "SELECT event_id FROM events WHERE status=? AND updated_at < ? AND attempts < 200 ORDER BY id LIMIT 20",
            (m.RECEIVED, cutoff),
        )
        for r in rows:
            await self.process(r["event_id"])
            if self.health.llm_fail_streak:
                break  # still down; try again next round


def _describe_cmd(c) -> str:
    title = c.payload.get("title") or (c.meta or {}).get("title") or "item"
    if c.purpose == "cancel":
        return f"cancel “{title}”"
    if c.purpose == "complete":
        return f"mark “{title}” done"
    if c.purpose == "update":
        return f"change “{title}” ({(c.meta or {}).get('summary', '')})"
    return title
