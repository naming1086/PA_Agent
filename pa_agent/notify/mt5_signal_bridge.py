"""MT5 信号桥（Python 侧）：把下单决策写成 JSON 文件，供 MT5 的 EA 读取.

链路
----
PA_Agent 出决策 -> 本模块写 JSON 文件 -> MQ5 EA (pa_signal_bridge.mq5) 轮询目录
-> 面板显示 / 自动下单。

目录
----
MQ5 的 FILE_COMMON 目录，Windows 上默认是::

    %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\PA_Agent\\signals

本模块会自动定位；也可在 settings.json 的 ``mt5_bridge.folder`` 里手动指定。
注意 MT5 若以 portable 方式安装，公共目录在终端目录下，需要手动指定。

写入方式
--------
先写 ``*.json.tmp`` 再 ``os.replace()`` 原子改名，避免 EA 读到写了一半的文件。

文件契约（与 pa_signal_bridge.mq5 保持一致）
--------------------------------------------
``id`` / ``symbol`` / ``timeframe`` / ``order_type`` / ``order_direction`` /
``entry_price`` / ``stop_loss_price`` / ``take_profit_price`` /
``take_profit_price_2`` / ``volume`` / ``trade_confidence`` /
``estimated_win_rate`` / ``created_at`` / ``reasoning``
"""
from __future__ import annotations

import json
import logging
import os
import re
import time
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from pa_agent.config.settings import Settings

logger = logging.getLogger(__name__)

#: 目录里最多保留的信号文件数，超出后删最旧的（0 = 不清理）
MAX_SIGNAL_FILES = 500

_SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._-]+")


# ── 目录定位 ──────────────────────────────────────────────────────────────────
def default_signal_folder() -> Path:
    """MT5 公共 Files 目录下的 PA_Agent/signals（自动探测，找不到则用项目内目录）."""
    appdata = os.environ.get("APPDATA") or ""
    if appdata:
        base = Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files"
        if base.exists():
            return base / "PA_Agent" / "signals"
    # macOS / 兜底：写到项目目录，MQ5 侧把 InpSignalFolder 指过来即可
    return Path(__file__).resolve().parents[2] / "mt5_signals"


def _resolve_folder(settings: "Settings | None") -> Path:
    """返回实际使用的信号目录（settings 未配置时自动探测）."""
    if settings is not None:
        cfg = getattr(settings, "mt5_bridge", None)
        custom = (getattr(cfg, "folder", "") or "").strip() if cfg else ""
        if custom:
            return Path(custom)
    return default_signal_folder()


# ── 数值清洗 ──────────────────────────────────────────────────────────────────
def _num(value: Any) -> float | None:
    """把决策里的价格/手数转成 float，失败返回 None."""
    if value is None or value == "":
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    # NaN / inf 不能进 JSON
    if result != result or result in (float("inf"), float("-inf")):
        return None
    return result


def _safe_name(value: str) -> str:
    """把品种名清洗成可用于文件名的字符串."""
    return _SAFE_NAME_RE.sub("_", (value or "").strip()) or "SYMBOL"


# ── 载荷构建 ──────────────────────────────────────────────────────────────────
def build_signal_payload(
    *,
    decision_inner: dict,
    stage2_full: dict | None = None,
    symbol: str = "",
    timeframe: str = "",
    default_volume: float = 0.0,
    include_reasoning: bool = True,
    ttl_seconds: int = 1800,
) -> dict | None:
    """把 stage2 决策翻译成 MQ5 能读懂的信号字典；无法构成有效信号时返回 None."""
    dec = decision_inner if isinstance(decision_inner, dict) else {}
    if not dec:
        return None

    order_type = str(dec.get("order_type") or "").strip()
    direction = str(dec.get("order_direction") or "").strip()
    entry = _num(dec.get("entry_price"))

    # 没有入场价就没什么可下的（「不下单」通常也没有三价）
    if entry is None:
        logger.debug("MT5 信号桥：缺少 entry_price，跳过写文件")
        return None

    payload: dict[str, Any] = {
        "symbol": str(symbol or "").strip(),
        "timeframe": str(timeframe or "").strip(),
        "order_type": order_type,
        "order_direction": direction,
        "entry_price": entry,
        "created_at": int(time.time()),
    }
    if not payload["symbol"]:
        logger.debug("MT5 信号桥：缺少 symbol，跳过写文件")
        return None

    # 可选字段
    sl = _num(dec.get("stop_loss_price"))
    tp1 = _num(dec.get("take_profit_price"))
    tp2 = _num(dec.get("take_profit_price_2"))
    if sl is not None:
        payload["stop_loss_price"] = sl
    if tp1 is not None:
        payload["take_profit_price"] = tp1
    if tp2 is not None:
        payload["take_profit_price_2"] = tp2

    volume = _num(dec.get("volume"))
    if volume is None:
        volume = default_volume if default_volume > 0 else None
    if volume is not None:
        payload["volume"] = round(volume, 4)

    confidence = _num(dec.get("trade_confidence"))
    if confidence is not None:
        payload["trade_confidence"] = confidence
    win_rate = _num(dec.get("estimated_win_rate"))
    if win_rate is not None:
        payload["estimated_win_rate"] = win_rate

    if ttl_seconds > 0:
        payload["ttl_seconds"] = int(ttl_seconds)

    # id：时间戳 + 品种，EA 侧用于去重与展示
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    payload["id"] = f"{stamp}_{_safe_name(payload['symbol'])}"

    if include_reasoning:
        reasoning = str(dec.get("reasoning") or "").strip()
        if reasoning:
            payload["reasoning"] = reasoning[:2000]
        ncp = (stage2_full or {}).get("next_cycle_prediction")
        if isinstance(ncp, dict):
            ncp_reason = str(ncp.get("reasoning") or "").strip()
            if ncp_reason:
                payload["next_cycle_prediction"] = ncp_reason[:800]

    return payload


