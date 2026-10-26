import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch, Mock

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PySide6.QtCore import QObject, QMimeData, QPointF, QUrl, Qt, QEventLoop, QTimer, Signal
from PySide6.QtGui import QDropEvent
from PySide6.QtWidgets import QApplication, QSystemTrayIcon
from island import ConversionIsland, RETRACT_MS, MARGIN, WIDTH, HEIGHT
from windows_wheel import WindowsShiftWheel
from background import BackgroundController
from app import Window


class FakeBatch(QObject):
    progress = Signal(int, int)
    finished = Signal()

    def __init__(self):
        super().__init__(); self.cancel = threading.Event()


class IslandTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.still = patch('island.animations_enabled', return_value=False); self.still.start()
        self.addCleanup(self.still.stop)

    def wheel_window(self):
        window = Window(global_wheel=False)
        window.island = ConversionIsland(window)
        with patch('windows_wheel.ctypes.WinDLL', create=True, return_value=Mock()):
            monitor = WindowsShiftWheel(window)
        monitor.timer.stop()
        return window, monitor

    def drop(self, monitor, window, sources, point=QPointF(294, 130)):
        mime = QMimeData(); mime.setUrls([QUrl.fromLocalFile(str(source)) for source in sources])
        event = QDropEvent(point, Qt.CopyAction, mime, Qt.LeftButton, Qt.ShiftModifier)
        monitor.overlay.dropEvent(event)
        self.assertTrue(event.isAccepted())
        loop = QEventLoop()
        window.batch.finished.connect(loop.quit)
        timeout = QTimer(); timeout.setSingleShot(True)
        timeout.timeout.connect(loop.quit); timeout.start(15000)
        loop.exec(); timeout.stop()
        self.app.processEvents()
        self.assertFalse(window.batch.isRunning())

    def test_wheel_success_shows_island_then_retracts(self):
        from PIL import Image
        window, monitor = self.wheel_window()
        island = window.island
        with tempfile.TemporaryDirectory() as directory:
            sources = [Path(directory)/f'source-{i}.png' for i in range(4)]
            for source in sources: Image.new('RGB', (12, 9), 'orange').save(source)
            originals = [source.read_bytes() for source in sources]
            self.drop(monitor, window, sources)
            self.assertTrue(island.isVisible())
            self.assertEqual(island.phase, 'done')
            self.assertEqual(island.title.text(), 'Converted 4 files to JPEG')
            self.assertEqual(len(island.outputs), 4)
            self.assertTrue(island.folder_button.isVisibleTo(island))
            # Open applies to a single output; four files offer the folder instead.
            self.assertFalse(island.open_button.isVisibleTo(island))
            self.assertFalse(island.dismiss_button.isVisibleTo(island))
            self.assertTrue(island.retract_timer.isActive())
            self.assertEqual(island.retract_timer.interval(), RETRACT_MS)
            self.assertEqual([source.read_bytes() for source in sources], originals)
            island.retract_timer.timeout.emit()
            self.assertFalse(island.isVisible())
        monitor.stop(); window.close(); island.close()

    def test_wheel_failure_stays_until_dismissed(self):
        window, monitor = self.wheel_window()
        island = window.island
        with tempfile.TemporaryDirectory() as directory:
            broken = Path(directory)/'broken.png'; broken.write_bytes(b'not really a png')
            self.drop(monitor, window, [broken])
            self.assertEqual(island.phase, 'failed')
            self.assertTrue(island.isVisible())
            self.assertTrue(island.title.text().startswith('Couldn’t convert 1 of 1'))
            self.assertTrue(island.detail.property('failed'))
            self.assertEqual(island.detail.text(), window.batch_errors[0][:160])
            self.assertFalse(island.retract_timer.isActive())
            self.assertTrue(island.dismiss_button.isVisibleTo(island))
            self.assertFalse(island.folder_button.isVisibleTo(island))
            # A long error must not squeeze the dismiss button out of the island.
            long_error = 'cannot identify image file ' + repr('C:\\Users\\someone\\' + 'nested\\' * 30 + 'broken.png')
            island.set_detail(long_error, failed=True); island.layout().activate()
            button = island.dismiss_button.geometry()
            self.assertEqual((island.width(), island.height()), (WIDTH, HEIGHT))
            self.assertTrue(island.rect().contains(button))
            self.assertGreaterEqual(button.width(), island.dismiss_button.minimumSizeHint().width())
            self.assertEqual(island.detail.toolTip(), long_error)
            self.assertTrue(island.detail.shown_text().endswith('…'))
            self.assertEqual(broken.read_bytes(), b'not really a png')
            island.dismiss_button.click()
            self.assertFalse(island.isVisible())
        monitor.stop(); window.close(); island.close()

    def test_single_output_offers_open(self):
        window = Window(global_wheel=False); island = ConversionIsland(window)
        batch = FakeBatch()
        self.assertTrue(island.track(batch, 'Image → PDF', 1))
        self.assertEqual(island.title.text(), 'Converting 1 file to PDF')
        self.assertEqual(island.bar.maximum(), 0)
        window.outputs = [str(Path(tempfile.gettempdir())/'only.pdf')]; window.batch_errors = []
        batch.finished.emit()
        self.assertEqual(island.phase, 'done')
        self.assertTrue(island.open_button.isVisibleTo(island))
        self.assertEqual(island.detail.text(), 'Ready · only.pdf')
        with patch('island.QDesktopServices.openUrl') as open_url:
            island.open_button.click()
            self.assertEqual(open_url.call_args.args[0].toLocalFile(), Path(window.outputs[0]).as_posix())
        island.stop(); window.close()

    def test_cancelled_batch_reports_kept_outputs_and_retracts(self):
        window = Window(global_wheel=False); island = ConversionIsland(window)
        batch = FakeBatch(); island.track(batch, 'PNG', 3)
        batch.progress.emit(1, 3)
        self.assertEqual((island.bar.value(), island.bar.maximum()), (1, 3))
        self.assertEqual(island.detail.text(), '1 of 3 done')
        window.outputs = ['a.png']; window.batch_errors = ['Cancelled; completed outputs are kept.']
        batch.cancel.set(); batch.finished.emit()
        self.assertEqual(island.phase, 'cancelled')
        self.assertEqual(island.detail.text(), '1 completed output(s) kept')
        self.assertTrue(island.retract_timer.isActive())
        island.stop(); window.close()

    def test_stale_batch_signals_are_ignored(self):
        window = Window(global_wheel=False); island = ConversionIsland(window)
        old, new = FakeBatch(), FakeBatch()
        island.track(old, 'PNG', 2); island.track(new, 'JPEG', 2)
        window.outputs = []; window.batch_errors = ['old failure']
        old.progress.emit(2, 2); old.finished.emit()
        self.assertEqual(island.phase, 'running')
        self.assertEqual(island.title.text(), 'Converting 2 files to JPEG')
        self.assertTrue(island.handles(new)); self.assertFalse(island.handles(old))
        island.stop(); window.close()

    def test_off_style_never_shows(self):
        window = Window(global_wheel=False); island = ConversionIsland(window, 'Off')
        self.assertFalse(island.track(FakeBatch(), 'PNG', 1))
        self.assertFalse(island.isVisible())
        island.set_style('Glass'); self.assertTrue(island.track(FakeBatch(), 'PNG', 1))
        self.assertTrue(island.isVisible())
        island.set_style('Off'); self.assertFalse(island.isVisible())
        island.set_style('unknown'); self.assertEqual(island.style_name, 'Pure black')
        island.stop(); window.close()

    def test_island_never_takes_drops_or_focus(self):
        island = ConversionIsland(Mock())
        self.assertFalse(island.acceptDrops())
        self.assertTrue(island.windowFlags() & Qt.WindowDoesNotAcceptFocus)
        self.assertTrue(island.testAttribute(Qt.WA_ShowWithoutActivating))
        island.close()

    def test_top_center_of_cursor_screen_work_area(self):
        island = ConversionIsland(Mock())
        area = (QApplication.screenAt(island.cursor().pos()) or QApplication.primaryScreen()).availableGeometry()
        resting, hidden = island.placement()
        self.assertEqual(resting.x(), area.center().x() - WIDTH // 2)
        self.assertEqual(resting.y(), area.top() + MARGIN)
        self.assertLess(hidden, area.top())
        island.close()

    def test_reopening_interrupts_retraction(self):
        window = Window(global_wheel=False); island = ConversionIsland(window)
        island.track(FakeBatch(), 'PNG', 1)
        with patch('island.animations_enabled', return_value=True):
            island.retract()
            self.assertTrue(island.retracting)
            island.track(FakeBatch(), 'JPEG', 1)
            self.assertFalse(island.retracting)
            island.motion_finished()
        self.assertTrue(island.isVisible())
        self.assertEqual(island.phase, 'running')
        island.stop(); window.close()

    def test_tray_skips_duplicate_message_and_quit_closes_island(self):
        window = Window(global_wheel=False); window.island = ConversionIsland(window)
        previous = self.app.quitOnLastWindowClosed()
        with patch.object(QSystemTrayIcon, 'isSystemTrayAvailable', return_value=True), \
             patch.object(QSystemTrayIcon, 'show'), \
             patch.object(QSystemTrayIcon, 'showMessage') as notify, \
             patch.object(QApplication, 'quit') as quit_app:
            window.background = BackgroundController(window)
            window.batch = FakeBatch(); window.batch.isRunning = lambda: False
            window.island.track(window.batch, 'PNG', 1)
            window.outputs = ['out.png']; window.batch_errors = []
            window.background.finished()
            notify.assert_not_called()
            # Conversions the island did not show still notify from the tray.
            window.batch = FakeBatch(); window.batch.isRunning = lambda: False
            window.background.finished()
            notify.assert_called_once()
            window.island.track(FakeBatch(), 'PNG', 1)
            window.island.retract_timer.start(RETRACT_MS)
            window.request_quit()
            quit_app.assert_called_once()
            self.assertFalse(window.island.isVisible())
            self.assertFalse(window.island.retract_timer.isActive())
        self.app.setQuitOnLastWindowClosed(previous)
        window.island.close()


if __name__ == '__main__':
    unittest.main()
