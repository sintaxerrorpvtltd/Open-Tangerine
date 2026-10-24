"""Notch-style conversion island for the Windows Shift wheel. PCs have no physical notch."""
import ctypes
import os
from pathlib import Path
from PySide6.QtCore import Qt, QRectF, QTimer, QPoint, QPropertyAnimation, QEasingCurve, QUrl, QSize
from PySide6.QtGui import QPainter, QColor, QPen, QLinearGradient, QRadialGradient, QCursor, QDesktopServices
from PySide6.QtWidgets import (QApplication, QWidget, QLabel, QPushButton, QProgressBar, QHBoxLayout, QVBoxLayout,
                               QSizePolicy)
from glass_design import format_label

STYLES = ('Pure black', 'Glass', 'Off')
RETRACT_MS = 2000
WIDTH, HEIGHT, MARGIN = 440, 92, 10
ISLAND_STYLE = '''
QWidget { background: transparent; color: #f5f3ed; }
QLabel#title { font-size: 13px; font-weight: bold; }
QLabel#detail { font-size: 11px; color: #c9c4ba; }
QLabel#detail[failed="true"] { color: #ff8a80; }
QPushButton { background: #2c2c2e; border: 1px solid #4a4a4c; border-radius: 9px; padding: 3px 10px; font-size: 11px; }
QPushButton:hover { background: #3a3a3c; }
QPushButton:focus { border: 1px solid #ff610a; }
QProgressBar { background: #2c2c2e; border: none; border-radius: 2px; max-height: 4px; }
QProgressBar::chunk { background: #ff610a; border-radius: 2px; }
'''


def animations_enabled():
    """Follow the Windows 'Animation effects' setting; other platforms animate."""
    if os.name != 'nt':
        return True
    try:
        value = ctypes.c_int(1)
        # SPI_GETCLIENTAREAANIMATION
        if ctypes.windll.user32.SystemParametersInfoW(0x1042, 0, ctypes.byref(value), 0):
            return bool(value.value)
    except (AttributeError, OSError):
        pass
    return True


class ElidedLabel(QLabel):
    """One line that ends in an ellipsis instead of widening the island."""
    def __init__(self):
        super().__init__(); self.setTextFormat(Qt.PlainText)
        self.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)

    def shown_text(self):
        return self.fontMetrics().elidedText(self.text(), Qt.ElideRight, max(self.width(), 0))

    def minimumSizeHint(self):
        return QSize(0, super().minimumSizeHint().height())

    def paintEvent(self, event):
        p = QPainter(self)
        p.setPen(self.palette().color(self.foregroundRole()))
        p.drawText(self.rect(), Qt.AlignLeft | Qt.AlignVCenter, self.shown_text())


