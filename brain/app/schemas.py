"""Pydantic models for the wire contracts (see docs/API.md) and the LLM output."""
from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field


class Event(BaseModel):
    event_id: str = Field(min_length=1, max_length=300)
    source: Literal["imessage", "mail", "manual"] = "imessage"
    sender_handle: str = ""
    sender_label: str | None = None
    chat_id: str | None = None
    is_from_me: bool = False
    received_at: datetime
    text: str = Field(max_length=20000)
    recent_context: list[str] = Field(default_factory=list)
    subject: str | None = None  # mail only


ActionType = Literal["create_reminder", "create_event"]


class Action(BaseModel):
    type: ActionType
    title: str
    list: str | None = None  # ignored: every reminder goes to rules.reminder_list
    due_date: str | None = None  # YYYY-MM-DD
    due_time: str | None = None  # HH:MM (24h, local)
    start: str | None = None  # YYYY-MM-DDTHH:MM (local) or YYYY-MM-DD when all_day
    end: str | None = None
    all_day: bool = False
    location: str | None = None
    calendar: str | None = None
    notes: str | None = None
    source_quote: str = ""


class Extraction(BaseModel):
    actionable: bool
    actions: list[Action] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0)
    reasoning_brief: str = ""


def _nullable(t: str, **extra: Any) -> dict[str, Any]:
    return {"type": [t, "null"], **extra}


# Flat schema, every field required (nullable where optional) — best for constrained decoding.
EXTRACTION_JSON_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["actionable", "actions", "confidence", "reasoning_brief"],
    "properties": {
        "actionable": {"type": "boolean"},
        "actions": {
            "type": "array",
            "maxItems": 10,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": [
                    "type", "title", "due_date", "due_time", "start", "end",
                    "all_day", "location", "calendar", "notes", "source_quote",
                ],
                "properties": {
                    "type": {"type": "string", "enum": ["create_reminder", "create_event"]},
                    "title": {"type": "string"},
                    "due_date": _nullable("string", description="YYYY-MM-DD"),
                    "due_time": _nullable("string", description="HH:MM 24h local"),
                    "start": _nullable("string", description="YYYY-MM-DDTHH:MM local, or YYYY-MM-DD if all_day"),
                    "end": _nullable("string", description="YYYY-MM-DDTHH:MM local, or YYYY-MM-DD if all_day"),
                    "all_day": {"type": "boolean"},
                    "location": _nullable("string"),
                    "calendar": _nullable("string"),
                    "notes": _nullable("string"),
                    "source_quote": {"type": "string"},
                },
            },
        },
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "reasoning_brief": {"type": "string"},
    },
}


class Heartbeat(BaseModel):
    agent_version: str = "unknown"
    last_rowid: int | None = None
    fda_ok: bool = False
    reminders_ok: bool = False
    calendar_ok: bool = False
    uptime_s: float = 0
    buffered_events: int = 0
    allowlist_version: int | None = None
    allowlist_size: int | None = None


class CommandResult(BaseModel):
    status: Literal["done", "failed"]
    apple_item_id: str | None = None
    error: str | None = None


class PlannedCommand(BaseModel):
    op: Literal["create_reminder", "create_event", "delete_item"]
    payload: dict[str, Any]
