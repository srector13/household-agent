"""LLM extraction: render the prompt, call vLLM (OpenAI-compatible) with a JSON schema, parse."""
from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Protocol

import httpx
import yaml
from pydantic import ValidationError

from .config import Config, LLMConfig
from .schemas import EXTRACTION_JSON_SCHEMA, Event, Extraction

PROMPT_PATH = Path(__file__).parent / "prompts" / "extract.md"
USER_SPLIT = "=== USER ==="


@dataclass
class PromptTemplate:
    version: str
    system: str
    user: str

    @classmethod
    def load(cls, path: Path = PROMPT_PATH) -> "PromptTemplate":
        text = path.read_text()
        version = "unversioned"
        if text.startswith("---"):
            _, front, text = text.split("---", 2)
            version = (yaml.safe_load(front) or {}).get("version", version)
        system, _, user = text.partition(USER_SPLIT)
        return cls(version=version, system=system.strip(), user=user.strip())


def _render(template: str, values: dict[str, str]) -> str:
    return re.sub(r"\{\{(\w+)\}\}", lambda m: values.get(m.group(1), m.group(0)), template)


def describe_item(cfg: Config, it: dict) -> str:
    st = it["state"]
    if it.get("collection"):
        col = next((c for c in cfg.collections if c.key == it["collection"]), None)
        what = f"Saved to {col.label if col else it['collection']} ({it.get('person') or '?'})"
    elif it.get("category") == "promise":
        what = f"My promise to {it.get('person') or '?'}"
    elif it.get("category") == "waiting":
        what = f"Waiting on {it.get('person') or '?'}"
    else:
        what = "To-do" if it["kind"] == "reminder" else "Event"
    bits = [f"{what}: “{it['title']}”"]
    if it["kind"] == "reminder" and st.get("due"):
        d = datetime.fromisoformat(st["due"]).strftime("%a %b %-d")
        bits.append(f"due {d}" + (f" {st['due_time']}" if st.get("due_time") else ""))
    elif it["kind"] == "reminder" and not it.get("collection") and it.get("category") != "waiting":
        bits.append("no due date")
    if it["kind"] == "event" and st.get("start"):
        s = datetime.fromisoformat(st["start"]).astimezone(cfg.tz)
        bits.append(s.strftime("%a %b %-d") + ("" if st.get("all_day") else s.strftime(" %-I:%M %p")))
    if it.get("status") == "proposed":
        bits.append("awaiting my approval")
    created = datetime.fromisoformat(it["created_at"]).astimezone(cfg.tz).strftime("%a %-I:%M %p")
    bits.append(f"created {created}")
    return " — ".join(bits)


def build_messages(cfg: Config, tpl: PromptTemplate, ev: Event, now: datetime,
                   open_items: list[dict] | None = None, lists: list[str] | None = None) -> list[dict[str, str]]:
    now = now.astimezone(cfg.tz)
    from .gate import self_chat
    is_self = self_chat(cfg, ev)
    days = []
    for i in range(0, 15):
        d = now.date() + timedelta(days=i)
        tag = " (today)" if i == 0 else " (tomorrow)" if i == 1 else ""
        days.append(f"- {d.strftime('%a')} {d.isoformat()}{tag}")
    received = ev.received_at.astimezone(cfg.tz)
    values = {
        "now": now.strftime("%Y-%m-%d %H:%M"),
        "weekday": now.strftime("%A"),
        "timezone": cfg.timezone,
        "calendar": "\n".join(days),
        "calendars": json.dumps([cfg.rules.calendars.default]),
        "context": "\n".join(f"- {c}" for c in ev.recent_context[-5:]) or "(none)",
        "sender": ev.sender_label or ev.sender_handle or "unknown",
        "open_items": "\n".join(f"{i}. {describe_item(cfg, it)}" for i, it in enumerate(open_items or [], 1))
                      or "(none)",
        "lists": ", ".join(f"“{n}”" for n in (lists or [])) or "(none — leave `list` null)",
        "collections": "\n".join(f"  - `{c.key}`: {c.description}" for c in cfg.collections if c.enabled)
                       or "  (none configured — do not use save_to_collection)",
        "direction": ("New note I wrote to MYSELF (notes-to-self capture)" if is_self
                      else f"New message from ME (the user) to {ev.sender_label or ev.sender_handle}" if ev.is_from_me
                      else f"New message from {ev.sender_label or ev.sender_handle or 'unknown'}"),
        "direction_rules": (
            "- This is my own notes-to-self thread: everything in it is something I want captured for me."
            if is_self else (
            "- This new message was written by ME (the user), not by the other person. \"I'll do it tomorrow\" "
            "about an open item → update_item with tomorrow's date; \"done\"/\"got it\" → complete_item; a NEW "
            "commitment to them (\"I'll send it tonight\") → track_promise; asking them to get back to me → "
            "waiting_on. "
            + ("I may also note other new things for myself." if cfg.watch.imessage.allow_self_notes
               else "Otherwise do NOT create new to-dos from my own message.")
        )) if ev.is_from_me else "",
        "received": received.strftime("%a %Y-%m-%d %H:%M"),
        "subject": f"Subject: {ev.subject}\n" if ev.subject else "",
        "message": ev.text.strip(),
    }
    return [
        {"role": "system", "content": _render(tpl.system, values)},
        {"role": "user", "content": _render(tpl.user, values)},
    ]


