"""FastAPI app: agent API, dashboard ("control room"), settings API, background loops."""
from __future__ import annotations

import asyncio
import hmac
import json
import logging
import secrets
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse

from fastapi import Body, Depends, FastAPI, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from . import __version__, views
from . import models as m
from .backup import backup_if_due
from .commands import Bus, CommandQueue
from .daily import Daily
from .config import Config, load_raw
from .extract import LLMClient, LLMError, VLLMClient, extract
from .gate import gate, normalize_handle
from .heartbeat import Alerter, Health, run_every
from .icons import icon
from .items import chat_key
from .models import DB
from .pipeline import ActionError, Pipeline
from .planner import plan
from .schemas import CommandResult, Event, Heartbeat, ItemStatusReport
from .settings import SettingsError, SettingsStore

log = logging.getLogger("brain")
HERE = Path(__file__).parent

STATUS_BADGE = {
    m.DONE: ("Done", "ok"), m.QUEUED: ("Queued", "info"), m.RECEIVED: ("Processing", "info"),
    m.SKIPPED: ("Skipped", "muted"), m.NEEDS_REVIEW: ("Needs review", "warn"), m.FAILED: ("Failed", "bad"),
    m.REJECTED: ("Rejected", "muted"), m.UNDOING: ("Undoing", "info"), m.UNDONE: ("Undone", "muted"),
}
STEP_LABEL = {
    "ingest": "Received", "allowlist": "Allowlist", "gate": "Gate", "extract": "LLM extraction",
    "extract_error": "LLM error", "plan": "Planner", "queue": "Queued for Mac", "command_sent": "Sent to Mac",
    "command_result": "Mac result", "review": "Review", "undo": "Undo", "retry": "Retry", "edit": "Edited",
}
AGENT_PATHS = ("/api/agent/", "/api/events")


