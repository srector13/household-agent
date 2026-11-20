"""LLM extraction: render the prompt, call vLLM (OpenAI-compatible) with a JSON schema, parse."""
from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Protocol

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


def build_messages(cfg: Config, tpl: PromptTemplate, ev: Event, now: datetime) -> list[dict[str, str]]:
    now = now.astimezone(cfg.tz)
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
        "lists": json.dumps(cfg.known_lists()),
        "calendars": json.dumps([cfg.rules.calendars.default]),
        "context": "\n".join(f"- {c}" for c in ev.recent_context[-5:]) or "(none)",
        "sender": ev.sender_label or ev.sender_handle or "unknown",
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
    def __init__(self, cfg: LLMConfig):
        self.cfg = cfg
        headers = {"Authorization": f"Bearer {cfg.api_key}"} if cfg.api_key else {}
        self.http = httpx.AsyncClient(base_url=cfg.base_url.rstrip("/"), timeout=cfg.timeout_s, headers=headers)

    def request_body(self, messages: list[dict[str, str]]) -> dict[str, Any]:
        body: dict[str, Any] = {
            "model": self.cfg.model,
            "messages": messages,
            "temperature": self.cfg.temperature,
            "max_tokens": self.cfg.max_tokens,
            "response_format": {
                "type": "json_schema",
                "json_schema": {"name": "extraction", "schema": EXTRACTION_JSON_SCHEMA, "strict": True},
            },
        }
        if self.cfg.disable_thinking:
            body["chat_template_kwargs"] = {"enable_thinking": False}
        return body

    async def complete(self, messages: list[dict[str, str]]) -> str:
        last: Exception | None = None
        for attempt in range(2):  # timeout + 1 retry
            try:
                r = await self.http.post("/chat/completions", json=self.request_body(messages))
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

    async def ping(self) -> float:
        t = time.perf_counter()
        r = await self.http.get("/models", timeout=5)
        r.raise_for_status()
        return (time.perf_counter() - t) * 1000

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


async def extract(cfg: Config, llm: LLMClient, tpl: PromptTemplate, ev: Event, now: datetime) -> ExtractResult:
    messages = build_messages(cfg, tpl, ev, now)
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
