"""Frozen Windows GUI must launch the console worker, never itself."""
import sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import runner

class WorkerEntryTests(unittest.TestCase):
    def test_windows_frozen_worker_is_a_separate_executable(self):
        with tempfile.TemporaryDirectory() as folder:
            gui=Path(folder)/'OpenTangerine.exe'
            worker=gui.with_name('OpenTangerineWorker.exe');worker.write_bytes(b'fixture')
            with patch.object(sys,'frozen',True,create=True), patch.object(sys,'platform','win32'), patch.object(sys,'executable',str(gui)):
                self.assertEqual(runner.worker_command(),[str(worker),'--worker'])
                worker.unlink()
                with self.assertRaisesRegex(FileNotFoundError,'Extract the entire Windows ZIP'):
                    runner.worker_command()

    def test_linux_frozen_worker_stays_in_same_binary(self):
        with patch.object(sys,'frozen',True,create=True), patch.object(sys,'platform','linux'):
            self.assertEqual(runner.worker_command(),[sys.executable,'--worker'])

if __name__=='__main__':unittest.main()
