"""Shared rounded, frosted radial material for floating and in-window wheels."""
import math
from PySide6.QtCore import Qt, QRectF, QPointF
from PySide6.QtGui import QColor, QPainterPath, QPen, QLinearGradient, QRadialGradient


def format_label(value):
    return {'Image → PDF': 'PDF', 'PDF → Text': 'TXT', 'Split PDF': 'SPLIT',
            'Merge PDFs': 'MERGE', 'SRT → VTT': 'VTT', 'VTT → SRT': 'SRT',
            'DOCX → Text': 'TXT', 'DOCX → PDF (text only)': 'PDF'}.get(value, value)


def target_at(point, formats):
    dx, dy = point.x()-190, point.y()-190
    if not formats or not 72 <= math.hypot(dx, dy) <= 176:
        return -1
    return int(((math.degrees(math.atan2(dy, dx))+90+180/len(formats)) % 360)
               / (360/len(formats)))


def point(radius, angle):
    radians = math.radians(angle)
    return QPointF(190 + radius*math.cos(radians), 190 + radius*math.sin(radians))


def segment(index, count):
    outer, inner = QRectF(16, 16, 348, 348), QRectF(118, 118, 144, 144)
    path = QPainterPath()
    if count == 1:
        path.addEllipse(outer); path.addEllipse(inner)
        path.setFillRule(Qt.OddEvenFill)
        return path
    step = 360/count
    start, end = index*step-90-step/2+2.2, index*step-90+step/2-2.2
    rounding = min(5, step/8)
    path.moveTo(point(174, start+rounding))
    path.arcTo(outer, -(start+rounding), -(end-start-2*rounding))
    path.quadTo(point(174, end), point(161, end))
    path.lineTo(point(85, end))
    path.quadTo(point(72, end), point(72, end-rounding*1.7))
    path.arcTo(inner, -(end-rounding*1.7), end-start-3.4*rounding)
    path.quadTo(point(72, start), point(85, start))
    path.lineTo(point(161, start))
    path.quadTo(point(174, start), point(174, start+rounding))
    path.closeSubpath()
    return path


def draw_ring(p, formats, selected=-1):
    labels = formats or ['Drop files']
    # Light passing through a pearly rim gives the separate panes a shared surface.
    rim = QLinearGradient(20, 5, 340, 380)
    rim.setColorAt(0, QColor(248, 253, 255, 170))
    rim.setColorAt(.55, QColor(161, 184, 198, 85))
    rim.setColorAt(1, QColor(245, 250, 255, 130))
    p.setBrush(rim); p.setPen(QPen(QColor(255, 255, 255, 100), 1))
    p.drawEllipse(QRectF(7, 7, 366, 366))
    for i, label in enumerate(labels):
        active = i == selected
        path = segment(i, len(labels))
        p.save(); p.translate(0, 3)
        p.setBrush(QColor(12, 33, 48, 18)); p.setPen(QPen(QColor(12, 33, 48, 12), 5))
        p.drawPath(path); p.restore()
        material = QLinearGradient(45, 15, 300, 375)
        material.setColorAt(0, QColor(255, 179, 107, 245) if active else QColor(255, 255, 255, 205))
        material.setColorAt(.5, QColor(255, 102, 25, 235) if active else QColor(224, 237, 243, 178))
        material.setColorAt(1, QColor(235, 79, 12, 245) if active else QColor(183, 206, 220, 200))
        p.setBrush(material); p.setPen(QPen(QColor(255, 255, 255, 220), 1.1)); p.drawPath(path)
        p.save(); p.setClipPath(path)
        sheen = QRadialGradient(125, 30, 260)
        sheen.setColorAt(0, QColor(255, 255, 255, 95)); sheen.setColorAt(1, QColor(255, 255, 255, 0))
        p.fillRect(QRectF(10, 10, 360, 360), sheen); p.restore()
        # Single-output documents use a full ring, with the label at twelve o'clock.
        location = point(123, i*360/len(labels)-90)
        p.setPen(QColor('#ffffff') if active else QColor('#213340'))
        font = p.font(); font.setPointSize(11); font.setBold(True); p.setFont(font)
        p.drawText(QRectF(location.x()-47, location.y()-22, 94, 44),
                   Qt.AlignCenter | Qt.TextWordWrap, format_label(label))


def draw_hub(p, formats, selected=-1, notice=''):
    value = formats[selected] if 0 <= selected < len(formats) else (formats[0] if formats else '')
    halo = QRadialGradient(174, 163, 84)
    halo.setColorAt(0, QColor(255, 255, 255, 248)); halo.setColorAt(1, QColor(217, 234, 243, 190))
    p.setBrush(halo); p.setPen(QPen(QColor(255, 255, 255, 220), 1))
    p.drawEllipse(QRectF(126, 126, 128, 128))
    p.setBrush(QColor(255, 255, 255, 155)); p.setPen(QPen(QColor(255, 255, 255, 200), 1))
    p.drawRoundedRect(QRectF(141, 169, 98, 42), 21, 21)
    font = p.font(); font.setPointSize(10); font.setBold(False); p.setFont(font)
    p.setPen(QColor('#263d4a'))
    p.drawText(QRectF(142, 169, 96, 42), Qt.AlignCenter, format_label(value) if value else 'DROP')
    caption = 'Convert to '+format_label(value) if value else 'Drag local files onto the wheel'
    if value in ('Merge PDFs', 'Split PDF'): caption = value
    if notice:caption = notice
    p.setBrush(QColor(239, 248, 253, 225)); p.setPen(QPen(QColor(255, 255, 255, 170), 1))
    p.drawRoundedRect(QRectF(55, 385, 270, 31), 15, 15)
    p.setPen(QColor('#28404e'))
    p.drawText(QRectF(58, 385, 264, 31), Qt.AlignCenter, caption)
