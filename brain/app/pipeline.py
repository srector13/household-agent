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
from .gate import allowlist_label, gate
from .heartbeat import Alerter, Health
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
        reason = gate(self.cfg, ev)
        self.db.trace(ev.event_id, "gate", {"decision": "skip" if reason else "pass", "reason": reason})
        if reason:
            self._set(ev.event_id, status=m.SKIPPED, reason=reason)
            return {"status": "accepted", "event_id": ev.event_id, "result": m.SKIPPED}
        self.bus.publish({"event_id": ev.event_id, "status": m.RECEIVED})
        if sync:
            await self.process(ev.event_id)
            row = self.db.get_event(ev.event_id)
            return {"status": "accepted", "event_id": ev.event_id, "result": row["status"], "reason": row["reason"]}
        self.submit(ev.event_id)
        return {"status": "accepted", "event_id": ev.event_id}

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
        try:
            # Resolve relative dates against when the message arrived, not when we got to it.
            res = await extract(self.cfg, self.llm, self.prompt, ev, ev.received_at)
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
            "parsed": ex.model_dump(),
        }, res.duration_ms)
        self.db.update_event(
            event_id, extraction=ex.model_dump(), confidence=ex.confidence, actionable=int(ex.actionable),
            extract_ms=res.duration_ms, prompt_version=res.prompt_version, last_error=None,
        )
        await self._apply_plan(ev, ex)

    async def _apply_plan(self, ev: Event, ex: Extraction, *, force: bool = False) -> Plan:
        p = plan(self.cfg, ev, ex, datetime.now(timezone.utc), force=force)
        self.db.trace(ev.event_id, "plan", {
            "commands": [c.model_dump() for c in p.commands], "review_reasons": p.review_reasons, "forced": force,
        })
        if not p.commands and not p.review_reasons:
            self._set(ev.event_id, status=m.SKIPPED, reason="not actionable")
            return p
        status = "held" if p.needs_review else "pending"
        gen = self.db.get_event(ev.event_id)["generation"]
        ids = [self.db.insert_command(ev.event_id, c.op, c.payload, status, seq=i, generation=gen)
               for i, c in enumerate(p.commands)]
        self.db.trace(ev.event_id, "queue", {"command_ids": ids, "status": status})
        if p.needs_review:
            reason = "; ".join(p.review_reasons)
            self._set(ev.event_id, status=m.NEEDS_REVIEW, reason=reason)
            link = f"{self.cfg.dashboard.public_url.rstrip('/')}/events/{ev.event_id}"
            titles = ", ".join(c.payload["title"] for c in p.commands) or "(no items)"
            await self.alerter.send(
                "needs_review",
                f"📝 Needs review — {ev.sender_label or ev.sender_handle}: “{ev.text[:200]}”\n"
                f"Proposed: {titles}\nWhy: {reason}\nApprove/reject: {link}",
            )
        else:
            self._set(ev.event_id, status=m.QUEUED, reason=None)
            await self.queue.wake()
        return p

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
            if c["op"] == "create_reminder" and c["payload"].get("list") != self.cfg.rules.reminder_list:
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
        self._cancel_open(event_id)
        self.db.trace(event_id, "review", {"decision": "rejected"})
        self._set(event_id, status=m.REJECTED, reason="rejected in dashboard")

    def _cancel_open(self, event_id: str) -> None:
        for c in self.db.commands_for_event(event_id):
            # Never cancel queued deletes: they clean up items that already exist.
            if c["status"] in ("held", "pending") and not c["undo_of"]:
                self.db.update_command(c["command_id"], status="cancelled", completed_at=m.utcnow())

    def _queue_deletes(self, event_id: str, generation: int) -> list[str]:
        """Queue delete_item for every created item of `generation` not already undone."""
        cmds = [c for c in self.db.commands_for_event(event_id) if c["generation"] == generation]
        already = {c["undo_of"] for c in cmds if c["undo_of"] and c["status"] != "failed"}
        ids = []
        for c in cmds:
            if c["undo_of"] or c["status"] != "done" or not c["apple_item_id"] or c["command_id"] in already:
                continue
            kind = "reminder" if c["op"] == "create_reminder" else "event"
            ids.append(self.db.insert_command(
                event_id, "delete_item", {"apple_item_id": c["apple_item_id"], "kind": kind},
                "pending", seq=c["seq"], undo_of=c["command_id"], generation=generation,
            ))
        return ids

    async def undo(self, event_id: str) -> None:
        row = self._require(event_id)
        self._cancel_open(event_id)
        ids = self._queue_deletes(event_id, row["generation"])
        if not ids:
            raise ActionError("nothing created yet to undo")
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
        ids = self._queue_deletes(event_id, row["generation"])
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
        await self._apply_plan(self.row_to_event(row), ex, force=True)

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
