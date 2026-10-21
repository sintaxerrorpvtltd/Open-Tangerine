import os, sys, tempfile, threading, time, unittest
from pathlib import Path
from unittest.mock import patch
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PySide6.QtCore import QMimeData, QPointF, Qt, QUrl
from PySide6.QtGui import QDropEvent
from PySide6.QtWidgets import QApplication
from app import Window
from runner import Cancelled, WorkerError
from engine import convert
from PIL import Image
from pypdf import PdfReader, PdfWriter


class UITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.window = Window()

    def tearDown(self):
        if self.window.busy:
            self.window.cancel_batch()
            self.wait_batch()
        self.window.close()
        self.app.processEvents()
        self.tmp.cleanup()

    def image(self, name='image.png'):
        p = self.root / name
        Image.new('RGB', (16, 12), 'orange').save(p)
        return str(p)

    def pdf(self, name):
        p = self.root / name
        writer = PdfWriter()
        writer.add_blank_page(100, 100)
        with p.open('wb') as f:
            writer.write(f)
        return str(p)

    def wait_for(self, predicate):
        deadline = time.monotonic() + 20
        while not predicate():
            self.app.processEvents()
            if time.monotonic() > deadline:
                self.fail('UI did not reach the expected state')
            time.sleep(.01)
        self.app.processEvents()

    def wait_batch(self):
        self.wait_for(lambda: not self.window.busy)

    def test_queue_deduplicates_and_rejects_directory(self):
        self.window.add_paths([self.image(), self.image(), str(self.root)])
        self.assertEqual(len(self.window.paths), 1)
        self.window.clear_files()
        self.assertEqual(self.window.list.count(), 0)

    def test_window_and_options(self):
        w = self.window
        w.show(); self.app.processEvents()
        w.target.setCurrentText('Merge PDFs')
        self.assertFalse(w.width.isEnabled())
        w.target.setCurrentText('JPEG')
        self.assertTrue(w.width.isEnabled())

    def test_rerun_resets_rows_and_cancel_marks_every_pending_file(self):
        w = self.window
        w.add_paths([self.image('first.png'), self.image('last.png')])
        w.target.setCurrentText('JPEG'); w.start(); self.wait_batch()
        self.assertEqual(w.states, ['Done', 'Done'])
        previous = {p: Path(p).read_bytes() for p in w.outputs}
        entered = threading.Event()
        def blocked(job, cancel):
            entered.set()
            if not cancel.wait(10): raise TimeoutError('Test worker timed out')
            raise Cancelled()
        with patch('app.run_job', side_effect=blocked):
            w.start()
            self.assertEqual(w.states, ['Queued', 'Queued'])
            self.assertNotIn('Done', w.list.item(0).text())
            self.assertNotIn('.jpg', w.list.item(0).toolTip())
            self.wait_for(entered.is_set)
            batch = w.batch
            w.start(); w.clear_files(); w.add_paths([self.image('ignored.png')])
            self.assertIs(w.batch, batch)
            self.assertEqual(len(w.paths), 2)
            self.assertFalse(w.width.isEnabled())
            self.assertFalse(w.rotate.isEnabled())
            self.assertFalse(w.ffmpeg.isEnabled())
            self.assertFalse(w.list.acceptDrops())
            w.cancel_batch(); self.wait_batch()
        self.assertEqual(w.states, ['Cancelled', 'Cancelled'])
        self.assertEqual(w.outputs, [])
        self.assertIn('2 cancelled', w.status.text())
        self.assertTrue(all(Path(p).read_bytes() == data for p, data in previous.items()))
        self.assertTrue(w.width.isEnabled())
        self.assertTrue(w.ffmpeg.isEnabled())
        self.assertTrue(w.list.acceptDrops())

    def test_cancel_keeps_completed_outputs(self):
        w = self.window
        first = self.image('first.png')
        w.add_paths([first, self.image('second.png'), self.image('third.png')])
        w.target.setCurrentText('JPEG')
        entered = threading.Event()
        def partial(job, cancel):
            if job['paths'] == [first]: return convert(job)
            entered.set()
            if not cancel.wait(10): raise TimeoutError('Test worker timed out')
            raise Cancelled()
        with patch('app.run_job', side_effect=partial):
            w.start(); self.wait_for(entered.is_set)
            w.cancel_batch(); self.wait_batch()
        self.assertEqual(w.states, ['Done', 'Cancelled', 'Cancelled'])
        self.assertEqual(len(w.outputs), 1)
        self.assertTrue(Path(w.outputs[0]).is_file())
        self.assertTrue(w.open.isEnabled())
        self.assertLess(w.progress.value(), 100)

    def test_merge_updates_all_rows_without_duplicating_outputs(self):
        w = self.window
        w.add_paths([self.pdf('one.pdf'), self.pdf('two.pdf')])
        w.target.setCurrentText('Merge PDFs'); w.start(); self.wait_batch()
        self.assertEqual(w.states, ['Done', 'Done'])
        self.assertEqual(len(w.outputs), 1)
        self.assertEqual(len(PdfReader(w.outputs[0]).pages), 2)
        for i in range(2): self.assertEqual(w.list.item(i).toolTip(), w.outputs[0])

    def test_merge_failure_updates_all_rows(self):
        w = self.window
        broken = self.root / 'broken.pdf'; broken.write_bytes(b'not a PDF')
        w.add_paths([self.pdf('one.pdf'), str(broken)])
        w.target.setCurrentText('Merge PDFs'); w.start(); self.wait_batch()
        self.assertEqual(w.states, ['Failed', 'Failed'])
        self.assertEqual(w.outputs, [])
        self.assertIn('2 failed', w.status.text())

    def test_corrupt_file_does_not_stop_later_files(self):
        w = self.window
        broken = self.root / 'broken.png'; broken.write_bytes(b'not an image')
        w.add_paths([self.image('first.png'), str(broken), self.image('last.png')])
        w.target.setCurrentText('JPEG'); w.start(); self.wait_batch()
        self.assertEqual(w.states, ['Done', 'Failed', 'Done'])
        self.assertEqual(len(w.outputs), 2)
        self.assertIn('1 failed', w.status.text())
        self.assertEqual(w.progress.value(), 100)

    def test_partial_failure_exposes_kept_outputs(self):
        w = self.window
        w.add_paths([self.pdf('one.pdf')]); w.target.setCurrentText('Split PDF')
        kept = self.pdf('kept-page.pdf')
        with patch('app.run_job', side_effect=WorkerError('Disk full; completed pages kept.', [kept])):
            w.start(); self.wait_batch()
        self.assertEqual(w.states, ['Failed'])
        self.assertEqual(w.outputs, [kept])
        self.assertTrue(w.open.isEnabled())
        self.assertEqual(w.list.item(0).toolTip(), kept)

    def test_output_folder_can_be_reset(self):
        w = self.window
        with patch('app.QFileDialog.getExistingDirectory', return_value=str(self.root)):
            w.choose_folder()
        self.assertEqual(w.output, str(self.root))
        self.assertFalse(w.reset_folder.isHidden())
        w.use_original_folders()
        self.assertEqual(w.output, '')
        self.assertTrue(w.reset_folder.isHidden())

    def test_drop_accepts_local_files_and_rejects_remote_urls(self):
        w = self.window
        for url, expected in [(QUrl('https://example.invalid/file.png'), False), (QUrl.fromLocalFile(self.image()), True)]:
            mime = QMimeData(); mime.setUrls([url])
            event = QDropEvent(QPointF(10, 10), Qt.CopyAction, mime, Qt.LeftButton, Qt.NoModifier)
            w.list.dropEvent(event)
            self.assertEqual(event.isAccepted(), expected)
        self.assertEqual(len(w.paths), 1)

    def test_close_waits_for_worker_cancellation(self):
        w = self.window; w.show(); w.add_paths([self.image()])
        entered = threading.Event()
        def blocked(job, cancel):
            entered.set()
            if not cancel.wait(10): raise TimeoutError('Test worker timed out')
            raise Cancelled()
        with patch('app.run_job', side_effect=blocked):
            w.start(); self.wait_for(entered.is_set); w.close()
            self.assertTrue(w.batch.cancel.is_set())
            self.wait_for(lambda: not w.isVisible())
        self.assertFalse(w.busy)

    def test_radial_wheel_and_quick_convert_saves_beside_original(self):
        w = self.window
        img1 = self.image('wheel-first.png')
        img2 = self.image('wheel-second.png')
        w.show_radial_wheel([img1, img2])
        self.assertIsNotNone(w.active_wheel)
        self.assertEqual(len(w.active_wheel.paths), 2)
        # Trigger quick conversion to JPEG
        w.active_wheel._trigger_selection('JPEG')
        self.assertIsNone(w.active_wheel)
        self.wait_batch()
        self.assertEqual(len(w.outputs), 2)
        # Verify outputs are saved beside original files
        for output in w.outputs:
            p = Path(output)
            self.assertTrue(p.is_file())
            self.assertEqual(p.parent, self.root)
            self.assertEqual(p.suffix.lower(), '.jpg')

if __name__ == '__main__': unittest.main()
