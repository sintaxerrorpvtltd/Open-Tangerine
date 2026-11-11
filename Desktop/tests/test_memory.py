"""Worker memory cap: a Windows job object per worker (winjob.py, runner.run_job) and the shared out-of-memory message."""
import contextlib, io, json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import engine, runner, winjob
from engine import MEMORY_MESSAGE
from PIL import Image

WIN = os.name == 'nt'
OK = '{"ok":true,"outputs":[]}'
MiB = 1024 * 1024

def child(code): return [sys.executable, '-c', 'import sys;sys.stdin.read();' + code]     # waits for the request, as the real worker does

class WorkerMessage(unittest.TestCase):
    def run_worker(self, error):
        stdin = io.TextIOWrapper(io.BytesIO(b'{}'));out = io.StringIO()
        with mock.patch.object(engine, 'convert', side_effect=error), mock.patch.object(sys, 'stdin', stdin), contextlib.redirect_stdout(out): code = engine.worker_main()
        return code, json.loads(out.getvalue())
    def test_memory_error_becomes_a_clear_message(self):
        code, result = self.run_worker(MemoryError());self.assertEqual(code, 1);self.assertEqual(result, {'ok': False, 'error': MEMORY_MESSAGE})
    def test_other_errors_keep_their_text(self):
        code, result = self.run_worker(engine.ConversionError('Bad file.'));self.assertEqual(result['error'], 'Bad file.')

class NotWindows(unittest.TestCase):
    def test_job_is_only_created_on_windows(self):
        self.assertIsNone(winjob.MemoryJob.create(0));self.assertEqual(winjob.MemoryJob.create(1 << 30) is not None, WIN)

