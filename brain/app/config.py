"""Configuration loading (config.yaml + env overrides for secrets)."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import yaml
from pydantic import BaseModel, Field, field_validator


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


class ListRoute(BaseModel):
    match: list[str]
    list: str


class ListsConfig(BaseModel):
    default: str = "Household"
    routes: list[ListRoute] = Field(default_factory=list)


class CalendarsConfig(BaseModel):
    default: str = "Family"
    default_duration_min: int = 60
    alert_minutes_before: int | None = 30


class RulesConfig(BaseModel):
    default_alert_time: str = "16:00"
    review_threshold: float = 0.75
    create_missing_lists: bool = True
    lists: ListsConfig = Field(default_factory=ListsConfig)
    calendars: CalendarsConfig = Field(default_factory=CalendarsConfig)

    @field_validator("default_alert_time")
    @classmethod
    def _hhmm(cls, v: str) -> str:
        h, m = v.split(":")
        assert 0 <= int(h) < 24 and 0 <= int(m) < 60
        return f"{int(h):02d}:{int(m):02d}"


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

    @property
    def tz(self) -> ZoneInfo:
        return ZoneInfo(self.timezone)

    def known_lists(self) -> list[str]:
        names = [self.rules.lists.default] + [r.list for r in self.rules.lists.routes]
        return list(dict.fromkeys(names))


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


def load_config(path: str | os.PathLike | None = None) -> Config:
    path = path or os.environ.get("HA_CONFIG", "/config/config.yaml")
    raw: dict[str, Any] = {}
    p = Path(path)
    if p.exists():
        raw = yaml.safe_load(p.read_text()) or {}
    for env, keypath in ENV_OVERRIDES.items():
        if os.environ.get(env):
            _set_path(raw, keypath, os.environ[env])
    return Config.model_validate(raw)
