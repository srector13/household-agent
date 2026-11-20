"""FastAPI app: agent API, dashboard, background loops."""
from __future__ import annotations

import asyncio
import hmac
import json
import logging
import secrets
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from . import __version__
from . import models as m
from .backup import backup_if_due
from .commands import Bus, CommandQueue
from .config import Config, load_config
from .extract import LLMClient, LLMError, PromptTemplate, VLLMClient, extract
from .gate import gate
from .heartbeat import Alerter, Health, run_every
from .models import DB
from .pipeline import ActionError, Pipeline
from .planner import plan
from .schemas import CommandResult, Event, Heartbeat

log = logging.getLogger("brain")
HERE = Path(__file__).parent

STATUS_BADGE = {
    m.DONE: ("created", "ok"), m.QUEUED: ("queued", "info"), m.RECEIVED: ("processing", "info"),
    m.SKIPPED: ("skipped", "muted"), m.NEEDS_REVIEW: ("needs review", "warn"), m.FAILED: ("failed", "bad"),
    m.REJECTED: ("rejected", "muted"), m.UNDOING: ("undoing", "info"), m.UNDONE: ("undone", "muted"),
}


def create_app(cfg: Config | None = None, *, llm: LLMClient | None = None, alerter: Alerter | None = None,
               background: bool = True) -> FastAPI:
    cfg = cfg or load_config()
    db = DB(cfg.storage.db_path)
    bus = Bus()
    queue = CommandQueue(db, bus)
    alerter = alerter or Alerter(cfg, db)
    health = Health(cfg, db, alerter)
    llm = llm or VLLMClient(cfg.llm)
    pipeline = Pipeline(cfg, db, llm, queue, bus, alerter, health)
    health.on_llm_recovered = lambda: asyncio.create_task(pipeline.retry_received())

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        tasks: list[asyncio.Task] = []
        if not cfg.security.agent_token:
            log.warning("security.agent_token is empty — all agent API calls will be rejected")
        if background:
            async def ping_llm():
                try:
                    await health.llm_ok(await llm.ping())
                except Exception as e:  # noqa: BLE001
                    await health.llm_failed(f"ping: {e!r}")

            tasks += [
                asyncio.create_task(run_every(30, health.check_agent, name="watchdog")),
                asyncio.create_task(run_every(30, pipeline.retry_received, name="retry")),
                asyncio.create_task(run_every(60, ping_llm, name="llm-ping")),
                asyncio.create_task(run_every(600, lambda: backup_if_due(cfg, db), name="backup")),
            ]
            if cfg.watch.mail.enabled:
                from .mail import MailListener
                listener = MailListener(cfg, db, pipeline, health, asyncio.get_running_loop())
                listener.start()
                app.state.mail = listener
        yield
        for t in tasks:
            t.cancel()
        if getattr(app.state, "mail", None):
            app.state.mail.stop()

    app = FastAPI(title="Household Agent brain", version=__version__, lifespan=lifespan)
    app.state.cfg, app.state.db, app.state.pipeline, app.state.queue, app.state.health = cfg, db, pipeline, queue, health
    app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
    templates = Jinja2Templates(directory=HERE / "templates")
    env = templates.env

    def localtime(value: str | None, fmt: str = "%a %b %-d, %-I:%M %p") -> str:
        if not value:
            return ""
        try:
            return datetime.fromisoformat(value).astimezone(cfg.tz).strftime(fmt)
        except ValueError:
            return value

    env.filters["localtime"] = localtime
    env.filters["pretty"] = lambda v: json.dumps(v, indent=2, ensure_ascii=False, default=str)
    env.globals.update(badge=lambda s: STATUS_BADGE.get(s, (s, "muted")), version=__version__)

    # ---- auth ------------------------------------------------------------------
    def agent_auth(request: Request) -> None:
        header = request.headers.get("authorization", "")
        token = header[7:] if header.lower().startswith("bearer ") else ""
        expected = cfg.security.agent_token
        if not expected or not hmac.compare_digest(token.encode(), expected.encode()):
            raise HTTPException(401, "bad token", headers={"WWW-Authenticate": "Bearer"})

    basic = HTTPBasic(auto_error=False)

    def dash_auth(creds: HTTPBasicCredentials | None = Depends(basic)) -> None:
        pw = cfg.dashboard.password
        if not pw:
            return
        if not creds or not secrets.compare_digest(creds.password.encode(), pw.encode()):
            raise HTTPException(401, "auth required", headers={"WWW-Authenticate": "Basic"})

    # ---- agent API ---------------------------------------------------------------
    @app.post("/api/events", dependencies=[Depends(agent_auth)])
    async def post_event(ev: Event, sync: bool = False):
        return await pipeline.ingest(ev, sync=sync)

    @app.get("/api/agent/commands", dependencies=[Depends(agent_auth)])
    async def get_commands(wait: float = Query(30, ge=0, le=55)):
        return {"commands": await queue.poll(wait)}

    @app.post("/api/agent/commands/{command_id}/result", dependencies=[Depends(agent_auth)])
    async def post_result(command_id: str, res: CommandResult):
        if not queue.record_result(command_id, res):
            raise HTTPException(404, "unknown command")
        return {"ok": True}

    @app.post("/api/agent/heartbeat", dependencies=[Depends(agent_auth)])
    async def post_heartbeat(hb: Heartbeat):
        await health.record_heartbeat(hb)
        return {"ok": True}

    # ---- JSON for the dashboard / debugging -------------------------------------------
    @app.get("/api/health", dependencies=[Depends(dash_auth)])
    async def api_health():
        return {"version": __version__, **health.snapshot(queue.depth())}

    @app.get("/api/events/{event_id:path}", dependencies=[Depends(dash_auth)])
    async def api_event(event_id: str):
        ev = db.get_event(event_id)
        if not ev:
            raise HTTPException(404)
        return {"event": ev, "trace": db.get_trace(event_id), "commands": db.commands_for_event(event_id)}

    @app.get("/api/stream", dependencies=[Depends(dash_auth)])
    async def stream(request: Request):
        q = bus.subscribe()

        async def gen():
            try:
                yield ": connected\n\n"
                while True:
                    if await request.is_disconnected():
                        break
                    try:
                        msg = await asyncio.wait_for(q.get(), timeout=15)
                        yield f"data: {json.dumps(msg)}\n\n"
                    except asyncio.TimeoutError:
                        yield ": keepalive\n\n"
            finally:
                bus.unsubscribe(q)

        return StreamingResponse(gen(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    # ---- dashboard pages ---------------------------------------------------------------
    def page(request: Request, name: str, **ctx: Any) -> HTMLResponse:
        return templates.TemplateResponse(request, name, {"cfg": cfg, **ctx})

    @app.get("/", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def feed(request: Request, status: str | None = None, limit: int = 100):
        events = db.recent_events(limit=min(limit, 500), status=status or None)
        review_count = db.one("SELECT COUNT(*) n FROM events WHERE status=?", (m.NEEDS_REVIEW,))["n"]
        return page(request, "feed.html", events=events, status=status, review_count=review_count,
                    health=health.snapshot(queue.depth()), statuses=list(STATUS_BADGE))

    @app.get("/partials/row/{event_id:path}", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def row_partial(request: Request, event_id: str):
        ev = db.get_event(event_id)
        if not ev:
            return HTMLResponse("", status_code=404)
        return page(request, "_row.html", e=ev)

    @app.get("/events/{event_id:path}", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def event_detail(request: Request, event_id: str, msg: str | None = None, err: str | None = None):
        ev = db.get_event(event_id)
        if not ev:
            raise HTTPException(404, "unknown event")
        cmds = db.commands_for_event(event_id)
        gen_cmds = [c for c in cmds if c["generation"] == ev["generation"]]
        can = {
            "approve": ev["status"] == m.NEEDS_REVIEW and any(c["status"] == "held" for c in gen_cmds),
            "reject": ev["status"] == m.NEEDS_REVIEW,
            "undo": any(c["status"] == "done" and not c["undo_of"] and c["apple_item_id"] for c in gen_cmds)
                    and ev["status"] not in (m.UNDONE, m.UNDOING),
            "retry": ev["status"] not in (m.UNDOING,),
        }
        extraction = ev["extraction"] or {"actionable": True, "actions": [], "confidence": 1.0,
                                          "reasoning_brief": "added manually"}
        return page(request, "event.html", e=ev, trace=db.get_trace(event_id), commands=cmds, can=can,
                    extraction_json=json.dumps(extraction, indent=2, ensure_ascii=False), msg=msg, err=err)

    async def _action(event_id: str, fn) -> RedirectResponse:
        from urllib.parse import quote
        try:
            await fn()
            q = "?msg=" + quote("Done.")
        except ActionError as e:
            q = "?err=" + quote(str(e))
        return RedirectResponse(f"/events/{quote(event_id)}{q}", status_code=303)

    @app.post("/actions/{action}/{event_id:path}", dependencies=[Depends(dash_auth)])
    async def do_action(action: str, event_id: str, extraction: str | None = Form(None)):
        fns = {
            "approve": lambda: pipeline.approve(event_id),
            "reject": lambda: pipeline.reject(event_id),
            "undo": lambda: pipeline.undo(event_id),
            "retry": lambda: pipeline.retry(event_id),
            "reprocess": lambda: pipeline.reprocess_with(event_id, extraction or ""),
        }
        if action not in fns:
            raise HTTPException(404)
        return await _action(event_id, fns[action])

    @app.get("/health", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def health_page(request: Request):
        alerts = db.all("SELECT * FROM alerts ORDER BY id DESC LIMIT 30")
        return page(request, "health.html", h=health.snapshot(queue.depth()), alerts=alerts,
                    last_backup=db.kv_get("last_backup"), prompt_version=pipeline.prompt.version)

    @app.get("/stats", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def stats_page(request: Request, days: int = 14):
        return page(request, "stats.html", s=compute_stats(db, cfg, days), days=days)

    @app.get("/playground", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def playground(request: Request):
        return page(request, "playground.html", result=None, form={})

    @app.post("/playground", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def playground_run(request: Request, text: str = Form(...), sender: str = Form("Wife"),
                             context: str = Form(""), now: str = Form("")):
        """Dry run: extraction + plan, nothing stored, nothing sent to the Mac."""
        when = datetime.fromisoformat(now).replace(tzinfo=cfg.tz) if now else datetime.now(cfg.tz)
        ev = Event(event_id="playground", source="manual", sender_handle="", sender_label=sender,
                   received_at=when, text=text, recent_context=[l for l in context.splitlines() if l.strip()])
        result: dict[str, Any] = {"gate": gate(cfg, ev)}
        try:
            res = await extract(cfg, llm, pipeline.prompt, ev, when)
            p = plan(cfg, ev, res.extraction, when)
            result.update(prompt=res.messages, raw=res.raw, parsed=res.extraction.model_dump(),
                          ms=res.duration_ms, commands=[c.model_dump() for c in p.commands],
                          review=p.review_reasons)
        except LLMError as e:
            result.update(error=str(e), raw=getattr(e, "raw", None))
        return page(request, "playground.html", result=result,
                    form={"text": text, "sender": sender, "context": context, "now": now})

    @app.get("/favicon.ico")
    async def favicon():
        return Response(status_code=204)

    return app


def compute_stats(db: DB, cfg: Config, days: int) -> dict[str, Any]:
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    rows = db.all("SELECT created_at, status, actionable, extract_ms FROM events WHERE created_at >= ?", (since,))
    per_day: dict[str, int] = {}
    today = datetime.now(cfg.tz).date()
    for i in range(days - 1, -1, -1):
        per_day[(today - timedelta(days=i)).isoformat()] = 0
    by_status: dict[str, int] = {}
    extracted = actionable = 0
    lat: list[int] = []
    for r in rows:
        d = datetime.fromisoformat(r["created_at"]).astimezone(cfg.tz).date().isoformat()
        if d in per_day:
            per_day[d] += 1
        by_status[r["status"]] = by_status.get(r["status"], 0) + 1
        if r["actionable"] is not None:
            extracted += 1
            actionable += r["actionable"]
        if r["extract_ms"]:
            lat.append(r["extract_ms"])
    lat.sort()
    return {
        "total": len(rows),
        "per_day": per_day,
        "max_day": max(per_day.values() or [0]) or 1,
        "by_status": by_status,
        "extracted": extracted,
        "pct_actionable": round(100 * actionable / extracted) if extracted else None,
        "avg_latency_ms": round(sum(lat) / len(lat)) if lat else None,
        "p90_latency_ms": lat[int(len(lat) * 0.9)] if lat else None,
        "failures": by_status.get(m.FAILED, 0),
        "commands_failed": db.one("SELECT COUNT(*) n FROM commands WHERE status='failed' AND created_at >= ?",
                                  (since,))["n"],
    }


def factory() -> FastAPI:
    """Entry point: `uvicorn app.main:factory --factory`."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    return create_app()
