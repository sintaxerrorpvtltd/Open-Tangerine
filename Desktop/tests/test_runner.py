import json, os, subprocess, sys, tempfile, threading, time, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from runner import run_job, stop, Cancelled, WorkerError


class RunnerTests(unittest.TestCase):
    def command(self, source):
        return [sys.executable, '-c', source]

    def test_cancelled_request_never_starts_worker(self):
        cancel = threading.Event(); cancel.set()
        with patch('runner.subprocess.Popen') as start:
            with self.assertRaises(Cancelled): run_job({}, cancel=cancel)
        start.assert_not_called()

    def test_timeout_applies_when_worker_does_not_read_request(self):
        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            run_job({'payload': 'x' * 60000}, timeout=.2, command=self.command('import time; time.sleep(30)'))
        self.assertLess(time.monotonic() - started, 12)

    def test_crashed_or_invalid_workers_report_errors(self):
        for source in ['raise SystemExit(2)', 'print("not JSON")', 'print("[]")', 'print(\'{"ok": "yes"}\')', 'print(\'{"ok": true, "outputs": "bad"}\')', 'print(\'{"ok": true, "outputs": []}\')']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                run_job({}, command=self.command(source))

    def test_fast_worker_cannot_bypass_diagnostic_limit(self):
        for stream in ['stdout', 'stderr']:
            source = f'import sys; sys.{stream}.write("x" * 140000); sys.{stream}.flush()'
            with self.subTest(stream=stream), self.assertRaisesRegex(ValueError, 'diagnostic'):
                run_job({}, command=self.command(source))

    def test_partial_outputs_survive_worker_error(self):
        data = {'ok': False, 'error': 'Disk full', 'outputs': ['kept-page.pdf']}
        with self.assertRaises(WorkerError) as error:
            run_job({}, command=self.command('print(' + repr(json.dumps(data)) + ')'))
        self.assertEqual(error.exception.outputs, ['kept-page.pdf'])

    @unittest.skipUnless(os.name == 'nt', 'Windows taskkill fallback')
    def test_taskkill_failure_still_reaps_worker(self):
        proc = subprocess.Popen(self.command('import time; time.sleep(30)'), creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            with patch('runner.subprocess.run', side_effect=subprocess.TimeoutExpired('taskkill', 5)):
                stop(proc)
            self.assertIsNotNone(proc.returncode)
        finally:
            if proc.poll() is None: proc.kill(); proc.wait()

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux process-group cleanup')
    def test_crashed_worker_does_not_leave_child_process(self):
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / 'child-survived'
            child = 'import time; from pathlib import Path; time.sleep(1.5); Path(' + repr(str(marker)) + ').write_text("orphan")'
            parent = 'import subprocess, sys; subprocess.Popen([sys.executable, "-c", ' + repr(child) + ']); raise SystemExit(1)'
            with self.assertRaises(ValueError): run_job({}, command=self.command(parent))
            time.sleep(2)
            self.assertFalse(marker.exists(), 'An orphaned child outlived the crashed worker')

if __name__ == '__main__': unittest.main()
