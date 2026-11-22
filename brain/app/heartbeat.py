"""Watchdog: mac-agent heartbeats, permission flags, vLLM reachability → Discord alerts."""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timezone
from typing import Any

import httpx

from .config import Config
from .models import DB
from .schemas import Heartbeat

log = logging.getLogger("brain.watchdog")


class Alerter:
    def __init__(self, cfg: Config, db: DB, http: httpx.AsyncClient | None = None):
        self.cfg = cfg
        self.db = db
        self.http = http or httpx.AsyncClient(timeout=10)

    SYSTEM_KINDS = {"agent_offline", "agent_online", "llm_down", "llm_up", "permission"}
    push = None  # set by the app (push.Push)

    async def send(self, kind: str, message: str, *, discord: bool = True) -> bool:
        if self.push and kind in self.SYSTEM_KINDS:
            try:
                await self.push.send("system", self.cfg.dashboard.app_name, message.lstrip("🔴✅⚠️ "), url="/system")
            except Exception as e:  # noqa: BLE001
                log.warning("push for %s failed: %r", kind, e)
        url = self.cfg.alerts.discord_webhook_url if discord else None
        delivered = False
        if url:
            try:
                r = await self.http.post(url, json={"content": message[:1900], "allowed_mentions": {"parse": []}})
                delivered = r.status_code < 300
                if not delivered:
                    log.warning("discord webhook HTTP %s: %s", r.status_code, r.text[:200])
            except httpx.HTTPError as e:
                log.warning("discord webhook failed: %r", e)
        log.info("ALERT [%s] %s (delivered=%s)", kind, message, delivered)
        self.db.insert_alert(kind, message, delivered)
        return delivered


class Health:
    """Tracks agent + LLM state and raises alerts on transitions (once, then on recovery)."""

    LLM_FAIL_THRESHOLD = 3
    PERM_FLAGS = ("fda_ok", "reminders_ok", "calendar_ok")
    PERM_NAMES = {"fda_ok": "Full Disk Access", "reminders_ok": "Reminders", "calendar_ok": "Calendar"}

    def __init__(self, cfg: Config, db: DB, alerter: Alerter):
        self.cfg = cfg
        self.db = db
        self.alerter = alerter
        self.started = time.time()
        self.llm_fail_streak = 0
        self.llm_down_alerted = False
        self.llm_last_latency_ms: float | None = None
        self.llm_last_ok: float | None = None
        self.llm_last_error: str | None = None
        self.mail_status: dict[str, Any] = {"enabled": cfg.watch.mail.enabled, "state": "disabled"}
        self.on_llm_recovered = None  # callback set by the app

    # ---- agent ---------------------------------------------------------------
    @property
    def agent(self) -> dict[str, Any] | None:
        return self.db.kv_get("agent")

    async def record_heartbeat(self, hb: Heartbeat) -> None:
        prev = self.agent or {}
        state = hb.model_dump()
        state["received_at"] = time.time()
        self.db.kv_set("agent", state)
        if self.db.kv_get("agent_offline_alerted", False):
            self.db.kv_set("agent_offline_alerted", False)
            await self.alerter.send("agent_online", f"✅ Mac agent back online (v{hb.agent_version}).")
        for flag in self.PERM_FLAGS:
            was = prev.get(flag, True)
            now = state[flag]
            if was and not now:
                await self.alerter.send("permission", f"⚠️ Mac agent lost {self.PERM_NAMES[flag]} permission.")
            elif not was and now:
                await self.alerter.send("permission", f"✅ Mac agent {self.PERM_NAMES[flag]} permission OK again.")

    async def check_agent(self) -> None:
        agent = self.agent
        last = agent["received_at"] if agent else self.started
        if time.time() - last > self.cfg.alerts.heartbeat_timeout_s and not self.db.kv_get("agent_offline_alerted", False):
            self.db.kv_set("agent_offline_alerted", True)
            when = datetime.fromtimestamp(last, timezone.utc).astimezone(self.cfg.tz).strftime("%a %H:%M")
            msg = (f"🔴 Mac agent offline — no heartbeat since {when}." if agent
                   else "🔴 Mac agent has not connected since the brain started.")
            await self.alerter.send("agent_offline", msg)

    def agent_online(self) -> bool:
        agent = self.agent
        return bool(agent) and time.time() - agent["received_at"] <= self.cfg.alerts.heartbeat_timeout_s

    # ---- LLM -----------------------------------------------------------------
    async def llm_ok(self, latency_ms: float | None = None) -> None:
        self.llm_fail_streak = 0
        self.llm_last_ok = time.time()
        self.llm_last_error = None
        if latency_ms is not None:
            self.llm_last_latency_ms = latency_ms
        if self.llm_down_alerted:
            self.llm_down_alerted = False
            await self.alerter.send("llm_up", "✅ vLLM reachable again — retrying queued messages.")
            if self.on_llm_recovered:
                self.on_llm_recovered()

    async def llm_failed(self, err: str) -> None:
        self.llm_fail_streak += 1
        self.llm_last_error = err
        if self.llm_fail_streak >= self.LLM_FAIL_THRESHOLD and not self.llm_down_alerted:
            self.llm_down_alerted = True
            await self.alerter.send("llm_down", f"🔴 vLLM unreachable ({self.llm_fail_streak} failed calls): {err[:300]}")

    def snapshot(self, queue_depth: int) -> dict[str, Any]:
        agent = self.agent
        return {
            "agent": {
                **(agent or {}),
                "online": self.agent_online(),
                "last_seen_s_ago": round(time.time() - agent["received_at"]) if agent else None,
            },
            "llm": {
                "base_url": self.cfg.llm.base_url,
                "model": self.cfg.llm.model,
                "reachable": self.llm_fail_streak == 0 and self.llm_last_ok is not None,
                "latency_ms": round(self.llm_last_latency_ms) if self.llm_last_latency_ms else None,
                "fail_streak": self.llm_fail_streak,
                "last_error": self.llm_last_error,
            },
            "mail": self.mail_status,
            "queue_depth": queue_depth,
            "brain_uptime_s": round(time.time() - self.started),
        }


async def run_every(interval_s: float, fn, *, name: str) -> None:
    while True:
        try:
            await fn()
        except asyncio.CancelledError:
            raise
        except Exception:  # keep background loops alive
            log.exception("background task %s failed", name)
        await asyncio.sleep(interval_s)
