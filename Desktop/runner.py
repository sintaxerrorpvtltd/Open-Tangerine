"""One disposable worker per job; cancellation kills the entire process tree.
On Windows each worker also runs in a job object that caps its memory (winjob.py); Linux workers limit themselves (engine.worker_main)."""
import json, os, signal, subprocess, sys, tempfile, time
from pathlib import Path
from contextlib import ExitStack
from engine import MEMORY_MESSAGE, output_folder
import winjob

# Committed memory allowed to one worker and everything it starts. It leaves ample room over the heaviest legitimate jobs (40-megapixel images).
WORKER_MEMORY=3*1024**3

class Cancelled(Exception): pass

def worker_command():
    if getattr(sys,'frozen',False):
        executable=Path(sys.executable)
        if sys.platform=='win32':
            executable=executable.with_name('OpenTangerineWorker.exe')
            if not executable.is_file():
                raise FileNotFoundError('Conversion worker missing. Extract the entire Windows ZIP before launching the app.')
        return [str(executable),'--worker']
    return [sys.executable,str(Path(__file__).with_name('app.py')),'--worker']

def stop(proc):
    if proc.poll() is not None: return
    if os.name=='nt':
        taskkill=Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32'/'taskkill.exe'
        try:
            if not taskkill.is_absolute():raise OSError('Invalid Windows system directory')
            subprocess.run([str(taskkill),'/PID',str(proc.pid),'/T','/F'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
        except (OSError,subprocess.TimeoutExpired):pass
    else:
        try: os.killpg(proc.pid,signal.SIGKILL)
        except ProcessLookupError: pass
    try:
        if proc.poll() is None:proc.kill()
        proc.wait(timeout=10)
    except (OSError,subprocess.TimeoutExpired):pass

def run_job(job,cancel=None,timeout=180,command=None,memory_limit=WORKER_MEMORY,info=None):
    """Run one job in a disposable worker. `info`, if given, receives `capped` (was the memory limit applied) and `peak_memory` (bytes, Windows only)."""
    with ExitStack() as cleanup:
        job=dict(job)
        # Parent-owned staging: removed here even when the worker is killed mid-job.
        if command is None and job.get('paths'):
            folder=output_folder(job.get('output') or Path(job['paths'][0]).parent)
            job['output']=str(folder)
            job['_work_root']=cleanup.enter_context(tempfile.TemporaryDirectory(prefix='.opentangerine-job-',dir=folder))
        return _run_job(job,cancel,timeout,command,memory_limit,info)

def _run_job(job,cancel,timeout,command,memory_limit,info):
    payload=json.dumps(job).encode()
    if len(payload)>65536: raise ValueError('Job request too large.')
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        kwargs={'start_new_session':True} if os.name!='nt' else {'creationflags':subprocess.CREATE_NO_WINDOW}
        proc=subprocess.Popen(command or worker_command(),stdin=subprocess.PIPE,stdout=out,stderr=err,**kwargs)
        cap=winjob.MemoryJob.create(memory_limit)
        # The worker only starts reading its request (and so only starts anything of its own) after the payload is written below, so it is in the job first.
        capped=bool(cap and cap.add(proc));start=time.monotonic()
        try:
            proc.stdin.write(payload);proc.stdin.close()
            while proc.poll() is None:
                if cancel is not None and cancel.is_set(): raise Cancelled('Cancelled; completed outputs are kept.')
                if time.monotonic()-start>timeout: raise TimeoutError('Conversion timed out; try a smaller file.')
                if os.fstat(out.fileno()).st_size>131072 or os.fstat(err.fileno()).st_size>131072: raise ValueError('Worker exceeded diagnostic limits.')
                time.sleep(.04)
            out.seek(0)
            if proc.returncode<0:
                label={getattr(signal,'SIGXCPU',-100):'CPU time limit',getattr(signal,'SIGXFSZ',-101):'output size limit',signal.SIGKILL:'forced termination (possibly memory pressure or an external kill)'}.get(-proc.returncode,'signal '+str(-proc.returncode))
                raise ValueError('Conversion worker stopped: '+label+'.')
            result=json.loads(out.read(131073))
            if not result.get('ok'):
                if capped and cap.exceeded(): raise ValueError(MEMORY_MESSAGE)
                raise ValueError(result.get('error','Conversion failed.'))
            if proc.returncode!=0: raise ValueError('Conversion worker exited unexpectedly.')
            return result['outputs']
        except (json.JSONDecodeError,UnicodeDecodeError) as e:
            if capped and cap.exceeded(): raise ValueError(MEMORY_MESSAGE) from e
            raise ValueError('Conversion worker failed. The file may be unsupported or exceed resource limits.') from e
        finally:
            stop(proc)
            if info is not None: info.update(capped=capped,peak_memory=cap.peak() if cap else 0)
            if cap: cap.close()
