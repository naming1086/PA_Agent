"""ChartWidget — pyqtgraph-based K-line chart with EMA20 and overlay lines.

Tasks 14.2 + 14.5:
  - Renders N candles, EMA20 line, and sequence-number labels.
  - Draws entry/TP/SL horizontal lines when order_type != "不下单".
  - 30 Hz QTimer throttles redraws so the 1 Hz data thread never blocks the UI.
"""
from __future__ import annotations

import math
from typing import TYPE_CHECKING

import numpy as np
import pyqtgraph as pg
from PyQt6.QtCore import QEvent, Qt, QTimer
from PyQt6.QtGui import QFont

from pa_agent.gui.widgets.candle_item import CandleItem
from pa_agent.gui.widgets.overlay_lines import OverlayLines
from pa_agent.gui.widgets.seq_label_item import SeqLabelItem
from pa_agent.util.trade_metrics import is_long_direction

if TYPE_CHECKING:
    from pa_agent.data.base import KlineFrame

# ── Constants ─────────────────────────────────────────────────────────────────

_TIMER_INTERVAL_MS = 33  # ~30 Hz
_EMA_COLOR = (255, 200, 0)  # amber
_NO_ORDER_TEXT = "不下单"
_X_MARGIN_BARS = 0.65
_Y_PADDING_RATIO = 0.07
_Y_TOP_EXTRA_RATIO = 0.04
_FIT_VISIBLE_BARS = 20
_AXIS_RESIZE_MIN_WIDTH = 40
_AXIS_RESIZE_EDGE_PX = 8

# ── 十字光标信息条配色 ────────────────────────────────────────────────────────
_C_TEXT = "#e6edf3"      # 主文字
_C_MUTED = "#8b949e"     # 标签/次要
_C_UP = "#3fb950"        # 涨
_C_DOWN = "#f85149"      # 跌
_C_EMA = "#ffc800"       # EMA20（与曲线同色）
_C_FORMING = "#d29922"   # 未收 K 线
_INFO_BG_RGBA = (13, 17, 23, 235)
_INFO_BORDER_RGBA = (48, 54, 63, 255)
_CHIP_BG = "#1f6feb"     # 跟随鼠标的价格标签
_CHIP_BG_TIME = "#30363d"  # 时间轴上的标签
_PRICE_CHIP_OFFSET_PX = 14  # 价格标签相对鼠标的水平偏移

# 读数用等宽字体（Qt 富文本里写 font-family 不生效，必须设到控件上）
def _info_font() -> QFont:
    font = QFont("Consolas")
    font.setPointSize(10)
    return font


