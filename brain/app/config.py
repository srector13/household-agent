"""Configuration loading (config.yaml + env overrides for secrets)."""
from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import yaml
from pydantic import BaseModel, Field, field_validator, model_validator


class LLMConfig(BaseModel):
    base_url: str = "http://localhost:8000/v1"
    model: str = "qwen"
    api_key: str | None = None
    temperature: float = 0.0
    disable_thinking: bool = True
    timeout_s: float = 30.0
    max_tokens: int = 1024


class AllowEntry(BaseModel):
    handle: str | None = None
    chat_id: str | None = None
    label: str | None = None
    enabled: bool = True

    @model_validator(mode="after")
    def _check(self):
        self.handle = (self.handle or "").strip() or None
        self.chat_id = (self.chat_id or "").strip() or None
        self.label = (self.label or "").strip() or None
        if not self.handle and not self.chat_id:
            raise ValueError("each entry needs a phone number, email or chat id")
        if self.handle and "@" not in self.handle and len(re.sub(r"\D", "", self.handle)) < 7:
            raise ValueError(f"{self.handle!r} doesn't look like a phone number or email")
        return self


class IMessageWatch(BaseModel):
    allow: list[AllowEntry] = Field(default_factory=list)
    allow_self_notes: bool = False


class MailWatch(BaseModel):
    enabled: bool = False
    host: str = ""
    port: int = 993
    username: str = ""
    password: str | None = None
    folders: list[str] = Field(default_factory=lambda: ["INBOX"])
    allow_senders: list[str] = Field(default_factory=list)
    labels: dict[str, str] = Field(default_factory=dict)


class WatchConfig(BaseModel):
    imessage: IMessageWatch = Field(default_factory=IMessageWatch)
    mail: MailWatch = Field(default_factory=MailWatch)


class CalendarsConfig(BaseModel):
    default: str = "Family"
    default_duration_min: int = 60
    alert_minutes_before: int | None = 30


class RulesConfig(BaseModel):
    default_alert_time: str = "16:00"
    review_threshold: float = Field(0.75, ge=0, le=1)
    reminder_list: str = Field("Household", min_length=1)  # every reminder goes to this one list
    create_missing_lists: bool = True
    calendars: CalendarsConfig = Field(default_factory=CalendarsConfig)

    @model_validator(mode="before")
    @classmethod
    def _migrate_lists(cls, data):
        # v0.1 had `lists: {default, routes}`; routing is gone, the default list is the one list.
        if isinstance(data, dict) and "lists" in data:
            data = dict(data)
            old = data.pop("lists") or {}
            if "reminder_list" not in data and isinstance(old, dict) and old.get("default"):
                data["reminder_list"] = old["default"]
        return data

    @field_validator("default_alert_time")
    @classmethod
    def _hhmm(cls, v: str) -> str:
        m = re.fullmatch(r"\s*(\d{1,2}):(\d{2})(?::\d{2})?\s*", v or "")
        if not m or int(m.group(1)) > 23 or int(m.group(2)) > 59:
            raise ValueError("use a 24-hour time like 16:00")
        return f"{int(m.group(1)):02d}:{m.group(2)}"


class AlertsConfig(BaseModel):
    discord_webhook_url: str | None = None
    heartbeat_timeout_s: int = 180


class DashboardConfig(BaseModel):
    public_url: str = "http://localhost:8080"
    password: str | None = None


class SecurityConfig(BaseModel):
    agent_token: str = ""


class StorageConfig(BaseModel):
    db_path: str = "/data/brain.db"
    backup_dir: str = "/data/backups"
    backup_keep: int = 14


class Config(BaseModel):
    timezone: str = "America/Chicago"
    llm: LLMConfig = Field(default_factory=LLMConfig)
    watch: WatchConfig = Field(default_factory=WatchConfig)
    rules: RulesConfig = Field(default_factory=RulesConfig)
    alerts: AlertsConfig = Field(default_factory=AlertsConfig)
    dashboard: DashboardConfig = Field(default_factory=DashboardConfig)
    security: SecurityConfig = Field(default_factory=SecurityConfig)
    storage: StorageConfig = Field(default_factory=StorageConfig)

    @field_validator("timezone")
    @classmethod
    def _tz(cls, v: str) -> str:
        try:
            ZoneInfo(v)
        except Exception as e:  # ZoneInfoNotFoundError is a KeyError, not a ValueError
            raise ValueError(f"unknown timezone {v!r}") from e
        return v

    @property
    def tz(self) -> ZoneInfo:
        return ZoneInfo(self.timezone)


ENV_OVERRIDES: dict[str, tuple[str, ...]] = {
    "HA_AGENT_TOKEN": ("security", "agent_token"),
    "HA_DISCORD_WEBHOOK_URL": ("alerts", "discord_webhook_url"),
    "HA_MAIL_PASSWORD": ("watch", "mail", "password"),
    "HA_DASHBOARD_PASSWORD": ("dashboard", "password"),
    "HA_DB_PATH": ("storage", "db_path"),
    "HA_LLM_BASE_URL": ("llm", "base_url"),
    "HA_LLM_MODEL": ("llm", "model"),
}


def _set_path(d: dict[str, Any], path: tuple[str, ...], value: str) -> None:
    for key in path[:-1]:
        if not isinstance(d.get(key), dict):
            d[key] = {}
        d = d[key]
    d[path[-1]] = value


def load_raw(path: str | os.PathLike | None = None) -> dict[str, Any]:
    """config.yaml + env overrides, as a plain dict (the base the dashboard's edits sit on)."""
    path = path or os.environ.get("HA_CONFIG", "/config/config.yaml")
    raw: dict[str, Any] = {}
    p = Path(path)
    if p.exists():
        raw = yaml.safe_load(p.read_text()) or {}
    for env, keypath in ENV_OVERRIDES.items():
        if os.environ.get(env):
            _set_path(raw, keypath, os.environ[env])
    return raw


def load_config(path: str | os.PathLike | None = None) -> Config:
    return Config.model_validate(load_raw(path))
