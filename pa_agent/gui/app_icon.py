"""Runtime-generated application icon + Windows taskbar identity for PA Agent.

When running as a per-timeframe profile (``PA_AGENT_PROFILE=H1`` etc.) we draw a
distinct blue "PA" tile carrying the period badge, and set a per-profile
AppUserModelID, so several instances are easy to tell apart in the taskbar /
Alt-Tab and are NOT merged into a single button group.

Importing this module is safe even without PyQt6 / on non-Windows hosts: the
helpers degrade to no-ops returning a default ``QIcon``.
"""
from __future__ import annotations

# Import Qt lazily-guarded so this module can be imported in headless / test
# contexts where PyQt6 is not installed.
try:
    from PyQt6.QtCore import Qt, QRect
    from PyQt6.QtGui import QColor, QFont, QIcon, QPainter, QPixmap

    _HAS_QT = True
except Exception:  # pragma: no cover - non-Qt environments
    _HAS_QT = False
    QIcon = None  # type: ignore[assignment]


def _normalize_badge(badge: str) -> str:
    return (badge or "").strip().upper()


def build_app_icon(badge: str = "") -> "QIcon":
    """Return a ``QIcon``: a blue "PA" tile with an optional period badge.

    ``badge`` is the timeframe / profile name (e.g. ``"H1"``, ``"M15"``).  When
    empty a plain "PA" tile is returned, so the main (un-profiled) instance still
    gets a branded icon.
    """
    if not _HAS_QT:
        return None

    size = 256
    pix = QPixmap(size, size)
    pix.fill(QColor("#0d1117"))  # GitHub dark background

    painter = QPainter(pix)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)

    # Blue rounded tile
    painter.setBrush(QColor("#1f6feb"))
    painter.setPen(Qt.PenStyle.NoPen)
    margin = 16
    inner = size - 2 * margin
    painter.drawRoundedRect(margin, margin, inner, inner, 36, 36)

    # "PA" letters
    painter.setPen(QColor("#ffffff"))
    painter.setFont(QFont("Segoe UI", 132, QFont.Weight.Bold))
    painter.drawText(pix.rect(), Qt.AlignmentFlag.AlignCenter, "PA")

    # Period badge (bottom-right pill)
    badge = _normalize_badge(badge)
    if badge:
        painter.setFont(QFont("Segoe UI", 64, QFont.Weight.Bold))
        metrics = painter.fontMetrics()
        pad = 18
        pill_w = metrics.horizontalAdvance(badge) + pad * 2
        pill_h = metrics.height() + pad
        pill_x = size - margin - pill_w
        pill_y = size - margin - pill_h
        painter.setBrush(QColor("#ffffff"))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.drawRoundedRect(pill_x, pill_y, pill_w, pill_h, pill_h / 2, pill_h / 2)
        painter.setPen(QColor("#0d1117"))
        painter.drawText(
            QRect(pill_x, pill_y, pill_w, pill_h),
            Qt.AlignmentFlag.AlignCenter,
            badge,
        )

    painter.end()
    return QIcon(pix)


def set_windows_app_model_id(profile: str) -> None:
    """Pin a per-profile AppUserModelID so Windows keeps taskbar buttons separate.

    Without this, every profiled instance shares the same AppID and Windows
    collapses them into one taskbar group.  No-op when ``profile`` is empty or on
    non-Windows platforms.
    """
    if not profile:
        return
    try:
        import ctypes

        appid = f"PAAgent.{profile.strip().upper()}"
        shell = ctypes.windll.shell32  # type: ignore[attr-defined]
        proto = ctypes.WINFUNCTYPE(ctypes.c_int, ctypes.c_wchar_p)
        set_appid = proto(("SetCurrentProcessExplicitAppUserModelID", shell))
        set_appid(appid)
    except Exception:  # pragma: no cover - non-Windows / missing API
        pass