# ── 写文件 ────────────────────────────────────────────────────────────────────
def _cleanup(folder: Path, keep: int = MAX_SIGNAL_FILES) -> None:
    """保留最近的 keep 个信号文件."""
    if keep <= 0:
        return
    try:
        files = sorted(folder.glob("signal_*.json"), key=lambda p: p.stat().st_mtime)
    except OSError:
        return
    for old in files[:-keep] if len(files) > keep else []:
        try:
            old.unlink()
        except OSError:
            pass


def write_signal(
    *,
    decision_inner: dict,
    stage2_full: dict | None = None,
    symbol: str = "",
    timeframe: str = "",
    settings: "Settings | None" = None,
) -> Path | None:
    """把决策写成信号文件，返回文件路径；被禁用/无效则返回 None.

    Parameters
    ----------
    decision_inner:
        stage2_decision["decision"] 内层字典。
    stage2_full:
        完整 stage2 字典（取 next_cycle_prediction）。
    symbol / timeframe:
        品种与周期标签。
    settings:
        内存中的 Settings；未传时从 config/settings.json 读取。
    """
    cfg = None
    if settings is not None:
        cfg = getattr(settings, "mt5_bridge", None)
    else:
        try:
            from pa_agent.config.paths import SETTINGS_JSON_PATH
            from pa_agent.config.settings import load_settings

            cfg = load_settings(SETTINGS_JSON_PATH).mt5_bridge
        except Exception as exc:  # noqa: BLE001
            logger.debug("MT5 信号桥：读取配置失败，使用默认配置 (%s)", exc)

    enabled = True if cfg is None else bool(getattr(cfg, "enabled", True))
    if cfg is not None and not enabled:
        logger.debug("MT5 信号桥已禁用（settings.json mt5_bridge.enabled=false）")
        return None

    if cfg is not None and bool(getattr(cfg, "order_only", True)):
        order_type = str((decision_inner or {}).get("order_type") or "").strip()
        if not order_type or order_type == "不下单":
            logger.debug("MT5 信号桥：order_only=true 且非下单信号，跳过")
            return None

    payload = build_signal_payload(
        decision_inner=decision_inner,
        stage2_full=stage2_full,
        symbol=symbol,
        timeframe=timeframe,
        default_volume=float(getattr(cfg, "default_volume", 0.0) or 0.0) if cfg else 0.0,
        include_reasoning=bool(getattr(cfg, "include_reasoning", True)) if cfg else True,
        ttl_seconds=int(getattr(cfg, "ttl_seconds", 1800) or 0) if cfg else 1800,
    )
    if payload is None:
        return None

    folder = _resolve_folder(settings)
    try:
        folder.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        logger.warning("MT5 信号桥：无法创建目录 %s (%s)", folder, exc)
        return None

    # 文件名带时间戳，字典序 = 时间序，EA 按此顺序消费
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    name = f"signal_{stamp}_{_safe_name(str(payload['symbol']))}.json"
    target = folder / name
    if target.exists():  # 同一秒内再来一条，加序号
        for i in range(1, 100):
            alt = folder / f"signal_{stamp}_{_safe_name(str(payload['symbol']))}_{i}.json"
            if not alt.exists():
                target = alt
                break

    tmp = target.with_suffix(".json.tmp")
    try:
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, target)  # 原子改名，EA 不会读到半个文件
    except OSError as exc:
        logger.warning("MT5 信号桥：写入失败 %s (%s)", target, exc)
        try:
            tmp.unlink()
        except OSError:
            pass
        return None

    logger.info("MT5 信号桥已写出信号: %s", target)
    _cleanup(folder)
    return target