class LLMError(Exception):
    pass


class LLMUnavailable(LLMError):
    """Network/timeout/5xx — the event should stay `received` and be retried later."""


class LLMClient(Protocol):
    async def complete(self, messages: list[dict[str, str]]) -> str: ...
    async def ping(self) -> float: ...


class VLLMClient:
    """OpenAI-compatible client. Reads its LLMConfig on every call, so dashboard edits apply live."""

    def __init__(self, cfg: LLMConfig | Callable[[], LLMConfig]):
        self._get = cfg if callable(cfg) else (lambda: cfg)
        self.http = httpx.AsyncClient()

    @property
    def cfg(self) -> LLMConfig:
        return self._get()

    @staticmethod
    def _headers(api_key: str | None) -> dict[str, str]:
        return {"Authorization": f"Bearer {api_key}"} if api_key else {}

    def request_body(self, messages: list[dict[str, str]]) -> dict[str, Any]:
        cfg = self.cfg
        body: dict[str, Any] = {
            "model": cfg.model,
            "messages": messages,
            "temperature": cfg.temperature,
            "max_tokens": cfg.max_tokens,
            "response_format": {
                "type": "json_schema",
                "json_schema": {"name": "extraction", "schema": EXTRACTION_JSON_SCHEMA, "strict": True},
            },
        }
        if cfg.disable_thinking:
            body["chat_template_kwargs"] = {"enable_thinking": False}
        return body

    async def complete(self, messages: list[dict[str, str]]) -> str:
        cfg = self.cfg
        url = cfg.base_url.rstrip("/") + "/chat/completions"
        last: Exception | None = None
        for attempt in range(2):  # timeout + 1 retry
            try:
                r = await self.http.post(url, json=self.request_body(messages), timeout=cfg.timeout_s,
                                         headers=self._headers(cfg.api_key))
            except (httpx.TransportError, httpx.TimeoutException) as e:
                last = e
                continue
            if r.status_code >= 500:
                last = LLMUnavailable(f"vLLM HTTP {r.status_code}: {r.text[:300]}")
                continue
            if r.status_code >= 400:
                raise LLMError(f"vLLM HTTP {r.status_code}: {r.text[:500]}")
            data = r.json()
            return data["choices"][0]["message"].get("content") or ""
        raise LLMUnavailable(f"vLLM unreachable after retry: {last!r}")

    async def complete_json(self, messages: list[dict[str, str]], schema: dict[str, Any], name: str) -> str:
        """One structured-output call with any JSON schema (daily picks, task breakdowns…)."""
        cfg = self.cfg
        body = {**self.request_body(messages),
                "response_format": {"type": "json_schema", "json_schema": {"name": name, "schema": schema,
                                                                           "strict": True}}}
        r = await self.http.post(cfg.base_url.rstrip("/") + "/chat/completions", json=body,
                                 timeout=cfg.timeout_s, headers=self._headers(cfg.api_key))
        if r.status_code >= 400:
            raise LLMError(f"vLLM HTTP {r.status_code}: {r.text[:300]}")
        return THINK_RE.sub("", r.json()["choices"][0]["message"].get("content") or "").strip()

    async def list_models(self, base_url: str | None = None, api_key: str | None = None) -> tuple[list[str], float]:
        cfg = self.cfg
        url = (base_url or cfg.base_url).rstrip("/") + "/models"
        t = time.perf_counter()
        r = await self.http.get(url, timeout=5, headers=self._headers(api_key if base_url else cfg.api_key))
        r.raise_for_status()
        ms = (time.perf_counter() - t) * 1000
        return [m.get("id", "?") for m in r.json().get("data", [])], ms

    async def ping(self) -> float:
        return (await self.list_models())[1]

    async def aclose(self) -> None:
        await self.http.aclose()


THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL)


def parse_extraction(raw: str) -> Extraction:
    text = THINK_RE.sub("", raw).strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text)
    if not text.startswith("{"):
        m = re.search(r"\{.*\}", text, re.DOTALL)
        if m:
            text = m.group(0)
    try:
        return Extraction.model_validate(json.loads(text))
    except (json.JSONDecodeError, ValidationError) as e:
        raise LLMError(f"could not parse model output: {e}") from e


@dataclass
class ExtractResult:
    extraction: Extraction
    messages: list[dict[str, str]]
    raw: str
    duration_ms: int
    prompt_version: str
    extra: dict[str, Any] = field(default_factory=dict)


async def extract(cfg: Config, llm: LLMClient, tpl: PromptTemplate, ev: Event, now: datetime,
                  open_items: list[dict] | None = None, lists: list[str] | None = None) -> ExtractResult:
    messages = build_messages(cfg, tpl, ev, now, open_items, lists if cfg.rules.route_to_lists else None)
    t = time.perf_counter()
    raw = await llm.complete(messages)
    ms = int((time.perf_counter() - t) * 1000)
    try:
        extraction = parse_extraction(raw)
    except LLMError as e:
        e.raw = raw  # type: ignore[attr-defined]
        e.messages = messages  # type: ignore[attr-defined]
        e.duration_ms = ms  # type: ignore[attr-defined]
        raise
    return ExtractResult(extraction, messages, raw, ms, tpl.version)
