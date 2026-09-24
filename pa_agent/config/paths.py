"""Centralised path constants for PA Agent.

Runtime write directories can be isolated per "profile", so several
instances (typically one per timeframe) can run side by side without
stepping on each other::

    set PA_AGENT_PROFILE=H1     →  profiles/H1/{config,logs,records,trade_records}
    set PA_AGENT_PROFILE=M30    →  profiles/M30/…

With no profile set, everything resolves to PROJECT_ROOT exactly as before.

Read-only assets stay shared across all instances:
  * ``prompt_engineering`` — prompt library
  * ``experience``         — curated experience cases

Import this module everywhere instead of hard-coding paths.
"""
from __future__ import annotations

import json
import os
import re
import shutil
from pathlib import Path

# ── Root ──────────────────────────────────────────────────────────────────────
# Resolve dynamically: this file is pa_agent/config/paths.py, so go up 3 levels.
PROJECT_ROOT: Path = Path(__file__).resolve().parent.parent.parent

# ── Profile (multi-instance isolation) ────────────────────────────────────────
PROFILE_NAME: str = (os.environ.get("PA_AGENT_PROFILE") or "").strip()
PROFILES_DIR: Path = PROJECT_ROOT / "profiles"
#: Root of everything writable for this instance.
STATE_ROOT: Path = PROFILES_DIR / PROFILE_NAME if PROFILE_NAME else PROJECT_ROOT

# ── Prompt engineering assets (read-only at runtime, shared) ─────────────────
PROMPT_DIR: Path = PROJECT_ROOT / "prompt_engineering"
EXPERIENCE_DIR: Path = PROJECT_ROOT / "experience"

# Alias kept for backward compat with design doc
PA_AGENT_DIR: Path = PROJECT_ROOT

# ── Runtime write directories (isolated per profile) ─────────────────────────
RECORDS_PENDING_DIR: Path = STATE_ROOT / "records" / "pending"
TRADE_RECORDS_DIR: Path = STATE_ROOT / "trade_records"
CONFIG_DIR: Path = STATE_ROOT / "config"
LOGS_DIR: Path = STATE_ROOT / "logs"

# ── Individual file paths ─────────────────────────────────────────────────────
FEISHU_JSON_LEGACY_PATH: Path = CONFIG_DIR / "feishu.json"
SETTINGS_JSON_PATH: Path = CONFIG_DIR / "settings.json"
LOG_FILE_PATH: Path = LOGS_DIR / "pa_agent.log"
CRASH_LOG_PATH: Path = LOGS_DIR / "crash.log"


# ── Profile bootstrap ─────────────────────────────────────────────────────────
#: 当 profile 名就是周期名时，顺便把它设成该实例的默认周期
_KNOWN_TIMEFRAMES = (
    "M1", "M5", "M15", "M30", "H1", "H2", "H4", "H6", "H12", "D1", "W1", "MN1",
)

#: 周期展示/下拉框格式（小写单位）：M15 -> 15m, H1 -> 1h, D1 -> 1d, MN1 -> 1M
_TF_UNIT = {"M": "m", "H": "h", "D": "d", "W": "w"}


def _normalize_timeframe(name: str) -> str:
    """Convert an MT5-style timeframe (``"M15"``) to the combo format (``"15m"``).

    The dropdown uses lowercase units (``15m``/``1h``/``4h``/``1d``), so a profile
    name such as ``M15`` must be normalised before being written as
    ``last_timeframe``, otherwise ``QComboBox.setCurrentText`` fails to match and
    the GUI falls back to the first item (``1m``).
    """
    name = (name or "").strip().upper()
    if name == "MN1":
        return "1M"
    m = re.match(r"^([MHWD])(\d+)$", name)
    if not m:
        return name.lower()
    return f"{m.group(2)}{_TF_UNIT.get(m.group(1), m.group(1).lower())}"


def _seed_config() -> None:
    """Copy the main config into a freshly created profile (API key etc.)."""
    source = PROJECT_ROOT / "config"
    if not source.is_dir() or CONFIG_DIR == source:
        return
    for name in ("settings.json", "settings.example.json",
                 "feishu.example.json", "feishu.json"):
        src = source / name
        dst = CONFIG_DIR / name
        if src.is_file() and not dst.exists():
            try:
                shutil.copy2(src, dst)
            except OSError:
                pass

    # 周期名当 profile 名时，帮用户把周期选好（写成下拉框格式，如 15m / 1h）
    raw_name = PROFILE_NAME.upper()
    if raw_name not in _KNOWN_TIMEFRAMES:
        return
    tf = _normalize_timeframe(raw_name)
    settings_path = CONFIG_DIR / "settings.json"
    if not settings_path.is_file():
        return
    try:
        raw = json.loads(settings_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    general = raw.setdefault("general", {})
    if str(general.get("last_timeframe", "")).lower() == tf.lower():
        return
    general["last_timeframe"] = tf
    try:
        settings_path.write_text(
            json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    except OSError:
        pass


def ensure_profile_dirs() -> Path:
    """Create this instance's runtime directories and seed its config.

    Safe to call when no profile is active (it does nothing then).
    Returns the state root in use.
    """
    if not PROFILE_NAME:
        return STATE_ROOT
    for directory in (CONFIG_DIR, LOGS_DIR, TRADE_RECORDS_DIR, RECORDS_PENDING_DIR):
        try:
            directory.mkdir(parents=True, exist_ok=True)
        except OSError:
            pass
    _seed_config()
    return STATE_ROOT
