import json
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from app.config import Config
from app.main import create_app

TZ = ZoneInfo("America/Chicago")
TOKEN = "test-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class FakeLLM:
    """Returns canned extractions. `responder(user_prompt) -> dict | str | Exception`."""

    def __init__(self):
        self.responder = lambda prompt: {"actionable": False, "actions": [], "confidence": 0.9,
                                         "reasoning_brief": "chit-chat"}
        self.calls: list[list[dict]] = []
        self.json_calls: list = []
        self.json_responder = lambda name, messages: RuntimeError("no json responder set")

    async def complete(self, messages):
        self.calls.append(messages)
        out = self.responder(messages[-1]["content"])
        if isinstance(out, Exception):
            raise out
        return out if isinstance(out, str) else json.dumps(out)

    async def ping(self):
        return 12.0

    async def complete_json(self, messages, schema, name):
        self.json_calls.append((name, messages))
        out = self.json_responder(name, messages)
        if isinstance(out, Exception):
            raise out
        return out if isinstance(out, str) else json.dumps(out)


class FakeAlerter:
    def __init__(self):
        self.sent: list[tuple[str, str]] = []

    async def send(self, kind, message, **kw):
        self.sent.append((kind, message))
        return True


def make_cfg(tmp_path, **over) -> Config:
    raw = {
        "timezone": "America/Chicago",
        "watch": {"imessage": {"allow": [{"handle": "+1 (785) 555-0000", "label": "Wife"}]},
                  "mail": {"allow_senders": ["*@school.example.org"], "labels": {"*@school.example.org": "School"}}},
        "rules": {"default_alert_time": "16:00", "review_threshold": 0.75,
                  "reminder_list": "Household",
                  "calendars": {"default": "Family"}},
        "security": {"agent_token": TOKEN},
        "storage": {"db_path": str(tmp_path / "brain.db"), "backup_dir": str(tmp_path / "backups")},
        "dashboard": {"public_url": "http://brain:8080"},
    }
    raw.update(over)
    return Config.model_validate(raw)


def reminder(title, due=None, time=None, lst=None, conf=0.95, quote=""):
    return {"type": "create_reminder", "title": title, "list": lst, "due_date": due, "due_time": time,
            "start": None, "end": None, "all_day": False, "location": None, "calendar": None,
            "notes": None, "source_quote": quote or title}


def event(title, start, end=None, all_day=False, location=None):
    return {"type": "create_event", "title": title, "list": None, "due_date": None, "due_time": None,
            "start": start, "end": end, "all_day": all_day, "location": location, "calendar": None,
            "notes": None, "source_quote": title}


def extraction(*actions, conf=0.95):
    return {"actionable": bool(actions), "actions": list(actions), "confidence": conf, "reasoning_brief": "test"}


def msg(event_id="imessage:1", text="Can you grab eggs tomorrow? We're out", handle="+17855550000", **kw):
    body = {"event_id": event_id, "source": "imessage", "sender_handle": handle,
            "chat_id": f"iMessage;-;{handle}", "received_at": datetime.now(TZ).isoformat(), "text": text,
            "recent_context": ["Me: heading home soon", "Wife: ok"]}
    body.update(kw)
    return body


@pytest.fixture
def llm():
    return FakeLLM()


@pytest.fixture
def alerter():
    return FakeAlerter()


@pytest.fixture
def cfg(tmp_path):
    return make_cfg(tmp_path)


@pytest.fixture
def client(cfg, llm, alerter):
    app = create_app(cfg, llm=llm, alerter=alerter, background=False)
    with TestClient(app) as c:
        c.app_state = app.state
        yield c
