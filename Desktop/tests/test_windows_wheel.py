import math
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PySide6.QtCore import QMimeData, QPoint, QPointF, QUrl, Qt, QEventLoop, QTimer
from PySide6.QtGui import QDragEnterEvent, QDropEvent
from PySide6.QtWidgets import QApplication
from windows_wheel import available_formats, DragWheel, WindowsShiftWheel
from app import Window


class WheelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def test_capabilities_intersect_for_entire_selection(self):
        self.assertEqual(available_formats(['a.png', 'b.jpg'])[-1], 'Image → PDF')
        self.assertEqual(available_formats(['a.png', 'b.pdf']), [])
        self.assertEqual(available_formats(['a.mp4']), [])
        self.assertIn('MP4', available_formats(['a.mp4'], True))
        self.assertNotIn('MP4', available_formats(['a.mp4', 'b.mp3'], True))
        self.assertNotIn('Merge PDFs', available_formats(['a.pdf']))
        self.assertIn('Merge PDFs', available_formats(['a.pdf', 'b.pdf']))
        self.assertEqual(available_formats(['a.srt']), ['SRT → VTT'])
        self.assertEqual(available_formats(['a.vtt']), ['VTT → SRT'])
        self.assertEqual(available_formats(['a.svg']), [])
        self.assertEqual(available_formats(['file.docx']), ['DOCX → Text', 'DOCX → PDF (text only)'])
        self.assertEqual(available_formats(['file.docx', 'b.pdf']), [])
        self.assertEqual(available_formats(['file.doc']), [])
        self.assertEqual(available_formats(['a.png'] * 101), [])

    def test_ring_targets_and_hollow_center(self):
        w = DragWheel(lambda: '')
        w.formats = available_formats(['a.png'])
        self.assertFalse(w.mask().contains(QPoint(190, 190)))
        self.assertEqual(w.sector(QPointF(190, 190)), -1)
        self.assertEqual(w.sector(QPointF(0, 0)), -1)
        for i in range(6):
            angle = math.radians(i*60-90)
            self.assertEqual(w.sector(QPointF(190+120*math.cos(angle),
                                              190+120*math.sin(angle))), i)
        w.close()

    def test_rounded_panes_match_radial_targets_for_each_file_family(self):
        from glass_design import segment, point, target_at
        for count in (1, 2, 3, 4, 6):
            formats = list(map(str, range(count)))
            for index in range(count):
                location = point(123, index*360/count-90)
                self.assertTrue(segment(index, count).contains(location))
                self.assertEqual(target_at(location, formats), index)

    def test_external_drop_uses_actual_payload_and_copy_action(self):
        w = DragWheel(lambda: '')
        received = []
        w.convert.connect(lambda paths, target: received.append((paths, target)))
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)/'actual.png'; source.write_bytes(b'fixture')
            mime = QMimeData(); mime.setUrls([QUrl.fromLocalFile(str(source))])
            enter = QDragEnterEvent(QPoint(190, 70), Qt.CopyAction | Qt.MoveAction,
                                    mime, Qt.LeftButton, Qt.ShiftModifier)
            w.dragEnterEvent(enter)
            self.assertTrue(enter.isAccepted())
            self.assertEqual(enter.dropAction(), Qt.CopyAction)
            self.assertEqual(received, [])
            drop = QDropEvent(QPointF(190, 70), Qt.CopyAction | Qt.MoveAction,
                              mime, Qt.LeftButton, Qt.ShiftModifier)
            w.dropEvent(drop)
            self.assertEqual(received, [([str(source.resolve())], 'PNG')])
            self.assertEqual(drop.dropAction(), Qt.CopyAction)
            # No shell move can be acknowledged, even if Shift requested a move.
            move = QDropEvent(QPointF(190, 70), Qt.MoveAction,
                              mime, Qt.LeftButton, Qt.ShiftModifier)
            w.dropEvent(move)
            self.assertFalse(move.isAccepted()); self.assertEqual(len(received), 1)
            # Releasing in the center or outside a sector never converts.
            center = QDropEvent(QPointF(190, 190), Qt.CopyAction,
                                mime, Qt.LeftButton, Qt.ShiftModifier)
            w.dropEvent(center)
            self.assertFalse(center.isAccepted()); self.assertEqual(len(received), 1)
        w.close()

    def test_nonfile_and_remote_payload_rejected(self):
        w = DragWheel(lambda: '')
        for url in ('https://example.com/file.png', 'file:///does-not-exist.png'):
            mime = QMimeData(); mime.setUrls([QUrl(url)])
            event = QDragEnterEvent(QPoint(190, 70), Qt.CopyAction,
                                    mime, Qt.LeftButton, Qt.ShiftModifier)
            w.dragEnterEvent(event); self.assertFalse(event.isAccepted())
        w.close()

    def test_cancelled_selection_lookup_cannot_reopen_wheel(self):
        window = Window(global_wheel=False)
        with patch('windows_wheel.ctypes.WinDLL', create=True, return_value=Mock()):
            monitor = WindowsShiftWheel(window)
        monitor.timer.stop()
        monitor.held = lambda key: key in (0x10, 0x1B)
        monitor.poll()
        self.assertTrue(monitor.cancelled)
        monitor.selection_ready(0, None)
        self.assertFalse(monitor.overlay.isVisible())
        monitor.stop(); window.close()

    def test_disabled_wheel_does_not_poll_input(self):
        window = Window(global_wheel=False)
        with patch('windows_wheel.ctypes.WinDLL', create=True, return_value=Mock()):
            monitor = WindowsShiftWheel(window)
        self.assertFalse(monitor.timer.isActive())
        monitor.set_enabled(True)
        self.assertTrue(monitor.timer.isActive())
        monitor.set_enabled(False)
        self.assertFalse(monitor.timer.isActive())
        self.assertTrue(monitor.cancelled)
        monitor.stop(); window.close()

    def test_shift_typing_and_editor_drags_do_not_start_lookup(self):
        window = Window(global_wheel=False)
        user = Mock()
        user.GetSystemMetrics.return_value = 0
        user.GetForegroundWindow.return_value = 42
        def class_name(hwnd, buffer, size):
            buffer.value = 'CorelDRAW'
            return 9
        user.GetClassNameW.side_effect = class_name
        with patch('windows_wheel.ctypes.WinDLL', create=True, return_value=user):
            monitor = WindowsShiftWheel(window)
        monitor.timer.stop(); monitor.enabled = True
        with patch.object(monitor.lookup, 'start') as start:
            monitor.held = lambda key: key == 0x10
            monitor.poll()
            monitor.held = lambda key: key in (0x10, 1)
            monitor.gesture_started = 0
            monitor.poll()
            start.assert_not_called()
        monitor.stop(); window.close()

    def test_only_sustained_explorer_drag_starts_lookup_and_release_cancels(self):
        window = Window(global_wheel=False)
        user = Mock()
        user.GetSystemMetrics.return_value = 0
        user.GetForegroundWindow.return_value = 42
        def class_name(hwnd, buffer, size):
            buffer.value = 'CabinetWClass'
            return 13
        user.GetClassNameW.side_effect = class_name
        with patch('windows_wheel.ctypes.WinDLL', create=True, return_value=user):
            monitor = WindowsShiftWheel(window)
        monitor.timer.stop(); monitor.enabled = True
        monitor.held = lambda key: key in (0x10, 1)
        with patch.object(monitor.lookup, 'start') as start, \
             patch('windows_wheel.time.monotonic', side_effect=[10, 10.1, 10.4]):
            monitor.poll(); monitor.poll()
            start.assert_not_called()
            # A valid absolute OS path is needed even when this test runs on Linux/Mac.
            with patch.dict(os.environ, {'SystemRoot': str(Path.cwd() / 'Windows')}):
                monitor.poll()
            start.assert_called_once()
        monitor.held = lambda key: key == 0x10
        monitor.poll()
        self.assertTrue(monitor.cancelled)
        self.assertFalse(monitor.overlay.isVisible())
        monitor.stop(); window.close()

    def test_wheel_conversion_runs_existing_worker_and_keeps_original(self):
        from PIL import Image
        window = Window(global_wheel=False)
        with patch('windows_wheel.ctypes.WinDLL', create=True, return_value=Mock()):
            monitor = WindowsShiftWheel(window)
        monitor.timer.stop()
        with tempfile.TemporaryDirectory() as directory:
            sources = [Path(directory)/f'source-{i}.png' for i in range(4)]
            for source in sources: Image.new('RGB', (12, 9), 'orange').save(source)
            originals = [source.read_bytes() for source in sources]
            mime = QMimeData(); mime.setUrls([QUrl.fromLocalFile(str(source)) for source in sources])
            drop = QDropEvent(QPointF(294, 130), Qt.CopyAction,
                              mime, Qt.LeftButton, Qt.ShiftModifier)
            monitor.overlay.dropEvent(drop)
            self.assertTrue(drop.isAccepted())
            self.assertFalse(window.isVisible())
            loop = QEventLoop()
            window.batch.finished.connect(loop.quit)
            timeout = QTimer(); timeout.setSingleShot(True)
            timeout.timeout.connect(loop.quit); timeout.start(10000)
            loop.exec(); timeout.stop()
            self.assertFalse(window.batch.isRunning())
            self.assertEqual(window.target.currentText(), 'JPEG')
            self.assertEqual(len(window.outputs), 4)
            self.assertEqual(Path(window.outputs[0]).suffix, '.jpg')
            self.assertEqual([source.read_bytes() for source in sources], originals)
            self.assertFalse(window.isVisible())
        monitor.stop(); window.close()


if __name__ == '__main__':
    unittest.main()