class ChartWidget(pg.PlotWidget):
    """Interactive K-line chart widget.

    Parameters
    ----------
    parent:
        Optional Qt parent widget.
    """

    def __init__(self, parent=None) -> None:
        super().__init__(parent=parent)

        # Configure plot appearance
        self.setBackground("#0d1117")
        self.showGrid(x=False, y=True, alpha=0.3)
        self.getPlotItem().setLabel("left", "Price")

        # Internal state
        self._latest_frame: KlineFrame | None = None
        self._dirty: bool = False
        self._candle_items: list[CandleItem] = []
        self._seq_labels: list[SeqLabelItem] = []
        self._ema_line: pg.PlotDataItem | None = None
        self._overlay = OverlayLines()
        self._sr_items: list[pg.GraphicsItem] = []  # support/resistance level lines
        self._pending_decision: dict | None = None
        self._direction_items: list[pg.GraphicsItem] = []
        self._seq_label_font_pt: int = 11
        self._fit_on_next_render: bool = False
        self._first_frame_fitted: bool = False

        # Price-axis resize state
        self._axis_resizing: bool = False
        self._axis_drag_origin_x: float = 0.0
        self._axis_drag_origin_w: float = 0.0

        vb = self.getViewBox()
        vb.enableAutoRange(x=False, y=False)

        # ── 十字光标 + 当前 K 线信息条 ─────────────────────────────────────
        # 需要开启 mouse tracking 才能在不按键的情况下收到 MouseMove
        self.setMouseTracking(True)
        self.viewport().setMouseTracking(True)
        cross_pen = pg.mkPen(color=(130, 140, 155, 150), width=1,
                             style=Qt.PenStyle.DashLine)
        self._cross_v = pg.InfiniteLine(angle=90, movable=False, pen=cross_pen)
        self._cross_h = pg.InfiniteLine(angle=0, movable=False, pen=cross_pen)
        self._cross_v.setZValue(40)
        self._cross_h.setZValue(40)
        self._cross_v.hide()
        self._cross_h.hide()
        self.addItem(self._cross_v)
        self.addItem(self._cross_h)
        bg_brush = pg.mkBrush(color=_INFO_BG_RGBA)
        bg_pen = pg.mkPen(color=_INFO_BORDER_RGBA, width=1)
        info_font = _info_font()
        self._info_item = pg.TextItem(anchor=(0, 0), border=bg_pen, fill=bg_brush)
        self._info_item.setFont(info_font)
        self._info_item.setZValue(50)
        self._info_item.hide()
        self.addItem(self._info_item)

        # 光标价标签（跟随鼠标显示当前价格）与 K 线时间标签（贴在时间轴）
        self._price_chip = pg.TextItem(anchor=(0.0, 0.5), border=bg_pen, fill=bg_brush)
        self._price_chip.setFont(info_font)
        self._price_chip.setZValue(51)
        self._price_chip.hide()
        self.addItem(self._price_chip)
        self._time_chip = pg.TextItem(anchor=(0.5, 0.0), border=bg_pen, fill=bg_brush)
        self._time_chip.setFont(info_font)
        self._time_chip.setZValue(51)
        self._time_chip.hide()
        self.addItem(self._time_chip)

        self._cross_idx = 0
        self._cross_y = 0.0
        self._cross_view_x = 0.0
        vb.sigRangeChanged.connect(self._on_view_range_changed)

        # 30 Hz redraw timer (task 14.5)
        self._timer = QTimer(self)
        self._timer.setInterval(_TIMER_INTERVAL_MS)
        self._timer.timeout.connect(self._on_timer)
        self._timer.start()

    # ── Public API ────────────────────────────────────────────────────────────

    def set_seq_label_font_pt(self, point_size: int) -> None:
        """Set K-line sequence label font size and refresh the chart if needed."""
        point_size = max(6, min(24, int(point_size)))
        if point_size == self._seq_label_font_pt:
            return
        self._seq_label_font_pt = point_size
        if self._latest_frame is not None:
            self._dirty = True

    def set_frame(self, frame: "KlineFrame", *, fit_view: bool = False) -> None:
        """Cache the latest KlineFrame; actual redraw happens on the timer."""
        if self._should_skip_redraw(frame):
            self._latest_frame = frame
            if fit_view or not self._first_frame_fitted:
                self._fit_on_next_render = True
            return
        self._latest_frame = frame
        if fit_view or not self._first_frame_fitted:
            self._fit_on_next_render = True
        self._dirty = True

    def set_frame_now(self, frame: "KlineFrame", *, fit_view: bool = False) -> None:
        """Apply *frame* to the chart immediately (bypass 30 Hz throttle)."""
        if self._should_skip_redraw(frame):
            self._latest_frame = frame
            if fit_view and not self._first_frame_fitted:
                self.fit_view()
            return
        self._latest_frame = frame
        self._dirty = False
        self._render_frame(frame)
        if fit_view:
            self.fit_view()

    def _should_skip_redraw(self, frame: "KlineFrame") -> bool:
        """Skip repaint when the screen already shows the same closed-only snapshot."""
        from pa_agent.data.snapshot import frame_is_pure_closed, frames_equal_for_chart

        current = self._latest_frame
        if current is None or not self._candle_items:
            return False
        if not frame_is_pure_closed(current) or not frame_is_pure_closed(frame):
            return False
        return frames_equal_for_chart(current, frame)

    def request_fit_on_next_render(self) -> None:
        """Zoom/pan to fit the next rendered frame (or now if one is already shown)."""
        self._fit_on_next_render = True
        if self._latest_frame is not None:
            self._dirty = True

    def fit_view(self) -> None:
        """Set view range to show all bars and a comfortable price span."""
        frame = self._latest_frame
        if frame is None or not frame.bars:
            return
        x_range, y_range = self._view_ranges_for_frame(frame)
        self.getViewBox().setRange(
            xRange=x_range,
            yRange=y_range,
            padding=0,
        )
        self._first_frame_fitted = True

    def displayed_frame(self) -> "KlineFrame | None":
        """Return the KlineFrame currently shown on the chart."""
        return self._latest_frame

    def set_decision(self, decision: dict) -> None:
        """Draw or clear entry/TP/SL lines and direction marker from the AI decision."""
        order_type = decision.get("order_type", _NO_ORDER_TEXT)
        overlay_active = bool(decision.get("chart_overlay_active"))

        if order_type == _NO_ORDER_TEXT and not overlay_active:
            self._pending_decision = None
            self._overlay.clear_lines(self)
            self._clear_direction_marker()
            return

        self._pending_decision = decision
        entry = decision.get("entry_price")
        tp = decision.get("take_profit_price")
        tp2 = decision.get("take_profit_price_2")
        sl = decision.get("stop_loss_price")

        if entry is not None and tp is not None and sl is not None:
            try:
                tp2_val = float(tp2) if tp2 is not None else None
                self._overlay.set_lines(
                    self,
                    float(entry),
                    float(tp),
                    float(sl),
                    tp2=tp2_val,
                    continuity=overlay_active,
                )
            except (TypeError, ValueError):
                self._overlay.clear_lines(self)
        else:
            self._overlay.clear_lines(self)

        self._update_direction_marker()

    def clear_decision_overlay(self) -> None:
        """Remove entry/TP/SL lines and direction marker; keep the current K-line frame."""
        self._overlay.clear_lines(self)
        self._clear_direction_marker()
        self._pending_decision = None

    def set_support_resistance(self, levels: list) -> None:
        """Draw horizontal support/resistance lines from StructureLevel objects.

        Parameters
        ----------
        levels:
            List of ``StructureLevel`` objects (from ``pa_agent.gui.support_resistance``).
            Supports are drawn in green, resistances in red/amber.
        """
        plot = self.getPlotItem()
        for item in self._sr_items:
            plot.removeItem(item)
        self._sr_items.clear()

        for level in levels:
            kind = getattr(level, "kind", "support")
            price = getattr(level, "price", None)
            low = getattr(level, "low", price)
            high = getattr(level, "high", price)
            label_text = getattr(level, "label", kind)
            if price is None:
                continue

            if kind == "support":
                color = (34, 197, 94, 180)    # green
                text_color = (134, 239, 172)   # light green
            else:
                color = (245, 158, 11, 180)    # amber
                text_color = (251, 191, 36)    # yellow

            # Draw the midline
            line = pg.InfiniteLine(
                pos=price,
                angle=0,
                pen=pg.mkPen(color=color, width=1,
                             style=pg.QtCore.Qt.PenStyle.DashLine),
                movable=False,
            )
            plot.addItem(line)
            self._sr_items.append(line)

            # Draw a zone fill if it's a range (high != low)
            is_zone = abs((high or price) - (low or price)) > 1e-9
            if is_zone and low is not None and high is not None:
                zone_color = (*color[:3], 28)  # very transparent fill
                fill = pg.LinearRegionItem(
                    values=(low, high),
                    orientation="horizontal",
                    movable=False,
                    brush=pg.mkBrush(color=zone_color),
                    pen=pg.mkPen(None),
                )
                plot.addItem(fill)
                self._sr_items.append(fill)

            # Label
            label = pg.TextItem(
                text=f"{label_text}: {price:.5g}",
                color=text_color,
                anchor=(0.0, 0.5),
            )
            plot.addItem(label)
            self._sr_items.append(label)
            label._sr_price = float(price)  # type: ignore[attr-defined]

        # Position labels at left edge (use exact price, not rounded display text)
        if self._sr_items:
            try:
                x_min = self.getViewBox().viewRange()[0][0]
                for item in self._sr_items:
                    if isinstance(item, pg.TextItem):
                        p = getattr(item, "_sr_price", None)
                        if p is not None:
                            item.setPos(x_min, float(p))
            except Exception:  # noqa: BLE001
                pass

    def clear_support_resistance(self) -> None:
        """Remove all support/resistance lines from the chart."""
        plot = self.getPlotItem()
        for item in self._sr_items:
            plot.removeItem(item)
        self._sr_items.clear()

    # ── Price-axis resize via viewportEvent ──────────────────────────────────

    def _axis_right_edge_wx(self) -> float:
        """Right edge x of the left price axis in viewport coordinates."""
        axis = self.getPlotItem().getAxis("left")
        geom = axis.geometry()  # layout-managed rect (not sceneBoundingRect!)
        return float(self.mapFromScene(geom.bottomRight()).x())

    def _axis_vertical_range_wy(self) -> tuple[float, float]:
        """Top/bottom y of the left price axis in viewport coordinates."""
        axis = self.getPlotItem().getAxis("left")
        geom = axis.geometry()
        return (
            float(self.mapFromScene(geom.topLeft()).y()),
            float(self.mapFromScene(geom.bottomRight()).y()),
        )

    def _in_axis_resize_zone(self, vx: float, vy: float) -> bool:
        """True when (vx, vy) is within ``_AXIS_RESIZE_EDGE_PX`` of the axis right edge."""
        edge = self._axis_right_edge_wx()
        top, bot = self._axis_vertical_range_wy()
        return abs(vx - edge) < _AXIS_RESIZE_EDGE_PX and top <= vy <= bot

    def viewportEvent(self, ev):  # noqa: N802
        """Intercept viewport mouse events to handle price-axis width resizing.

        This is the canonical entry-point for viewport events in
        ``QAbstractScrollArea`` (parent of ``QGraphicsView``).  We check
        whether the event is inside the price-axis resize zone; if so, we
        handle the drag ourselves and return ``True`` to prevent the event
        from reaching ``QGraphicsView::viewportEvent`` (and thus the scene).
        Otherwise we delegate to the superclass so normal pan/zoom/drag
        on the ViewBox works as usual.
        """
        et = ev.type()

        if et == QEvent.Type.MouseMove:
            pos = ev.position()
            if self._axis_resizing:
                dx = pos.x() - self._axis_drag_origin_x
                new_w = max(
                    _AXIS_RESIZE_MIN_WIDTH,
                    int(self._axis_drag_origin_w + dx),
                )
                self.getPlotItem().getAxis("left").setWidth(new_w)
                ev.accept()
                return True  # consume event — don't forward to scene
            # Cursor hint (on the viewport, not the QGraphicsView)
            vp = self.viewport()
            if self._in_axis_resize_zone(pos.x(), pos.y()):
                vp.setCursor(Qt.CursorShape.SplitHCursor)
                self._hide_crosshair()
            else:
                vp.unsetCursor()
                self._update_crosshair(ev)

        elif et == QEvent.Type.Leave:
            self._hide_crosshair()

        elif et == QEvent.Type.MouseButtonPress and ev.button() == Qt.MouseButton.LeftButton:
            pos = ev.position()
            if self._in_axis_resize_zone(pos.x(), pos.y()):
                self._axis_resizing = True
                self._axis_drag_origin_x = pos.x()
                self._axis_drag_origin_w = self.getPlotItem().getAxis("left").width()
                ev.accept()
                return True

        elif et == QEvent.Type.MouseButtonRelease and self._axis_resizing:
            self._axis_resizing = False
            ev.accept()
            return True

        return super().viewportEvent(ev)

    def reset(self) -> None:
        """Clear all chart items (candles, labels, EMA, overlay lines)."""
        self.clear_decision_overlay()
        self._clear_candles_and_labels()
        if self._ema_line is not None:
            self.removeItem(self._ema_line)
            self._ema_line = None
        self._latest_frame = None
        self._dirty = False
        self._fit_on_next_render = False
        self._first_frame_fitted = False

    # ── Timer slot ────────────────────────────────────────────────────────────

    def _on_timer(self) -> None:
        """Called every ~33 ms; redraws only when a new frame is available."""
        if not self._dirty or self._latest_frame is None:
            return
        self._dirty = False
        self._render_frame(self._latest_frame)

    # ── Internal rendering ────────────────────────────────────────────────────

    def _render_frame(self, frame: "KlineFrame") -> None:
        """Rebuild all candle items, EMA line, and sequence labels."""
        self._clear_candles_and_labels()
        if self._ema_line is not None:
            self.removeItem(self._ema_line)
            self._ema_line = None
        bars = frame.bars
        n = len(bars)
        if n == 0:
            return

        # bars[0] is newest (seq=1); we want x=0 for oldest, x=n-1 for newest
        # so x_pos for bars[i] = (n - 1 - i)
        ema_x: list[float] = []
        ema_y: list[float] = []

        for i, bar in enumerate(bars):
            x_pos = n - 1 - i  # oldest bar at x=0, newest at x=n-1

            forming = not bar.closed

            # Candle (forming bar: semi-transparent dashed outline)
            candle = CandleItem(bar, x_pos, forming=forming)
            self.addItem(candle)
            self._candle_items.append(candle)

            # Sequence label — odd seq only; skip forming bar (seq=0)
            if bar.seq > 0 and bar.seq % 2 == 1:
                label_y = bar.high
                seq_label = SeqLabelItem(
                    bar.seq,
                    x_pos,
                    label_y,
                    font_pt=self._seq_label_font_pt,
                    forming=forming,
                )
                self.addItem(seq_label)
                self._seq_labels.append(seq_label)

            # EMA20 point (skip NaN)
            ema_val = frame.indicators.ema20[i]
            if not math.isnan(ema_val):
                ema_x.append(float(x_pos))
                ema_y.append(ema_val)

        # EMA20 line (slightly dimmed through forming bar)
        if ema_x:
            newest_forming = len(bars) > 0 and not bars[0].closed
            ema_color: tuple[int, ...] = _EMA_COLOR
            if newest_forming:
                ema_color = (255, 200, 0, 140)
            self._ema_line = pg.PlotDataItem(
                x=np.array(ema_x),
                y=np.array(ema_y),
                pen=pg.mkPen(color=ema_color, width=1),
            )
            self.addItem(self._ema_line)

        self._update_direction_marker()

        if self._fit_on_next_render:
            self._fit_on_next_render = False
            self.fit_view()

    def _view_ranges_for_frame(
        self,
        frame: "KlineFrame",
    ) -> tuple[tuple[float, float], tuple[float, float]]:
        """Compute (x_range, y_range) for the newest ``_FIT_VISIBLE_BARS`` bars."""
        bars = frame.bars
        n = len(bars)
        visible_count = min(_FIT_VISIBLE_BARS, n)
        visible_bars = bars[:visible_count]
        visible_ema = frame.indicators.ema20[:visible_count]

        y_min = min(b.low for b in visible_bars)
        y_max = max(b.high for b in visible_bars)

        for ema_val in visible_ema:
            if not math.isnan(ema_val):
                y_min = min(y_min, ema_val)
                y_max = max(y_max, ema_val)

        decision = self._pending_decision
        if decision is not None:
            for key in (
                "entry_price",
                "take_profit_price",
                "take_profit_price_2",
                "stop_loss_price",
            ):
                raw = decision.get(key)
                if raw is None:
                    continue
                try:
                    price = float(raw)
                except (TypeError, ValueError):
                    continue
                y_min = min(y_min, price)
                y_max = max(y_max, price)

        span = y_max - y_min
        if span <= 0:
            mid = y_max if y_max != 0 else 1.0
            span = abs(mid) * 0.01 or 1.0
        y_pad = span * _Y_PADDING_RATIO
        y_top = span * _Y_TOP_EXTRA_RATIO

        # x=0 is oldest; newest bar is at x=n-1 — show only the rightmost window.
        x_left = float(max(0, n - _FIT_VISIBLE_BARS))
        x_min = x_left - _X_MARGIN_BARS
        x_max = float(n - 1) + _X_MARGIN_BARS
        return (
            (x_min, x_max),
            (y_min - y_pad, y_max + y_pad + y_top),
        )

    def _clear_direction_marker(self) -> None:
        for item in self._direction_items:
            self.removeItem(item)
        self._direction_items.clear()

    def _update_direction_marker(self) -> None:
        """Draw ▲/▼ at newest bar × entry price for long/short."""
        self._clear_direction_marker()
        decision = self._pending_decision
        frame = self._latest_frame
        if decision is None or frame is None:
            return
        if (
            decision.get("order_type", _NO_ORDER_TEXT) == _NO_ORDER_TEXT
            and not decision.get("chart_overlay_active")
        ):
            return

        entry = decision.get("entry_price")
        if entry is None:
            return
        try:
            entry_f = float(entry)
        except (TypeError, ValueError):
            return

        n = len(frame.bars)
        if n == 0:
            return

        long = is_long_direction(decision.get("order_direction"))
        if long is True:
            symbol, color = "▲", (63, 185, 80)
            anchor = (0.5, 1.0)
        elif long is False:
            symbol, color = "▼", (248, 81, 73)
            anchor = (0.5, 0.0)
        else:
            return

        x_pos = float(n - 1)
        marker = pg.TextItem(
            text=symbol,
            color=color,
            anchor=anchor,
        )
        from PyQt6.QtGui import QFont

        font = QFont()
        font.setPointSize(14)
        font.setBold(True)
        marker.setFont(font)
        marker.setPos(x_pos, entry_f)
        self.addItem(marker)
        self._direction_items.append(marker)

    # ── 十字光标 + 当前 K 线信息 ──────────────────────────────────────────────

    def _hide_crosshair(self) -> None:
        """Hide the crosshair lines and every readout."""
        self._cross_v.hide()
        self._cross_h.hide()
        self._info_item.hide()
        self._price_chip.hide()
        self._time_chip.hide()

    def _on_view_range_changed(self) -> None:
        """Keep the readouts pinned to their corners while pan/zoom."""
        if self._info_item.isVisible():
            self._position_overlays()

    def _data_units_per_pixel_x(self) -> float:
        """一个屏幕像素等于多少个 x 轴（K 线序号）单位，用于把像素偏移换成数据坐标."""
        vb = self.getViewBox()
        (x_min, x_max), _ = vb.viewRange()
        rect = vb.sceneBoundingRect()
        left = self.mapFromScene(rect.topLeft())
        right = self.mapFromScene(rect.topRight())
        width_px = float(right.x() - left.x())
        if width_px <= 0.0:
            return 0.0
        return float(x_max - x_min) / width_px

    def _position_overlays(self) -> None:
        """Anchor every readout: info top-left, price chip next to the mouse, time chip below."""
        (x_min, _), (y_min, y_max) = self.getViewBox().viewRange()
        self._info_item.setPos(float(x_min), float(y_max))
        self._price_chip.setPos(
            self._cross_view_x + _PRICE_CHIP_OFFSET_PX * self._data_units_per_pixel_x(),
            self._cross_y,
        )
        self._time_chip.setPos(float(self._cross_idx), float(y_min))

    def _update_crosshair(self, ev) -> None:
        """Move the crosshair to the mouse position and show the hovered bar."""
        frame = self._latest_frame
        if frame is None or not frame.bars:
            self._hide_crosshair()
            return
        scene_pos = self.mapToScene(ev.position().toPoint())
        vb = self.getViewBox()
        if not vb.sceneBoundingRect().contains(scene_pos):
            self._hide_crosshair()
            return
        view_pos = vb.mapSceneToView(scene_pos)

        n = len(frame.bars)
        # x=0 oldest … x=n-1 newest; bars[0] is the newest bar
        idx = max(0, min(n - 1, int(round(view_pos.x()))))
        bar_index = n - 1 - idx
        bar = frame.bars[bar_index]

        self._cross_idx = idx
        self._cross_y = float(view_pos.y())
        self._cross_view_x = float(view_pos.x())
        self._cross_v.setPos(float(idx))
        self._cross_h.setPos(self._cross_y)
        self._cross_v.show()
        self._cross_h.show()

        time_text = self._bar_time_text(bar)
        self._info_item.setHtml(
            self._bar_info_html(frame, bar, bar_index, self._cross_y, time_text)
        )
        self._price_chip.setHtml(
            f'<div><span style="background-color:{_CHIP_BG};color:#ffffff">'
            f'&nbsp;{self._fmt_price(self._cross_y)}&nbsp;</span></div>'
        )
        self._time_chip.setHtml(
            f'<div><span style="background-color:{_CHIP_BG_TIME};color:{_C_TEXT}">'
            f'&nbsp;{time_text}&nbsp;</span></div>'
        )
        self._position_overlays()
        self._info_item.show()
        self._price_chip.show()
        self._time_chip.show()

    # ── 读数格式化 ────────────────────────────────────────────────────────────

    @staticmethod
    def _fmt_price(value: float) -> str:
        """按价格量级选择小数位（黄金 2 位、外汇 4~5 位）."""
        magnitude = abs(value)
        if magnitude >= 1000:
            digits = 2
        elif magnitude >= 10:
            digits = 3
        elif magnitude >= 1:
            digits = 4
        else:
            digits = 5
        return f"{value:,.{digits}f}"

    @staticmethod
    def _fmt_volume(value: float) -> str:
        """成交量紧凑显示：1.2K / 3.4M / 5.6B."""
        magnitude = abs(value)
        if magnitude >= 1e9:
            return f"{value / 1e9:.2f}B"
        if magnitude >= 1e6:
            return f"{value / 1e6:.2f}M"
        if magnitude >= 1e3:
            return f"{value / 1e3:.2f}K"
        return f"{value:.0f}"

    @staticmethod
    def _bar_time_text(bar) -> str:
        """K 线开盘时间的本地时间字符串."""
        from datetime import datetime

        from pa_agent.data.datetime_ts import ts_open_to_ms

        ts_ms = ts_open_to_ms(bar.ts_open)
        return datetime.fromtimestamp(ts_ms / 1000.0).strftime("%m-%d %H:%M")

    def _bar_info_html(
        self,
        frame: "KlineFrame",
        bar,
        bar_index: int,
        cross_y: float,
        time_text: str,
    ) -> str:
        """Compose the HTML readout for the hovered bar."""
        if bar.pct_chg is not None:
            chg = float(bar.pct_chg)
        elif bar.open:
            chg = (bar.close - bar.open) / bar.open * 100.0
        else:
            chg = 0.0

        try:
            ema = float(frame.indicators.ema20[bar_index])
        except (IndexError, TypeError, ValueError):
            ema = float("nan")
        ema_text = self._fmt_price(ema) if not math.isnan(ema) else "—"

        chg_color = _C_UP if chg >= 0 else _C_DOWN
        close_color = _C_UP if bar.close >= bar.open else _C_DOWN
        seq_text = f"#{bar.seq}" if bar.seq > 0 else "形成中"
        if not bar.closed:
            state_text = f'<span style="color:{_C_FORMING}">未收</span>'
        else:
            state_text = f'<span style="color:{_C_MUTED}">已收</span>'

        muted = _C_MUTED
        return (
            f'<div style="color:{_C_TEXT};white-space:pre">'
            # 标题行：时间 · 序号 · 收盘状态
            f'<div style="color:{muted}">{time_text}&nbsp;&nbsp;'
            f'<b style="color:{_C_TEXT}">{seq_text}</b>&nbsp;{state_text}</div>'
            # 开 / 高
            f'<div><span style="color:{muted}">开</span> {self._fmt_price(bar.open)}'
            f'&nbsp;&nbsp;&nbsp;<span style="color:{muted}">高</span> '
            f'{self._fmt_price(bar.high)}</div>'
            # 低 / 收（收盘价按涨跌着色）
            f'<div><span style="color:{muted}">低</span> {self._fmt_price(bar.low)}'
            f'&nbsp;&nbsp;&nbsp;<span style="color:{muted}">收</span> '
            f'<span style="color:{close_color}">{self._fmt_price(bar.close)}</span></div>'
            # 涨跌 / 量
            f'<div><span style="color:{muted}">涨跌</span> '
            f'<b style="color:{chg_color}">{chg:+.2f}%</b>'
            f'&nbsp;&nbsp;&nbsp;<span style="color:{muted}">量</span> '
            f'{self._fmt_volume(bar.volume)}</div>'
            # EMA20 / 光标价
            f'<div><span style="color:{_C_EMA}">EMA20 {ema_text}</span>'
            f'&nbsp;&nbsp;&nbsp;<span style="color:{muted}">光标</span> '
            f'{self._fmt_price(cross_y)}</div>'
            '</div>'
        )

    def _clear_candles_and_labels(self) -> None:
        """Remove all candle and label items from the plot."""
        for item in self._candle_items:
            self.removeItem(item)
        self._candle_items.clear()

        for item in self._seq_labels:
            self.removeItem(item)
        self._seq_labels.clear()
