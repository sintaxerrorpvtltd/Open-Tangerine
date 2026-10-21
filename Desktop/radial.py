"""Radial wheel overlay and status toast for quick file conversion (GPL-3.0-only)."""
import math
from pathlib import Path
from PySide6.QtCore import Qt, QPointF, QRectF, Signal, QTimer, QPropertyAnimation, QEasingCurve, QUrl
from PySide6.QtGui import (QPainter, QPainterPath, QColor, QFont, QPen, QBrush,
                           QLinearGradient, QCursor, QFontMetrics, QDesktopServices)
from PySide6.QtWidgets import QWidget, QApplication, QLabel, QPushButton, QHBoxLayout, QVBoxLayout


class RadialGeometry:
    def __init__(self, count, inner_radius=68, outer_radius=155, gap=5, corner=8):
        self.count = max(count, 1)
        self.inner_radius = inner_radius
        self.outer_radius = outer_radius
        self.gap = gap
        self.corner = corner
        self.slice = 2 * math.pi / self.count
        self.label_radius = inner_radius + (outer_radius - inner_radius) * 0.54

    def angles(self, index):
        mid = self.slice * index
        return (mid - self.slice / 2, mid + self.slice / 2)

    def midpoint(self, index, center, expand=0):
        mid = self.slice * index
        r = self.label_radius + expand * 0.5
        return QPointF(center.x() + math.sin(mid) * r,
                       center.y() - math.cos(mid) * r)

    def index_at(self, offset):
        dist = math.hypot(offset.x(), offset.y())
        if dist < self.inner_radius - 12 or dist > self.outer_radius + 30:
            return None
        theta = math.atan2(offset.x(), -offset.y())
        if theta < 0:
            theta += 2 * math.pi
        idx = int((theta + self.slice / 2) / self.slice) % self.count
        return idx

    def wedge_path(self, index, center, expand=0):
        a0, a1 = self.angles(index)
        r0 = self.inner_radius
        r1 = self.outer_radius + expand
        mid_r = (r0 + r1) / 2
        gap_rad = self.gap / mid_r
        start_a = a0 + gap_rad / 2
        end_a = a1 - gap_rad / 2
        if end_a <= start_a:
            end_a = start_a + 0.001

        mid_angle = (start_a + end_a) / 2
        cx = center.x() + math.sin(mid_angle) * (expand * 0.7)
        cy = center.y() - math.cos(mid_angle) * (expand * 0.7)

        k = min(self.corner, (r1 - r0) / 3, (end_a - start_a) * r0 / 3)
        d_out = k / r1
        d_in = k / r0

        def pt(r, a):
            return QPointF(cx + math.sin(a) * r, cy - math.cos(a) * r)

        path = QPainterPath()
        steps = max(10, int(abs(math.degrees(end_a - start_a))))

        p_out_start = pt(r1, start_a + d_out)
        path.moveTo(p_out_start)

        for s in range(1, steps + 1):
            t = (start_a + d_out) + ((end_a - d_out) - (start_a + d_out)) * (s / steps)
            path.lineTo(pt(r1, t))

        p_corner_out_end = pt(r1, end_a)
        p_edge_out_end = pt(r1 - k, end_a)
        path.quadTo(p_corner_out_end, p_edge_out_end)

        p_edge_in_end = pt(r0 + k, end_a)
        path.lineTo(p_edge_in_end)

        p_corner_in_end = pt(r0, end_a)
        p_in_end = pt(r0, end_a - d_in)
        path.quadTo(p_corner_in_end, p_in_end)

        for s in range(1, steps + 1):
            t = (end_a - d_in) - ((end_a - d_in) - (start_a + d_in)) * (s / steps)
            path.lineTo(pt(r0, t))

        p_corner_in_start = pt(r0, start_a)
        p_edge_in_start = pt(r0 + k, start_a)
        path.quadTo(p_corner_in_start, p_edge_in_start)

        p_edge_out_start = pt(r1 - k, start_a)
        path.lineTo(p_edge_out_start)

        p_corner_out_start = pt(r1, start_a)
        path.quadTo(p_corner_out_start, p_out_start)

        path.closeSubpath()
        return path