@unittest.skipUnless(WIN, 'Windows job objects')
class Cap(unittest.TestCase):
    def test_runaway_allocation_is_stopped_with_a_clear_message(self):
        info = {}
        with self.assertRaisesRegex(ValueError, 'more memory than a conversion is allowed'): runner.run_job({}, command=child(f'b=bytearray({700 * MiB});print({OK!r})'), memory_limit=300 * MiB, info=info)
        self.assertTrue(info['capped'])
    def test_same_allocation_is_fine_under_a_bigger_limit_and_the_peak_is_reported(self):
        info = {};self.assertEqual(runner.run_job({}, command=child(f'b=bytearray({200 * MiB});print({OK!r})'), memory_limit=1024 * MiB, info=info), [])
        self.assertTrue(info['capped']);self.assertGreater(info['peak_memory'], 180 * MiB);self.assertLess(info['peak_memory'], 600 * MiB)
    def test_no_limit_means_no_job(self):
        info = {};runner.run_job({}, command=child(f'print({OK!r})'), memory_limit=0, info=info);self.assertEqual(info, {'capped': False, 'peak_memory': 0})
    def test_if_the_job_cannot_be_created_the_job_still_runs(self):
        info = {}
        with mock.patch.object(winjob.MemoryJob, 'create', return_value=None): self.assertEqual(runner.run_job({}, command=child(f'print({OK!r})'), info=info), [])
        self.assertFalse(info['capped'])
    def test_default_limit_is_three_gib_and_leaves_room_over_the_measured_peak(self):
        self.assertEqual(runner.WORKER_MEMORY, 3 * 1024 ** 3)

    def alive(self, pid):
        import ctypes
        k = ctypes.windll.kernel32;k.OpenProcess.restype = ctypes.c_void_p;h = k.OpenProcess(0x00100000, False, pid)        # SYNCHRONIZE
        if not h: return False
        try: return k.WaitForSingleObject(ctypes.c_void_p(h), 0) == 0x102                                                    # WAIT_TIMEOUT: still running
        finally: k.CloseHandle(ctypes.c_void_p(h))
    def test_closing_the_job_ends_everything_it_started(self):
        spawn = "import subprocess,sys,time;c=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);print(c.pid,flush=True);time.sleep(60)"
        job = winjob.MemoryJob.create(1 << 30);parent = subprocess.Popen([sys.executable, '-c', spawn], stdout=subprocess.PIPE, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            self.assertTrue(job.add(parent));grandchild = int(parent.stdout.readline());self.assertTrue(self.alive(grandchild));self.assertTrue(self.alive(parent.pid))
            job.close()
            self.assertEqual(parent.wait(timeout=10) is not None, True);import time;end = time.monotonic() + 5
            while self.alive(grandchild) and time.monotonic() < end: time.sleep(.05)
            self.assertFalse(self.alive(grandchild))
        finally:
            job.close();parent.stdout.close()
            if parent.poll() is None: parent.kill()
    # --- helpers for child cleanup ---
    def gone(self, pid, seconds=5):
        import time;end = time.monotonic() + seconds
        while self.alive(pid) and time.monotonic() < end: time.sleep(.05)
        return not self.alive(pid)
    def tree_writing_pid(self, pidfile):
        """A fake worker that starts a long-running grandchild and writes its PID to a file (run_job captures stdout)."""
        code = "import subprocess,sys,time;sys.stdin.read();c=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);open(sys.argv[1],'w').write(str(c.pid));time.sleep(60)"
        return [sys.executable, '-c', code, str(pidfile)]
    def wait_for_pid(self, pidfile, seconds=10):
        import time;end = time.monotonic() + seconds
        while time.monotonic() < end:
            try: return int(pidfile.read_text())
            except (OSError, ValueError): time.sleep(.05)
        self.fail('fake worker never started its child')

    # --- nested-job failure ---
    def test_if_windows_refuses_to_add_the_worker_it_runs_uncapped_and_the_job_is_closed(self):
        closed, real_close = [], winjob.MemoryJob.close
        def close(job): closed.append(True);real_close(job)
        info = {}
        with mock.patch.object(winjob.MemoryJob, 'add', return_value=False), mock.patch.object(winjob.MemoryJob, 'close', close):
            self.assertEqual(runner.run_job({}, command=child(f'print({OK!r})'), info=info), [])
        self.assertFalse(info['capped']);self.assertEqual(closed, [True])
    def test_if_the_worker_cannot_be_opened_add_returns_false(self):
        job = winjob.MemoryJob.create(1 << 30);proc = subprocess.Popen(child(f'print({OK!r})'), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            with mock.patch.object(winjob._k, 'OpenProcess', return_value=None): self.assertFalse(job.add(proc))
        finally: proc.communicate(b'{}', timeout=10);job.close()
    def test_a_worker_started_from_inside_an_outer_job_is_still_capped(self):
        desktop = str(Path(runner.__file__).resolve().parent)
        script = f"import sys,json;cmd=json.loads(sys.stdin.read());sys.path.insert(0,{desktop!r});import runner;info={{}};runner.run_job({{}},command=cmd,info=info);print(json.dumps(info))"
        outer = winjob.MemoryJob.create(2 << 30)
        proc = subprocess.Popen([sys.executable, '-c', script], stdin=subprocess.PIPE, stdout=subprocess.PIPE, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            self.assertTrue(outer.add(proc))
            out, _ = proc.communicate(json.dumps(child(f'print({OK!r})')).encode(), timeout=60)
            self.assertTrue(json.loads(out.splitlines()[-1])['capped'])
        finally: outer.close()

    # --- cancellation and the deadline end the worker and its children ---
    def test_cancel_ends_the_worker_and_its_child(self):
        import threading
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = Path(tmp) / 'pid';cancel = threading.Event();found = {}
            def watch(): found['pid'] = self.wait_for_pid(pidfile);cancel.set()
            t = threading.Thread(target=watch);t.start()
            with self.assertRaises(runner.Cancelled): runner.run_job({}, cancel=cancel, command=self.tree_writing_pid(pidfile))
            t.join();self.assertTrue(self.gone(found['pid']))
    def test_deadline_ends_the_worker_and_its_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = Path(tmp) / 'pid'
            with self.assertRaises(TimeoutError): runner.run_job({}, timeout=3, command=self.tree_writing_pid(pidfile))
            self.assertTrue(self.gone(self.wait_for_pid(pidfile, 1)))

class RealWorker(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.root = Path(self.tmp.name).resolve();self.src = self.root / 'wide.png';Image.new('RGB', (5000, 4000), (200, 120, 40)).save(self.src)    # 20 MP, tiny file
    def tearDown(self): self.tmp.cleanup()
    def job(self, target='JPEG'): return {'paths': [str(self.src)], 'target': target, 'output': str(self.root)}
    @unittest.skipUnless(WIN, 'Windows job objects')
    def test_a_real_conversion_over_the_limit_reports_the_memory_message(self):
        with self.assertRaisesRegex(ValueError, 'more memory than a conversion is allowed'): runner.run_job(self.job(), memory_limit=180 * MiB)
        self.assertEqual([p.name for p in self.root.iterdir()], ['wide.png'])               # nothing half-written is left behind
    def test_a_real_conversion_under_the_default_limit_works(self):
        info = {};out = runner.run_job(self.job(), info=info);self.assertTrue(Path(out[0]).is_file())
        if WIN: self.assertTrue(info['capped']);self.assertLess(info['peak_memory'], runner.WORKER_MEMORY // 3)

if __name__ == '__main__': unittest.main()
