"""Pydantic models for the wire contracts (see docs/API.md) and the LLM output."""
from __future__ import annotations

from datetime import datetime
from typing import Any, List, Literal

from pydantic import BaseModel, Field


class Event(BaseModel):
    event_id: str = Field(min_length=1, max_length=300)
    source: Literal["imessage", "mail", "manual", "capture"] = "imessage"
    sender_handle: str = ""
    sender_label: str | None = None
    chat_id: str | None = None
    is_from_me: bool = False
    received_at: datetime
    text: str = Field(max_length=20000)
    recent_context: list[str] = Field(default_factory=list)
    subject: str | None = None  # mail only


ActionType = Literal["create_reminder", "create_event", "save_to_collection", "track_promise", "waiting_on",
                     "update_item", "complete_item", "cancel_item"]
CREATE_TYPES = ("create_reminder", "create_event", "save_to_collection", "track_promise", "waiting_on")
ITEM_TYPES = ("update_item", "complete_item", "cancel_item")


class Action(BaseModel):
    type: ActionType
    ref: int | None = None          # open item number, for update/complete/cancel
    collection: str | None = None   # for save_to_collection
    person: str | None = None       # who a saved note is about (default: the sender)
    title: str = ""
    list: str | None = None         # ignored: to-dos go to rules.reminder_list
    due_date: str | None = None     # YYYY-MM-DD
    due_time: str | None = None     # HH:MM (24h, local)
    start: str | None = None        # YYYY-MM-DDTHH:MM (local) or YYYY-MM-DD when all_day
    end: str | None = None
    all_day: bool = False
    location: str | None = None
    calendar: str | None = None
    url: str | None = None
    notes: str | None = None
    summary: str | None = None      # one-line context summary, goes in the item's notes
    first_step: str | None = None   # tiny concrete way to start a big/vague task
    steps: List[str] = Field(default_factory=lambda: [])  # `list` is shadowed by the field above
    source_quote: str = ""


class Extraction(BaseModel):
    actionable: bool
    actions: list[Action] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0)
    reasoning_brief: str = ""


def _nullable(t: str, **extra: Any) -> dict[str, Any]:
    return {"type": [t, "null"], **extra}


ACTION_FIELDS = ["type", "ref", "collection", "person", "title", "due_date", "due_time", "start", "end",
                 "all_day", "location", "url", "notes", "summary", "first_step", "steps", "source_quote"]

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
                "required": ACTION_FIELDS,
                "properties": {
                    "type": {"type": "string", "enum": list(ActionType.__args__)},
                    "ref": _nullable("integer", description="open item number for update/complete/cancel"),
                    "collection": _nullable("string", description="collection key for save_to_collection"),
                    "person": _nullable("string"),
                    "title": {"type": "string"},
                    "due_date": _nullable("string", description="YYYY-MM-DD"),
                    "due_time": _nullable("string", description="HH:MM 24h local"),
                    "start": _nullable("string", description="YYYY-MM-DDTHH:MM local, or YYYY-MM-DD if all_day"),
                    "end": _nullable("string", description="YYYY-MM-DDTHH:MM local, or YYYY-MM-DD if all_day"),
                    "all_day": {"type": "boolean"},
                    "location": _nullable("string"),
                    "url": _nullable("string"),
                    "notes": _nullable("string"),
                    "summary": _nullable("string"),
                    "first_step": _nullable("string", description="tiny concrete first step for big/vague tasks"),
                    "steps": {"type": "array", "maxItems": 5, "items": {"type": "string"}},
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
    reminderkit_ok: bool | None = None  # sections + tags available on the Mac
    contacts_ok: bool | None = None     # Contacts access for photos
    allowlist_version: int | None = None
    allowlist_size: int | None = None


class ItemStatus(BaseModel):
    """What the Mac sees for a tracked item (completion sync)."""
    apple_item_id: str
    kind: Literal["reminder", "event"] = "reminder"
    exists: bool = True
    completed: bool | None = None
    completed_at: datetime | None = None
    title: str | None = None
    due: str | None = None
    due_time: str | None = None
    start: str | None = None
    end: str | None = None
    found_id: str | None = None


class ItemStatusReport(BaseModel):
    items: list[ItemStatus] = Field(default_factory=list, max_length=500)


class CommandResult(BaseModel):
    status: Literal["done", "failed"]
    apple_item_id: str | None = None
    error: str | None = None
    warning: str | None = None  # done, but e.g. section/tags fell back to the name in the title


class PlannedCommand(BaseModel):
    op: Literal["create_reminder", "create_event", "update_item", "delete_item"]
    payload: dict[str, Any]
    purpose: Literal["create", "update", "complete", "cancel"] = "create"
    item_id: str | None = None                 # existing item this acts on
    new_item: dict[str, Any] | None = None     # registry row to create (for creates)
    meta: dict[str, Any] | None = None         # brain-only: previous values (for undo), collection…
