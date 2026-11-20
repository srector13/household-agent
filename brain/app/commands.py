"""Command queue for the mac-agent (long-poll delivery with leases) + SSE bus."""
from __future__ import annotations

import asyncio
import json
from datetime import datetime, timedelta, timezone
from typing import Any

from . import models as m
from .models import DB
from .schemas import CommandResult

LEASE_S = 300
MAX_DELIVERIES = 5


class Bus:
    """In-process pub/sub used for the dashboard's Server-Sent Events feed."""

    def __init__(self) -> None:
        self._subs: set[asyncio.Queue] = set()

    def publish(self, msg: dict[str, Any]) -> None:
        for q in list(self._subs):
            try:
                q.put_nowait(msg)
            except asyncio.QueueFull:
                pass

    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=200)
        self._subs.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        self._subs.discard(q)


class CommandQueue:
    def __init__(self, db: DB, bus: Bus):
        self.db = db
        self.bus = bus
        self._cond = asyncio.Condition()
        self._gen = 0

    async def wake(self) -> None:
        async with self._cond:
            self._gen += 1
            self._cond.notify_all()

    def depth(self) -> int:
        row = self.db.one("SELECT COUNT(*) AS n FROM commands WHERE status IN ('pending','sent')")
        return row["n"] if row else 0

    def _claim(self) -> list[dict[str, Any]]:
        now = datetime.now(timezone.utc)
        lease_cutoff = (now - timedelta(seconds=LEASE_S)).isoformat(timespec="milliseconds")
        with self.db.lock:
            rows = self.db.all(
                """SELECT * FROM commands
                   WHERE status='pending' OR (status='sent' AND sent_at < ?)
                   ORDER BY rowid LIMIT 20""",
                (lease_cutoff,),
            )
            out = []
            for r in rows:
                if r["attempts"] >= MAX_DELIVERIES:
                    self.db.update_command(
                        r["command_id"], status="failed", completed_at=m.utcnow(),
                        error=f"no result after {MAX_DELIVERIES} deliveries",
                    )
                    self.refresh_event(r["event_id"])
                    continue
                self.db.update_command(
                    r["command_id"], status="sent", sent_at=now.isoformat(timespec="milliseconds"),
                    attempts=r["attempts"] + 1,
                )
                out.append({
                    "command_id": r["command_id"],
                    "event_id": r["event_id"],
                    "op": r["op"],
                    "payload": json.loads(r["payload"]),
                })
        return out

    async def poll(self, wait_s: float) -> list[dict[str, Any]]:
        deadline = asyncio.get_running_loop().time() + max(0.0, min(wait_s, 55.0))
        while True:
            async with self._cond:
                gen = self._gen
            cmds = self._claim()
            if cmds:
                for c in cmds:
                    self.db.trace(c["event_id"], "command_sent", {"command_id": c["command_id"], "op": c["op"]})
                return cmds
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                return []
            async with self._cond:
                try:
                    # Wake on new commands, or re-check every 10s for expired leases.
                    await asyncio.wait_for(
                        self._cond.wait_for(lambda: self._gen != gen), timeout=min(remaining, 10.0)
                    )
                except asyncio.TimeoutError:
                    pass

    def record_result(self, command_id: str, res: CommandResult) -> dict[str, Any] | None:
        cmd = self.db.get_command(command_id)
        if not cmd:
            return None
        if cmd["status"] in ("done", "cancelled"):
            return cmd  # late duplicate result — keep the first outcome
        self.db.update_command(
            command_id, status=res.status, apple_item_id=res.apple_item_id or cmd["apple_item_id"],
            error=res.error, completed_at=m.utcnow(),
        )
        self.db.trace(cmd["event_id"], "command_result", {
            "command_id": command_id, "op": cmd["op"], **res.model_dump(),
        })
        self.refresh_event(cmd["event_id"])
        return self.db.get_command(command_id)

    def refresh_event(self, event_id: str) -> str | None:
        """Derive the event status from its commands."""
        ev = self.db.get_event(event_id)
        if not ev or ev["status"] in (m.NEEDS_REVIEW, m.REJECTED, m.SKIPPED, m.RECEIVED):
            return ev["status"] if ev else None
        gen = ev["generation"]
        cmds = [c for c in self.db.commands_for_event(event_id)
                if c["generation"] == gen and c["status"] not in ("cancelled", "held")]
        undo = [c for c in cmds if c["undo_of"]]
        creates = [c for c in cmds if not c["undo_of"]]
        active = {"pending", "sent"}
        status, reason = ev["status"], ev["reason"]
        if undo:
            if any(c["status"] in active for c in undo):
                status = m.UNDOING
            elif any(c["status"] == "failed" for c in undo):
                status, reason = m.FAILED, "undo failed: " + "; ".join(c["error"] or "?" for c in undo if c["status"] == "failed")
            else:
                status = m.UNDONE
        elif creates:
            if any(c["status"] in active for c in creates):
                status = m.QUEUED
            elif any(c["status"] == "failed" for c in creates):
                status, reason = m.FAILED, "; ".join(c["error"] or "?" for c in creates if c["status"] == "failed")
            else:
                status = m.DONE
        if status != ev["status"] or reason != ev["reason"]:
            self.db.update_event(event_id, status=status, reason=reason)
            self.bus.publish({"event_id": event_id, "status": status})
        return status
