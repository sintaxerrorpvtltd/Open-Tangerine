"""One disposable worker per job; cancellation kills the entire process tree."""
import json, os, signal, subprocess, sys, tempfile, time
from pathlib import Path

class Cancelled(Exception): pass

class WorkerError(ValueError):
    def __init__(self, message, outputs=()):
        super().__init__(message)
        self.outputs = list(outputs)


def worker_command():
    if getattr(sys, 'frozen', False):
        return [sys.executable, '--worker']
    return [sys.executable, str(Path(__file__).with_name('app.py')), '--worker']


def stop(proc):
    if os.name == 'nt':
        if proc.poll() is None:
            taskkill = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32' / 'taskkill.exe'
            try:
                subprocess.run([str(taskkill), '/PID', str(proc.pid), '/T', '/F'],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=5,
                               creationflags=subprocess.CREATE_NO_WINDOW)
            except (OSError, subprocess.TimeoutExpired):
                pass  # Still kill and reap the worker if taskkill is unavailable.
    else:
        # A crashed worker may have left a child in its dedicated process group.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if proc.poll() is None:
        proc.kill()
    proc.wait(timeout=10)


def run_job(job, cancel=None, timeout=180, command=None):
    if cancel is not None and cancel.is_set():
        raise Cancelled('Cancelled; completed outputs are kept.')
    payload = json.dumps(job).encode()
    if len(payload) > 65536:
        raise ValueError('Job request too large.')
    # A file-backed request cannot block while writing to an unresponsive worker's pipe.
    with tempfile.TemporaryFile() as request, tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        request.write(payload)
        request.seek(0)
        kwargs = {'start_new_session': True} if os.name != 'nt' else {'creationflags': subprocess.CREATE_NO_WINDOW}
        proc = subprocess.Popen(command or worker_command(), stdin=request, stdout=out, stderr=err, **kwargs)
        start = time.monotonic()
        def check_diagnostics():
            if os.fstat(out.fileno()).st_size > 131072 or os.fstat(err.fileno()).st_size > 131072:
                raise ValueError('Worker exceeded diagnostic limits.')
        try:
            while proc.poll() is None:
                if cancel is not None and cancel.is_set():
                    raise Cancelled('Cancelled; completed outputs are kept.')
                if time.monotonic() - start > timeout:
                    raise TimeoutError('Conversion timed out; try a smaller file.')
                check_diagnostics()
                time.sleep(.04)
            check_diagnostics()
            out.seek(0)
            result = json.loads(out.read(131073))
            if not isinstance(result, dict) or type(result.get('ok')) is not bool:
                raise ValueError('Conversion worker returned an invalid response.')
            outputs = result.get('outputs', [])
            if not isinstance(outputs, list) or any(not isinstance(p, str) or not p for p in outputs):
                raise ValueError('Conversion worker returned invalid output paths.')
            if not result['ok']:
                raise WorkerError(str(result.get('error') or 'Conversion failed.'), outputs)
            if proc.returncode != 0:
                raise ValueError('Conversion worker exited unexpectedly.')
            if not outputs:
                raise ValueError('Conversion worker returned no output files.')
            return outputs
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            raise ValueError('Conversion worker failed. The file may be unsupported or exceed resource limits.') from e
        finally:
            stop(proc)