def create_app(cfg: Config | None = None, *, llm: LLMClient | None = None, alerter: Alerter | None = None,
               background: bool = True, base_raw: dict | None = None) -> FastAPI:
    if cfg is None:
        base_raw = load_raw()
        cfg = Config.model_validate(base_raw)
    db = DB(cfg.storage.db_path)
    settings = SettingsStore(cfg, db, base_raw)  # applies saved dashboard overrides to cfg in place
    bus = Bus()
    queue = CommandQueue(db, bus)
    alerter = alerter or Alerter(cfg, db)
    health = Health(cfg, db, alerter)
    llm = llm or VLLMClient(lambda: cfg.llm)
    pipeline = Pipeline(cfg, db, llm, queue, bus, alerter, health)
    health.on_llm_recovered = lambda: asyncio.create_task(pipeline.retry_received())
    daily = Daily(cfg, db, pipeline.items, queue, llm, alerter, bus)
    state: dict[str, Any] = {"mail": None}

    def start_mail() -> None:
        if state["mail"]:
            state["mail"].stop()
            state["mail"] = None
        health.mail_status = {"enabled": cfg.watch.mail.enabled, "state": "disabled", "folders": {}}
        if cfg.watch.mail.enabled:
            from .mail import MailListener
            state["mail"] = MailListener(cfg, db, pipeline, health, asyncio.get_running_loop())
            state["mail"].start()

    def on_settings_change(sections: set[str]) -> None:
        log.info("settings changed: %s (v%s)", ", ".join(sorted(sections)), settings.version)
        bus.publish({"type": "settings", "sections": sorted(sections), "version": settings.version})
        if "watch.mail" in sections and background:
            start_mail()

    settings.listeners.append(on_settings_change)

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
                asyncio.create_task(run_every(60, daily.tick, name="daily")),
            ]
            start_mail()
        yield
        for t in tasks:
            t.cancel()
        if state["mail"]:
            state["mail"].stop()

    app = FastAPI(title="Household Agent brain", version=__version__, lifespan=lifespan)
    app.state.cfg, app.state.db, app.state.pipeline, app.state.queue = cfg, db, pipeline, queue
    app.state.health, app.state.settings, app.state.daily = health, settings, daily
    app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
    templates = Jinja2Templates(directory=HERE / "templates")
    env = templates.env

    # ---- template helpers -------------------------------------------------------------
    def localtime(value: Any, fmt: str = "%a %b %-d, %-I:%M %p") -> str:
        if not value:
            return ""
        try:
            dt = value if isinstance(value, datetime) else datetime.fromisoformat(str(value))
            return dt.astimezone(cfg.tz).strftime(fmt)
        except ValueError:
            return str(value)

    env.filters["localtime"] = localtime
    env.filters["pretty"] = lambda v: json.dumps(v, indent=2, ensure_ascii=False, default=str)
    env.filters["handle"] = normalize_handle

    def nicedate(value: str | None) -> str:
        if not value:
            return ""
        try:
            if len(value) == 10:
                return datetime.fromisoformat(value).strftime("%a %b %-d")
            return datetime.fromisoformat(value).strftime("%a %b %-d %-I:%M %p")
        except ValueError:
            return value

    env.filters["nicedate"] = nicedate

    def ref_title(e: dict, ref: int | None) -> str:
        """Title of the open item an action's `ref` pointed at when this event was processed."""
        try:
            ids = json.loads(e.get("open_refs") or "[]")
            it = pipeline.items.get(ids[int(ref) - 1]) if ref else None
        except (ValueError, IndexError, TypeError):
            it = None
        return it["title"] if it else f"item #{ref}"

    def collection_label(key: str | None) -> str:
        c = next((c for c in cfg.collections if c.key == key), None)
        return c.label if c else (key or "")

    env.globals.update(ref_title=ref_title, collection_label=collection_label)
    env.globals.update(badge=lambda s: STATUS_BADGE.get(s, (s, "muted")), version=__version__,
                       step_label=lambda s: STEP_LABEL.get(s, s), icon=icon)

    # ---- auth & CSRF -------------------------------------------------------------------
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

    @app.middleware("http")
    async def same_origin_writes(request: Request, call_next):
        """Dashboard writes must come from the dashboard itself (blocks cross-site form posts)."""
        if request.method not in ("GET", "HEAD", "OPTIONS") and not request.url.path.startswith(AGENT_PATHS):
            site = request.headers.get("sec-fetch-site")
            origin = request.headers.get("origin")
            if site == "cross-site" or (origin and origin != "null"
                                        and urlparse(origin).netloc != request.headers.get("host")):
                return JSONResponse({"error": "cross-origin request blocked"}, status_code=403)
        return await call_next(request)

    def wants_json(request: Request) -> bool:
        return request.headers.get("x-requested-with") == "fetch" or "application/json" in request.headers.get("accept", "")

    # ---- agent API ------------------------------------------------------------------------
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
        bus.publish({"type": "heartbeat"})
        return {"ok": True, "settings_version": settings.version}

    @app.get("/api/agent/tracked", dependencies=[Depends(agent_auth)])
    async def agent_tracked():
        return {"items": pipeline.items.tracked(), "interval_s": 300}

    @app.post("/api/agent/item-status", dependencies=[Depends(agent_auth)])
    async def agent_item_status(report: ItemStatusReport):
        n = pipeline.items.apply_status(report.items)
        if n:
            bus.publish({"type": "items"})
        return {"ok": True, "updated": n}

    @app.get("/api/agent/config", dependencies=[Depends(agent_auth)])
    async def agent_config():
        return settings.agent_config()

    # ---- dashboard JSON ---------------------------------------------------------------------
    @app.get("/api/health", dependencies=[Depends(dash_auth)])
    async def api_health():
        return {"version": __version__, **health.snapshot(queue.depth())}

    @app.get("/api/overview", dependencies=[Depends(dash_auth)])
    async def api_overview():
        ov = views.overview(db, cfg, health.snapshot(queue.depth()))
        ov["settings_version"] = settings.version
        return JSONResponse(json.loads(json.dumps(ov, default=str)))

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

    # ---- settings API ---------------------------------------------------------------------------
    @app.get("/api/settings", dependencies=[Depends(dash_auth)])
    async def get_settings():
        return settings.view()

    @app.patch("/api/settings", dependencies=[Depends(dash_auth)])
    async def patch_settings(patch: dict = Body(...)):
        try:
            changed = settings.update(patch)
        except SettingsError as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=422)
        return {"ok": True, "changed": sorted(changed), **settings.view()}

    @app.post("/api/settings/reset", dependencies=[Depends(dash_auth)])
    async def reset_setting(body: dict = Body(...)):
        try:
            changed = settings.reset(str(body.get("path", "")))
        except SettingsError as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=422)
        return {"ok": True, "changed": sorted(changed), **settings.view()}

    @app.post("/api/settings/test-llm", dependencies=[Depends(dash_auth)])
    async def test_llm(body: dict = Body(default={})):
        base_url = (body.get("base_url") or "").strip() or None
        try:
            if not hasattr(llm, "list_models"):
                return {"ok": True, "models": [cfg.llm.model], "latency_ms": round(await llm.ping())}
            models, ms = await llm.list_models(base_url, body.get("api_key") or None)
        except Exception as e:  # noqa: BLE001 — shown in the UI
            return {"ok": False, "error": f"{type(e).__name__}: {e}"[:400]}
        model = body.get("model") or cfg.llm.model
        return {"ok": True, "models": models, "latency_ms": round(ms), "model_found": model in models}

    @app.post("/api/system/test-alert", dependencies=[Depends(dash_auth)])
    async def test_alert():
        if not cfg.alerts.discord_webhook_url:
            return {"ok": False, "error": "No Discord webhook configured."}
        ok = await alerter.send("test", "🔔 Test alert from the Household Agent dashboard.")
        return {"ok": ok, "error": None if ok else "Discord rejected the webhook call — check the URL."}

    @app.post("/api/system/backup", dependencies=[Depends(dash_auth)])
    async def backup_now():
        path = await backup_if_due(cfg, db, force=True)
        return {"ok": bool(path), "path": path}

    # ---- today / daily ------------------------------------------------------------------------
    @app.post("/api/today/{what}", dependencies=[Depends(dash_auth)])
    async def today_action(what: str, body: dict = Body(default={})):
        if what == "repick":
            plan = await daily.morning(force=True)
            return {"ok": True, "picks": plan["picks"]}
        if what == "morning":
            day = daily.today()
            plan = daily.plan(day)
            if not plan.get("picks"):
                plan = await daily.morning()
            elif cfg.daily.discord:
                await alerter.send("daily", daily.morning_text(day, plan))
            return {"ok": True}
        if what == "evening":
            await daily.evening(force=True)
            return {"ok": True}
        if what == "tomorrow":
            ids = [str(i) for i in body.get("item_ids", [])]
            from datetime import timedelta as _td
            daily.preselect(daily.today() + _td(days=1), ids)
            return {"ok": True}
        raise HTTPException(404)

    @app.post("/api/items/{item_id}/breakdown", dependencies=[Depends(dash_auth)])
    async def item_breakdown(item_id: str):
        try:
            return {"ok": True, **(await daily.breakdown(item_id))}
        except (ValueError, LLMError) as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=422)

    # ---- pages -------------------------------------------------------------------------------
    def page(request: Request, name: str, nav: str, **ctx: Any) -> HTMLResponse:
        review = db.one("SELECT COUNT(*) n FROM events WHERE status=?", (m.NEEDS_REVIEW,))["n"]
        return templates.TemplateResponse(request, name, {
            "cfg": cfg, "nav": nav, "review_count": review, "agent_online": health.agent_online(),
            "llm_ok": health.llm_fail_streak == 0 and health.llm_last_ok is not None, **ctx})

    @app.get("/", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def overview_page(request: Request):
        ov = views.overview(db, cfg, health.snapshot(queue.depth()))
        tplan = daily.plan(daily.today())
        today_picks = [{**p, "status": (pipeline.items.get(p["item_id"]) or {}).get("status", "gone")}
                       for p in tplan.get("picks", [])]
        return page(request, "overview.html", "overview", ov=ov, today_picks=today_picks, recent=views.search_events(
            db, q=None, status=None, source=None, limit=8), upcoming=views.upcoming(db, cfg),
            prompt_version=pipeline.prompt.version)

    @app.get("/today", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def today_page(request: Request):
        from datetime import timedelta as _td
        day = daily.today()
        plan = daily.plan(day)
        picks = []
        for p in plan.get("picks", []):
            it = pipeline.items.get(p["item_id"])
            picks.append({**p, "status": it["status"] if it else "gone", "item": it})
        tomorrow = daily.plan(day + _td(days=1))
        chosen = tomorrow.get("preselected") or [s["item_id"] for s in tomorrow.get("suggested", [])]
        return page(request, "today.html", "today", day=day, plan=plan, picks=picks, done=daily.done_on(day),
                    events=daily.events_on(day), candidates=daily.candidates(datetime.now(cfg.tz), limit=15),
                    tomorrow_chosen=chosen, tomorrow_locked=bool(tomorrow.get("preselected")))

    @app.get("/activity", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def activity_page(request: Request, status: str | None = None, q: str | None = None,
                            source: str | None = None, limit: int = 150):
        events = views.search_events(db, q=q, status=status or None, source=source or None, limit=min(limit, 500))
        return page(request, "activity.html", "activity", events=events, status=status, q=q or "",
                    source=source, counts=views.status_counts(db), statuses=list(STATUS_BADGE))

    @app.get("/review", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def review_page(request: Request):
        items = []
        for e in db.recent_events(limit=200, status=m.NEEDS_REVIEW):
            cmds = [c for c in db.commands_for_event(e["event_id"]) if c["generation"] == e["generation"]]
            items.append({"e": e, "cmds": [c for c in cmds if c["status"] == "held"]})
        return page(request, "review.html", "review", items=items)

    @app.get("/items", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def items_page(request: Request, tab: str = "todos"):
        reg = pipeline.items
        counts = {
            "todos": len(reg.listing(statuses=("proposed", "planned", "active"), collection=None)),
            "collections": len(reg.listing(statuses=("planned", "active"), collection=True)),
            "history": len(reg.listing(statuses=("completed", "cancelled", "undone", "rejected", "failed", "deleted"))),
        }
        groups: dict[str, dict[str, list]] = {}
        if tab == "collections":
            rows = views.item_cards(db, reg.listing(statuses=("planned", "active"), collection=True))
            for it in rows:
                groups.setdefault(it["collection"], {}).setdefault(it["person"] or "Unassigned", []).append(it)
            rows = []
        elif tab == "history":
            rows = views.item_cards(db, reg.listing(statuses=("completed", "cancelled", "undone", "rejected", "failed",
                                                              "deleted"),
                                                    limit=200))
        else:
            tab = "todos"
            rows = views.item_cards(db, reg.listing(statuses=("proposed", "planned", "active"), collection=None))
        return page(request, "items.html", "items", tab=tab, rows=rows, groups=groups, counts=counts,
                    upcoming=views.upcoming(db, cfg, 14))

    @app.get("/partials/row/{event_id:path}", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def row_partial(request: Request, event_id: str):
        ev = db.get_event(event_id)
        if not ev:
            return HTMLResponse("", status_code=404)
        return templates.TemplateResponse(request, "_row.html", {"e": ev})

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
            "undo": any(c["status"] == "done" and not c["undo_of"] for c in gen_cmds)
                    and ev["status"] not in (m.UNDONE, m.UNDOING),
            "retry": ev["status"] not in (m.UNDOING,),
        }
        extraction = ev["extraction"] or {"actionable": True, "actions": [], "confidence": 1.0,
                                          "reasoning_brief": "added manually"}
        trace = db.get_trace(event_id)
        total_ms = sum(t["duration_ms"] or 0 for t in trace)
        return page(request, "event.html", "activity", e=ev, trace=trace, commands=cmds, can=can,
                    total_ms=total_ms, msg=msg, err=err,
                    extraction_json=json.dumps(extraction, indent=2, ensure_ascii=False))

    @app.post("/actions/{action}/{event_id:path}", dependencies=[Depends(dash_auth)])
    async def do_action(request: Request, action: str, event_id: str, extraction: str | None = Form(None)):
        fns = {
            "approve": lambda: pipeline.approve(event_id),
            "reject": lambda: pipeline.reject(event_id),
            "undo": lambda: pipeline.undo(event_id),
            "retry": lambda: pipeline.retry(event_id),
            "reprocess": lambda: pipeline.reprocess_with(event_id, extraction or ""),
        }
        if action not in fns:
            raise HTTPException(404)
        try:
            await fns[action]()
            error = None
        except ActionError as e:
            error = str(e)
        if wants_json(request):
            row = db.get_event(event_id)
            return JSONResponse({"ok": error is None, "error": error, "status": row["status"] if row else None},
                                status_code=200 if error is None else 409)
        q = "?err=" + quote(error) if error else "?msg=" + quote("Done.")
        return RedirectResponse(f"/events/{quote(event_id)}{q}", status_code=303)

    @app.get("/system", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def system_page(request: Request):
        return page(request, "system.html", "system", h=health.snapshot(queue.depth()),
                    alerts=db.all("SELECT * FROM alerts ORDER BY id DESC LIMIT 40"),
                    commands=views.open_commands(db), last_backup=db.kv_get("last_backup"),
                    prompt=pipeline.prompt, dbinfo=views.db_info(db), history=settings.history(25),
                    funnel=views.funnel(db, 24), latency=views.latency(db), settings_version=settings.version,
                    agent_cfg=settings.agent_config())

    @app.get("/settings", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def settings_page(request: Request):
        return page(request, "settings.html", "settings", s=settings.view(),
                    allow=[a.model_dump() for a in cfg.watch.imessage.allow],
                    agent=health.agent, history=settings.history(10))

    @app.get("/lab", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def lab(request: Request):
        return page(request, "lab.html", "lab", result=None, form={})

    @app.post("/lab", response_class=HTMLResponse, dependencies=[Depends(dash_auth)])
    async def lab_run(request: Request, text: str = Form(...), who: str = Form(""),
                      context: str = Form(""), now: str = Form(""), from_me: bool = Form(False)):
        """Dry run: extraction + plan, nothing stored, nothing sent to the Mac."""
        when = datetime.fromisoformat(now).replace(tzinfo=cfg.tz) if now else datetime.now(cfg.tz)
        entry = next((a for a in cfg.watch.imessage.allow if (a.handle or a.chat_id) == who), None)
        ev = Event(event_id="lab", source="imessage", sender_handle=(entry.handle if entry else "") or "",
                   chat_id=entry.chat_id if entry else None, sender_label=(entry.label if entry else None) or "Them",
                   is_from_me=from_me, received_at=when, text=text,
                   recent_context=[l for l in context.splitlines() if l.strip()])
        open_items = pipeline.items.open_for(chat_key(ev), datetime.now(cfg.tz)) if entry else []
        result: dict[str, Any] = {"gate": gate(cfg, ev), "open_items": open_items}
        try:
            res = await extract(cfg, llm, pipeline.prompt, ev, when, open_items)
            p = plan(cfg, ev, res.extraction, when, open_items=open_items)
            result.update(prompt=res.messages, raw=res.raw, parsed=res.extraction.model_dump(),
                          ms=res.duration_ms, commands=[c.model_dump() for c in p.commands],
                          review=p.review_reasons, skipped=p.skipped)
        except LLMError as e:
            result.update(error=str(e), raw=getattr(e, "raw", None))
        return page(request, "lab.html", "lab", result=result,
                    form={"text": text, "who": who, "context": context, "now": now, "from_me": from_me})

    # old URLs
    for old, new in {"/health": "/system", "/stats": "/", "/playground": "/lab"}.items():
        app.add_api_route(old, (lambda n: (lambda: RedirectResponse(n, status_code=301)))(new),
                          methods=["GET"], include_in_schema=False)

    @app.get("/favicon.ico")
    async def favicon():
        return Response(status_code=204)

    return app


def factory() -> FastAPI:
    """Entry point: `uvicorn app.main:factory --factory`."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    return create_app()
