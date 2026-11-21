"""Dashboard-editable settings.

Effective config = config.yaml (+ env) ⊕ overrides stored in SQLite. Edits are validated as a
whole Config before anything is saved, then applied in place to the live Config object so every
component sees them immediately. Each change bumps `settings_version` (the mac-agent watches it
to re-sync the allowlist) and is written to `settings_history`.
"""
from __future__ import annotations

import copy
import json
from typing import Any, Callable

from pydantic import ValidationError

from .config import Config
from .gate import normalize_handle
from .models import DB, utcnow

# Which keys the dashboard may change. Nested dicts = sections; True = editable leaf.
# Not editable on the web: security.*, storage.*, dashboard.password (file/env only).
EDITABLE: dict[str, Any] = {
    "timezone": True,
    "llm": {"base_url": True, "model": True, "api_key": True, "temperature": True,
            "disable_thinking": True, "timeout_s": True, "max_tokens": True},
    "watch": {
        "imessage": {"allow": True, "allow_self_notes": True},
        "mail": {"enabled": True, "host": True, "port": True, "username": True, "password": True,
                 "folders": True, "allow_senders": True, "labels": True},
    },
    "rules": {"default_alert_time": True, "review_threshold": True, "reminder_list": True,
              "create_missing_lists": True, "self_updates": True, "person_in_title": True, "open_item_days": True,
              "person_tags": True, "track_promises": True, "waiting_list": True, "waiting_default_days": True, "breakdown": True,
              "calendars": {"default": True, "default_duration_min": True, "alert_minutes_before": True}},
    "alerts": {"discord_webhook_url": True, "heartbeat_timeout_s": True},
    "dashboard": {"public_url": True},
    "collections": True,
    "daily": {"enabled": True, "morning_time": True, "evening_time": True, "count": True, "today_view": True,
              "discord": True},
}
SECRETS = {("llm", "api_key"), ("watch", "mail", "password"), ("alerts", "discord_webhook_url")}

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at TEXT NOT NULL,
    path TEXT NOT NULL,
    before TEXT,
    after TEXT,
    action TEXT NOT NULL      -- set | reset
);
"""


class SettingsError(ValueError):
    pass


def deep_merge(base: dict, patch: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def _leaves(d: dict, prefix: tuple = ()) -> list[tuple[tuple, Any]]:
    out = []
    for k, v in d.items():
        if isinstance(v, dict) and not (prefix + (k,) in _dict_leaves()):
            out += _leaves(v, prefix + (k,))
        else:
            out.append((prefix + (k,), v))
    return out


def _dict_leaves() -> set[tuple]:
    # leaves whose *value* is a dict (replace wholesale, don't recurse)
    return {("watch", "mail", "labels")}


def _get(d: dict, path: tuple, default=None):
    for k in path:
        if not isinstance(d, dict) or k not in d:
            return default
        d = d[k]
    return d


def _check_editable(path: tuple) -> None:
    node: Any = EDITABLE
    for k in path:
        if not isinstance(node, dict) or k not in node:
            raise SettingsError(f"{'.'.join(path)} can't be changed from the dashboard")
        node = node[k]
    if node is not True:
        raise SettingsError(f"{'.'.join(path)} is a section, not a setting")


def _mask(path: tuple, value: Any) -> Any:
    if path in SECRETS:
        return "••••" if value else None
    return value


class SettingsStore:
    def __init__(self, cfg: Config, db: DB, base_raw: dict | None = None):
        self.cfg = cfg
        self.db = db
        self.base_raw = base_raw if base_raw is not None else cfg.model_dump(mode="json")
        self.listeners: list[Callable[[set[str]], Any]] = []
        with db.lock:
            db.conn.executescript(SCHEMA)
        if self.overrides:
            try:
                self._apply(self._build(self.overrides))
            except ValidationError as e:
                # A config.yaml change can make old overrides invalid; keep the file config.
                db.insert_alert("settings", f"Saved dashboard settings ignored (invalid): {e}", False)

    # ---- state ------------------------------------------------------------------------
    @property
    def overrides(self) -> dict:
        return self.db.kv_get("settings_overrides", {}) or {}

    @property
    def version(self) -> int:
        return int(self.db.kv_get("settings_version", 0) or 0)

    def _build(self, overrides: dict) -> Config:
        return Config.model_validate(deep_merge(self.base_raw, overrides))

    def _apply(self, new: Config) -> None:
        for name in type(self.cfg).model_fields:
            setattr(self.cfg, name, getattr(new, name))

    def source(self, path: tuple) -> str:
        if _get(self.overrides, path, _MISSING) is not _MISSING:
            return "dashboard"
        if _get(self.base_raw, path, _MISSING) is not _MISSING:
            return "file"
        return "default"

    # ---- edits --------------------------------------------------------------------------
    def update(self, patch: dict) -> set[str]:
        """Apply a nested patch, e.g. {"rules": {"reminder_list": "To-do"}}. Returns changed sections."""
        leaves = _leaves(patch)
        if not leaves:
            return set()
        for path, _ in leaves:
            _check_editable(path)
        new_over = copy.deepcopy(self.overrides)
        changed: list[tuple[tuple, Any, Any]] = []
        current = self.cfg.model_dump(mode="json")
        for path, value in leaves:
            if path in SECRETS and value in ("••••",):
                continue  # untouched masked secret field
            before = _get(current, path)
            if before == value:
                continue
            node = new_over
            for k in path[:-1]:
                node = node.setdefault(k, {})
            node[path[-1]] = value
            changed.append((path, before, value))
        if not changed:
            return set()
        try:
            new_cfg = self._build(new_over)
        except ValidationError as e:
            raise SettingsError(_friendly(e)) from e
        self.db.kv_set("settings_overrides", new_over)
        self.db.kv_set("settings_version", self.version + 1)
        for path, before, after in changed:
            self.db.execute(
                "INSERT INTO settings_history (at, path, before, after, action) VALUES (?,?,?,?,?)",
                (utcnow(), ".".join(path), json.dumps(_mask(path, before)), json.dumps(_mask(path, after)), "set"),
            )
        self._apply(new_cfg)
        sections = {".".join(p[:2]) if p[0] == "watch" else p[0] for p, _, _ in changed}
        self._notify(sections)
        return sections

    def reset(self, dotted: str) -> set[str]:
        """Drop a dashboard override so the config.yaml value applies again."""
        path = tuple(dotted.split("."))
        _check_editable(path)
        new_over = copy.deepcopy(self.overrides)
        node = new_over
        for k in path[:-1]:
            node = node.get(k) if isinstance(node, dict) else None
            if node is None:
                return set()
        if not isinstance(node, dict) or path[-1] not in node:
            return set()
        before = node.pop(path[-1])
        new_over = _prune(new_over)
        try:
            new_cfg = self._build(new_over)
        except ValidationError as e:
            raise SettingsError(_friendly(e)) from e
        self.db.kv_set("settings_overrides", new_over)
        self.db.kv_set("settings_version", self.version + 1)
        self.db.execute(
            "INSERT INTO settings_history (at, path, before, after, action) VALUES (?,?,?,?,?)",
            (utcnow(), dotted, json.dumps(_mask(path, before)), None, "reset"),
        )
        self._apply(new_cfg)
        sections = {".".join(path[:2]) if path[0] == "watch" else path[0]}
        self._notify(sections)
        return sections

    def _notify(self, sections: set[str]) -> None:
        for fn in self.listeners:
            fn(sections)

    # ---- views ----------------------------------------------------------------------------
    def view(self) -> dict[str, Any]:
        """Effective settings for the UI: secrets masked, with where each value came from."""
        cur = self.cfg.model_dump(mode="json")
        values: dict[str, Any] = {}
        sources: dict[str, str] = {}

        def walk(node: dict, path: tuple):
            for k, v in node.items():
                p = path + (k,)
                if v is True:
                    values[".".join(p)] = _mask(p, _get(cur, p))
                    sources[".".join(p)] = self.source(p)
                else:
                    walk(v, p)

        walk(EDITABLE, ())
        return {"values": values, "sources": sources, "version": self.version}

    def history(self, limit: int = 50) -> list[dict[str, Any]]:
        rows = self.db.all("SELECT * FROM settings_history ORDER BY id DESC LIMIT ?", (limit,))
        for r in rows:
            r["before"] = json.loads(r["before"]) if r["before"] else None
            r["after"] = json.loads(r["after"]) if r["after"] else None
        return rows

    def agent_config(self) -> dict[str, Any]:
        allow = [a for a in self.cfg.watch.imessage.allow if a.enabled]
        return {
            "settings_version": self.version,
            "allow": {
                "handles": sorted({normalize_handle(a.handle) for a in allow if a.handle}),
                "chat_ids": sorted({a.chat_id for a in allow if a.chat_id}),
            },
            "allow_self_notes": self.cfg.watch.imessage.allow_self_notes,
        }


_MISSING = object()


def _prune(d: dict) -> dict:
    out = {}
    for k, v in d.items():
        if isinstance(v, dict) and (k, ) != ("labels",):
            v = _prune(v)
            if not v:
                continue
        out[k] = v
    return out


def _friendly(e: ValidationError) -> str:
    msgs = []
    for err in e.errors():
        loc = ".".join(str(x) for x in err["loc"])
        msg = err["msg"].removeprefix("Value error, ")
        msgs.append(f"{loc}: {msg}" if loc else msg)
    return "; ".join(msgs)