def draw_action_glyph(painter, center, action, is_hl):
    """Render a clean glyph icon for the action."""
    color = QColor(255, 255, 255) if is_hl else QColor(200, 200, 210)
    painter.setPen(QPen(color, 1.4, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
    painter.setBrush(Qt.NoBrush)

    cx, cy = center.x(), center.y() - 9
    s = 7 # size half-extent

    if any(fmt in action for fmt in ('PNG', 'JPEG', 'WEBP', 'TIFF', 'BMP')):
        # Photo / mountain icon
        painter.drawRoundedRect(QRectF(cx - s, cy - s + 1, s * 2, s * 2 - 2), 2, 2)
        m = QPainterPath()
        m.moveTo(cx - s + 2, cy + s - 2)
        m.lineTo(cx - 1, cy - 1)
        m.lineTo(cx + 2, cy + 2)
        m.lineTo(cx + s - 2, cy - 2)
        painter.drawPath(m)
        painter.drawPoint(QPointF(cx - 2, cy - 3))
    elif 'PDF' in action:
        # Document icon with folded corner
        doc = QPainterPath()
        doc.moveTo(cx - s + 2, cy - s)
        doc.lineTo(cx + 2, cy - s)
        doc.lineTo(cx + s - 1, cy - s + 4)
        doc.lineTo(cx + s - 1, cy + s)
        doc.lineTo(cx - s + 2, cy + s)
        doc.closeSubpath()
        painter.drawPath(doc)
        painter.drawLine(QPointF(cx - s + 4, cy - 1), QPointF(cx + s - 3, cy - 1))
        painter.drawLine(QPointF(cx - s + 4, cy + 3), QPointF(cx + s - 3, cy + 3))
    elif any(fmt in action for fmt in ('MP4', 'WEBM')):
        # Film / video icon
        painter.drawRoundedRect(QRectF(cx - s, cy - s + 1, s * 2, s * 2 - 2), 2, 2)
        tri = QPainterPath()
        tri.moveTo(cx - 2, cy - 3)
        tri.lineTo(cx + 3, cy)
        tri.lineTo(cx - 2, cy + 3)
        tri.closeSubpath()
        painter.fillPath(tri, color)
    elif any(fmt in action for fmt in ('MP3', 'WAV', 'FLAC', 'OGG')):
        # Musical note icon
        note = QPainterPath()
        note.addEllipse(QPointF(cx - 3, cy + 3), 2.5, 2)
        note.moveTo(cx - 0.5, cy + 3)
        note.lineTo(cx - 0.5, cy - s + 1)
        note.lineTo(cx + 4, cy - s + 2.5)
        painter.drawPath(note)
    elif 'VTT' in action or 'SRT' in action:
        # Subtitle icon (speech bubble / captions)
        painter.drawRoundedRect(QRectF(cx - s, cy - s + 2, s * 2, s * 2 - 4), 3, 3)
        painter.drawLine(QPointF(cx - 4, cy), QPointF(cx + 4, cy))
    elif 'SHA-256' in action:
        # Shield / security check icon
        sh = QPainterPath()
        sh.moveTo(cx - s + 1, cy - s + 1)
        sh.lineTo(cx + s - 1, cy - s + 1)
        sh.lineTo(cx + s - 1, cy)
        sh.quadTo(QPointF(cx, cy + s + 1), QPointF(cx - s + 1, cy))
        sh.closeSubpath()
        painter.drawPath(sh)


class RadialWheel(QWidget):
    action_selected = Signal(str, list)
    cancelled = Signal()

    def __init__(self, paths, items, parent=None):
        super().__init__(parent)
        self.paths = list(paths)
        self.items = list(items)
        self.highlighted = None
        self.geometry = RadialGeometry(len(self.items))
        self.radius = self.geometry.outer_radius + 40
        self.setFixedSize(int(self.radius * 2), int(self.radius * 2))
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setMouseTracking(True)
        self.setAcceptDrops(True)

        if len(self.paths) == 1:
            self.title = Path(self.paths[0]).name
        else:
            self.title = f"{len(self.paths)} files"

    def position_at(self, screen_pos=None):
        if screen_pos is None:
            screen_pos = QCursor.pos()
        screen = QApplication.screenAt(screen_pos) or QApplication.primaryScreen()
        geom = screen.availableGeometry()
        w, h = self.width(), self.height()
        x = min(max(screen_pos.x() - w // 2, geom.left()), geom.right() - w)
        y = min(max(screen_pos.y() - h // 2, geom.top()), geom.bottom() - h)
        self.move(int(x), int(y))

    def show_animated(self, screen_pos=None):
        self.position_at(screen_pos)
        self.setWindowOpacity(0.0)
        self.show()
        self.raise_()
        self.activateWindow()

        anim = QPropertyAnimation(self, b"windowOpacity", self)
        anim.setDuration(140)
        anim.setStartValue(0.0)
        anim.setEndValue(1.0)
        anim.setEasingCurve(QEasingCurve.OutCubic)
        anim.start()
        self._anim = anim

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setRenderHint(QPainter.TextAntialiasing)

        center = QPointF(self.width() / 2, self.height() / 2)

        # Ambient soft outer shadow
        shadow = QPainterPath()
        shadow.addEllipse(center, self.geometry.outer_radius + 10, self.geometry.outer_radius + 10)
        painter.fillPath(shadow, QColor(0, 0, 0, 75))

        if not self.items:
            # Empty / unsupported state
            empty_pill = QPainterPath()
            empty_pill.addRoundedRect(QRectF(center.x() - 110, center.y() - 25, 220, 50), 16, 16)
            painter.fillPath(empty_pill, QBrush(QColor(22, 22, 26, 245)))
            painter.setPen(QPen(QColor(255, 255, 255, 40), 1))
            painter.drawPath(empty_pill)
            painter.setFont(QFont("Segoe UI", 10, QFont.Bold))
            painter.setPen(QColor(220, 220, 225))
            painter.drawText(QRectF(center.x() - 100, center.y() - 12, 200, 24), Qt.AlignCenter, "No conversions available")
            return

        # Draw wedges
        for i, item in enumerate(self.items):
            is_hl = (self.highlighted == i)
            expand = 6 if is_hl else 0
            path = self.geometry.wedge_path(i, center, expand=expand)

            mid_pt = self.geometry.midpoint(i, center, expand=expand)

            if is_hl:
                grad = QLinearGradient(center, mid_pt)
                grad.setColorAt(0, QColor(255, 120, 20, 250))
                grad.setColorAt(1, QColor(230, 75, 0, 255))
                painter.setBrush(QBrush(grad))
                painter.setPen(QPen(QColor(255, 210, 170), 1.6))
            else:
                grad = QLinearGradient(center, mid_pt)
                grad.setColorAt(0, QColor(36, 36, 42, 235))
                grad.setColorAt(1, QColor(24, 24, 28, 245))
                painter.setBrush(QBrush(grad))
                painter.setPen(QPen(QColor(255, 255, 255, 32), 1.1))

            painter.drawPath(path)

            # Draw glyph icon
            draw_action_glyph(painter, mid_pt, item, is_hl)

            # Draw format label
            font = QFont("Segoe UI", 9, QFont.Bold if is_hl else QFont.DemiBold)
            painter.setFont(font)
            painter.setPen(QColor(255, 255, 255) if is_hl else QColor(215, 215, 220))

            fm = QFontMetrics(font)
            rect = fm.boundingRect(item)
            text_rect = QRectF(mid_pt.x() - rect.width() / 2 - 4, mid_pt.y() + 3, rect.width() + 8, 16)
            painter.drawText(text_rect, Qt.AlignCenter, item)

        # Center hub
        hub_r = self.geometry.inner_radius - 6
        hub_path = QPainterPath()
        hub_path.addEllipse(center, hub_r, hub_r)
        painter.fillPath(hub_path, QBrush(QColor(18, 18, 22, 250)))

        is_any_hl = (self.highlighted is not None and 0 <= self.highlighted < len(self.items))
        hub_border = QColor(255, 97, 10, 220) if is_any_hl else QColor(255, 255, 255, 45)
        painter.setPen(QPen(hub_border, 2 if is_any_hl else 1.2))
        painter.drawPath(hub_path)

        # Center hub text
        hub_text = self.items[self.highlighted] if is_any_hl else self.title
        painter.setFont(QFont("Segoe UI", 9, QFont.Bold))
        painter.setPen(QColor(255, 120, 40) if is_any_hl else QColor(190, 190, 195))
        painter.drawText(QRectF(center.x() - hub_r + 4, center.y() - 12, (hub_r - 4) * 2, 24),
                         Qt.AlignCenter, hub_text)

    def mouseMoveEvent(self, event):
        center = QPointF(self.width() / 2, self.height() / 2)
        offset = event.position() - center
        idx = self.geometry.index_at(offset)
        if idx != self.highlighted:
            self.highlighted = idx
            self.update()

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            if self.highlighted is not None and 0 <= self.highlighted < len(self.items):
                self._trigger_selection(self.items[self.highlighted])
            else:
                self.cancelled.emit()
                self.close()
        elif event.button() == Qt.RightButton:
            self.cancelled.emit()
            self.close()

    def _trigger_selection(self, target):
        self.action_selected.emit(target, self.paths)
        self.close()

    def dragEnterEvent(self, event):
        event.acceptProposedAction()
        self._update_drag_highlight(event.position())

    def dragMoveEvent(self, event):
        event.acceptProposedAction()
        self._update_drag_highlight(event.position())

    def _update_drag_highlight(self, pos):
        center = QPointF(self.width() / 2, self.height() / 2)
        offset = pos - center
        idx = self.geometry.index_at(offset)
        if idx != self.highlighted:
            self.highlighted = idx
            self.update()

    def dropEvent(self, event):
        self._update_drag_highlight(event.position())
        if self.highlighted is not None and 0 <= self.highlighted < len(self.items):
            self._trigger_selection(self.items[self.highlighted])
            event.acceptProposedAction()
        else:
            self.cancelled.emit()
            self.close()

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_Escape:
            self.cancelled.emit()
            self.close()
        elif event.key() in (Qt.Key_Return, Qt.Key_Enter):
            if self.highlighted is not None and 0 <= self.highlighted < len(self.items):
                self._trigger_selection(self.items[self.highlighted])
        elif event.key() in (Qt.Key_Left, Qt.Key_Up):
            self.highlighted = (self.highlighted - 1) % len(self.items) if self.highlighted is not None else 0
            self.update()
        elif event.key() in (Qt.Key_Right, Qt.Key_Down):
            self.highlighted = (self.highlighted + 1) % len(self.items) if self.highlighted is not None else 0
            self.update()


class StatusToast(QWidget):
    """Floating HUD pill displaying conversion progress and completion."""
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.last_folder = None

        layout = QHBoxLayout(self)
        layout.setContentsMargins(16, 10, 16, 10)
        layout.setSpacing(12)

        self.icon_label = QLabel()
        self.icon_label.setStyleSheet("font-size: 16px;")
        layout.addWidget(self.icon_label)

        text_box = QVBoxLayout()
        text_box.setSpacing(2)
        self.title_label = QLabel("Open Tangerine")
        self.title_label.setStyleSheet("font-weight: bold; font-size: 13px; color: #ffffff;")
        text_box.addWidget(self.title_label)

        self.subtitle_label = QLabel("Processing...")
        self.subtitle_label.setStyleSheet("font-size: 11px; color: #a0a0a5;")
        text_box.addWidget(self.subtitle_label)
        layout.addLayout(text_box)

        self.open_btn = QPushButton("Open")
        self.open_btn.setStyleSheet("""
            QPushButton {
                background: #ff610a;
                color: #111;
                font-weight: bold;
                border-radius: 6px;
                padding: 4px 10px;
                font-size: 11px;
            }
            QPushButton:hover {
                background: #ff762b;
            }
        """)
        self.open_btn.clicked.connect(self._open_folder)
        self.open_btn.hide()
        layout.addWidget(self.open_btn)

        self.dismiss_timer = QTimer(self)
        self.dismiss_timer.setSingleShot(True)
        self.dismiss_timer.timeout.connect(self.hide_animated)

        self.adjustSize()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        rect = QRectF(self.rect()).adjusted(1, 1, -1, -1)
        path = QPainterPath()
        path.addRoundedRect(rect, 14, 14)
        painter.fillPath(path, QBrush(QColor(22, 22, 26, 245)))
        painter.setPen(QPen(QColor(255, 97, 10, 120), 1.2))
        painter.drawPath(path)

    def position_toast(self):
        screen = QApplication.primaryScreen()
        if screen:
            geom = screen.availableGeometry()
            self.adjustSize()
            x = geom.right() - self.width() - 28
            y = geom.bottom() - self.height() - 28
            self.move(x, y)

    def show_converting(self, count, target):
        self.dismiss_timer.stop()
        self.open_btn.hide()
        self.icon_label.setText("🍊")
        self.title_label.setText(f"Converting to {target}…")
        self.subtitle_label.setText(f"{count} file(s) · Beside original(s)")
        self.position_toast()
        self.setWindowOpacity(1.0)
        self.show()

    def show_finished(self, outputs):
        self.icon_label.setText("✨")
        if outputs:
            self.last_folder = str(Path(outputs[-1]).parent)
            self.title_label.setText("Conversion complete")
            self.subtitle_label.setText(f"{len(outputs)} file(s) saved beside original(s)")
            self.open_btn.show()
        else:
            self.title_label.setText("Batch cancelled or failed")
            self.subtitle_label.setText("No output files created")
            self.open_btn.hide()

        self.position_toast()
        self.show()
        self.dismiss_timer.start(5000)

    def show_error(self, message):
        self.icon_label.setText("⚠️")
        self.title_label.setText("Conversion error")
        self.subtitle_label.setText(str(message)[:60])
        self.open_btn.hide()
        self.position_toast()
        self.show()
        self.dismiss_timer.start(5000)

    def _open_folder(self):
        if self.last_folder:
            QDesktopServices.openUrl(QUrl.fromLocalFile(self.last_folder))
            self.hide()

    def hide_animated(self):
        anim = QPropertyAnimation(self, b"windowOpacity", self)
        anim.setDuration(300)
        anim.setStartValue(1.0)
        anim.setEndValue(0.0)
        anim.finished.connect(self.hide)
        anim.start()
        self._anim = anim