class ConversionIsland(QWidget):
    """Shows one wheel batch. Successes retract; failures stay until dismissed."""
    def __init__(self, window, style='Pure black'):
        super().__init__(None, Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
                         | Qt.WindowDoesNotAcceptFocus)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        # Never a drop target, so it cannot intercept an Explorer drag or the wheel.
        self.setAcceptDrops(False)
        self.setWindowTitle('Open Tangerine conversion island')
        self.setAccessibleName('Conversion progress')
        self.setStyleSheet(ISLAND_STYLE)
        self.setFixedSize(WIDTH, HEIGHT)
        self.owner = window
        self.style_name = style if style in STYLES else STYLES[0]
        self.batch = None
        self.count = 0
        self.target = ''
        self.phase = 'idle'
        self.outputs = []
        self.retracting = False
        self.retract_timer = QTimer(self); self.retract_timer.setSingleShot(True)
        self.retract_timer.timeout.connect(self.retract)
        self.motion = QPropertyAnimation(self, b'pos', self)
        self.motion.setDuration(180); self.motion.setEasingCurve(QEasingCurve.OutCubic)
        self.motion.finished.connect(self.motion_finished)

        layout = QHBoxLayout(self); layout.setContentsMargins(66, 12, 16, 12); layout.setSpacing(10)
        text = QVBoxLayout(); text.setSpacing(3); layout.addLayout(text, 1)
        self.title = ElidedLabel(); self.title.setObjectName('title')
        self.detail = ElidedLabel(); self.detail.setObjectName('detail')
        self.bar = QProgressBar(); self.bar.setTextVisible(False)
        self.bar.setAccessibleName('Conversion progress')
        for widget in (self.title, self.detail, self.bar): text.addWidget(widget)
        self.open_button = QPushButton('Open'); self.open_button.clicked.connect(self.open_output)
        self.folder_button = QPushButton('Show folder'); self.folder_button.clicked.connect(self.show_folder)
        self.dismiss_button = QPushButton('✕'); self.dismiss_button.clicked.connect(self.retract)
        self.open_button.setAccessibleName('Open converted file')
        self.folder_button.setAccessibleName('Show output folder')
        self.dismiss_button.setAccessibleName('Dismiss conversion result')
        self.dismiss_button.setToolTip('Dismiss')
        for button in (self.open_button, self.folder_button, self.dismiss_button):
            button.setCursor(Qt.PointingHandCursor); button.hide(); layout.addWidget(button)

    def set_style(self, style):
        self.style_name = style if style in STYLES else STYLES[0]
        if self.style_name == 'Off':
            self.stop()
        self.update()

    def handles(self, batch):
        return batch is not None and self.batch is batch

    def track(self, batch, target, count):
        """Follow a batch started by the Shift wheel. Returns False when disabled."""
        if self.style_name == 'Off' or batch is None:
            return False
        self.batch, self.target, self.count = batch, target, count
        self.phase, self.outputs = 'running', []
        self.retract_timer.stop()
        noun = 'file' if count == 1 else 'files'
        self.title.setText(f'Converting {count} {noun} to {format_label(target)}')
        self.set_detail('Starting…')
        # A single file reports progress only when it ends, so show activity instead.
        self.bar.setRange(0, 0 if count == 1 else count); self.bar.setValue(0); self.bar.show()
        for button in (self.open_button, self.folder_button, self.dismiss_button): button.hide()
        batch.progress.connect(self.progressed)
        batch.finished.connect(self.finished)
        self.setAccessibleDescription(self.title.text())
        self.reveal()
        return True

    def set_detail(self, text, failed=False):
        self.detail.setText(text); self.detail.setToolTip(text)
        self.detail.setProperty('failed', failed)
        self.detail.style().unpolish(self.detail); self.detail.style().polish(self.detail)

    def progressed(self, done, total):
        if self.sender() is not self.batch:
            return
        if total > 1:
            self.bar.setRange(0, total); self.bar.setValue(done)
        self.set_detail(f'{done} of {total} done')

    def finished(self):
        if self.sender() is not self.batch:
            return
        self.outputs = list(self.owner.outputs)
        errors = list(self.owner.batch_errors)
        cancelled = self.batch.cancel.is_set()
        label = format_label(self.target)
        self.bar.hide()
        if cancelled:
            self.phase = 'cancelled'
            self.title.setText('Conversion cancelled')
            self.set_detail(f'{len(self.outputs)} completed output(s) kept')
        elif errors:
            self.phase = 'failed'
            failed = len(errors)
            self.title.setText(f'Couldn’t convert {failed} of {self.count} to {label}')
            self.set_detail(errors[0][:160], failed=True)
        else:
            self.phase = 'done'
            noun = 'file' if self.count == 1 else 'files'
            self.title.setText(f'Converted {self.count} {noun} to {label}')
            self.set_detail('Ready · ' + Path(self.outputs[-1]).name if self.outputs else 'Ready')
        self.open_button.setVisible(self.phase == 'done' and len(self.outputs) == 1)
        self.folder_button.setVisible(bool(self.outputs))
        self.dismiss_button.setVisible(self.phase == 'failed')
        self.setAccessibleDescription(self.title.text() + '. ' + self.detail.text())
        self.update()
        # Failures stay visible so their message can be read.
        if self.phase != 'failed':
            self.retract_timer.start(RETRACT_MS)

    def placement(self):
        screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        area = screen.availableGeometry()
        return QPoint(area.center().x() - WIDTH // 2, area.top() + MARGIN), area.top() - HEIGHT

    def reveal(self):
        # Reopening interrupts a dismissal in progress.
        self.retracting = False
        self.motion.stop()
        resting, hidden_y = self.placement()
        if animations_enabled() and not self.isVisible():
            self.move(resting.x(), hidden_y); self.show()
            self.motion.setStartValue(self.pos()); self.motion.setEndValue(resting); self.motion.start()
        else:
            self.move(resting); self.show()
        self.raise_()

    def retract(self):
        self.retract_timer.stop()
        if not self.isVisible():
            return
        self.retracting = True
        if animations_enabled():
            self.motion.stop()
            self.motion.setStartValue(self.pos())
            self.motion.setEndValue(QPoint(self.x(), self.y() - HEIGHT - MARGIN))
            self.motion.start()
        else:
            self.motion_finished()

    def motion_finished(self):
        if self.retracting:
            self.retracting = False
            self.hide()
            self.phase = 'idle'

    def open_output(self):
        if self.outputs:
            QDesktopServices.openUrl(QUrl.fromLocalFile(self.outputs[-1]))

    def show_folder(self):
        if self.outputs:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(Path(self.outputs[-1]).parent)))

    def stop(self):
        self.retract_timer.stop(); self.motion.stop()
        self.retracting = False
        self.hide()
        self.phase = 'idle'

    def paintEvent(self, event):
        p = QPainter(self); p.setRenderHint(QPainter.Antialiasing)
        shape = QRectF(1, 1, self.width() - 2, self.height() - 2)
        if self.style_name == 'Glass':
            # Qt cannot blur what is behind, so smoked glass stays dense enough to read over text.
            material = QLinearGradient(0, 0, 0, self.height())
            material.setColorAt(0, QColor(62, 66, 72, 242)); material.setColorAt(1, QColor(22, 24, 28, 248))
            p.setBrush(material); p.setPen(QPen(QColor(255, 255, 255, 110), 1))
            p.drawRoundedRect(shape, 30, 30)
            sheen = QLinearGradient(0, 0, 0, self.height() / 2)
            sheen.setColorAt(0, QColor(255, 255, 255, 40)); sheen.setColorAt(1, QColor(255, 255, 255, 0))
            p.setBrush(sheen); p.setPen(Qt.NoPen)
        else:
            # Solid black with no gray border, like the Mac default.
            p.setBrush(QColor(0, 0, 0)); p.setPen(Qt.NoPen)
        p.drawRoundedRect(shape, 30, 30)
        self.draw_citrus(p)

    def draw_citrus(self, p):
        # Citrus status mark: orange while working, green done, red failed.
        tint = {'done': QColor('#34c759'), 'failed': QColor('#ff453a')}.get(self.phase, QColor('#ff610a'))
        fruit = QRadialGradient(28, 40, 26)
        fruit.setColorAt(0, QColor('#ffd166')); fruit.setColorAt(1, QColor('#ff610a'))
        p.setPen(Qt.NoPen); p.setBrush(fruit); p.drawEllipse(QRectF(18, 28, 36, 36))
        p.setBrush(QColor('#4caf50')); p.drawEllipse(QRectF(36, 21, 13, 7))
        p.setBrush(tint); p.setPen(QPen(QColor(0, 0, 0), 2)); p.drawEllipse(QRectF(43, 51, 14, 14))
