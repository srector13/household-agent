"""Nightly SQLite backups (online `.backup`), keeping the newest N."""
from __future__ import annotations

import logging
from datetime import datetime
from pathlib import Path

from .config import Config
from .models import DB

log = logging.getLogger("brain.backup")
BACKUP_HOUR = 3  # local time


async def backup_if_due(cfg: Config, db: DB, *, force: bool = False) -> str | None:
    if cfg.storage.db_path == ":memory:":
        return None
    now = datetime.now(cfg.tz)
    today = now.date().isoformat()
    if not force and (now.hour < BACKUP_HOUR or db.kv_get("last_backup", {}).get("date") == today):
        return None
    dest_dir = Path(cfg.storage.backup_dir)
    dest = dest_dir / f"brain-{now:%Y%m%d}.db"
    db.backup(str(dest))
    backups = sorted(dest_dir.glob("brain-*.db"))
    for old in backups[: max(0, len(backups) - cfg.storage.backup_keep)]:
        old.unlink(missing_ok=True)
    db.kv_set("last_backup", {"date": today, "path": str(dest), "at": now.isoformat()})
    log.info("backup written to %s", dest)
    return str(dest)
