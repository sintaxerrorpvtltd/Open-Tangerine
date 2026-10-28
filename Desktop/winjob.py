"""Windows Job Object that caps the memory of one worker and everything it starts (FFmpeg, Tesseract, LibreOffice).

Linux workers get RLIMIT_AS inside the worker (engine.worker_main). Windows has no per-process equivalent, so the parent puts the
worker in a job object with a limit on the total committed memory of the job. When the limit is reached allocations fail (Python raises
MemoryError) instead of the machine running out of memory. The job also has KILL_ON_JOB_CLOSE: if the app exits or crashes, every
process still in the job is ended, so no orphaned FFmpeg keeps running. Not an OS security sandbox: it limits memory only."""
from __future__ import annotations
import os

JOB_OBJECT_LIMIT_JOB_MEMORY = 0x00000200
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
EXTENDED_LIMIT_INFORMATION = 9
LIMIT_VIOLATION_INFORMATION = 13
PROCESS_SET_QUOTA, PROCESS_TERMINATE = 0x0100, 0x0001

if os.name == 'nt':
    import ctypes, ctypes.wintypes as wt
    class _Basic(ctypes.Structure):
        _fields_ = [('PerProcessUserTimeLimit', ctypes.c_int64), ('PerJobUserTimeLimit', ctypes.c_int64), ('LimitFlags', wt.DWORD), ('MinimumWorkingSetSize', ctypes.c_size_t),
                    ('MaximumWorkingSetSize', ctypes.c_size_t), ('ActiveProcessLimit', wt.DWORD), ('Affinity', ctypes.c_size_t), ('PriorityClass', wt.DWORD), ('SchedulingClass', wt.DWORD)]
    class _IO(ctypes.Structure): _fields_ = [(n, ctypes.c_uint64) for n in ('Read', 'Write', 'Other', 'ReadBytes', 'WriteBytes', 'OtherBytes')]
    class _Extended(ctypes.Structure):
        _fields_ = [('Basic', _Basic), ('Io', _IO), ('ProcessMemoryLimit', ctypes.c_size_t), ('JobMemoryLimit', ctypes.c_size_t), ('PeakProcessMemoryUsed', ctypes.c_size_t), ('PeakJobMemoryUsed', ctypes.c_size_t)]
    class _Violation(ctypes.Structure):
        _fields_ = [('LimitFlags', wt.DWORD), ('ViolationLimitFlags', wt.DWORD), ('IoReadBytes', ctypes.c_uint64), ('IoReadBytesLimit', ctypes.c_uint64), ('IoWriteBytes', ctypes.c_uint64), ('IoWriteBytesLimit', ctypes.c_uint64),
                    ('PerJobUserTime', ctypes.c_int64), ('PerJobUserTimeLimit', ctypes.c_int64), ('JobMemory', ctypes.c_uint64), ('JobMemoryLimit', ctypes.c_uint64), ('RateControlTolerance', wt.DWORD),
                    ('RateControlToleranceLimit', wt.DWORD)]
    _k = ctypes.WinDLL('kernel32', use_last_error=True)
    _k.CreateJobObjectW.restype = wt.HANDLE;_k.CreateJobObjectW.argtypes = [ctypes.c_void_p, wt.LPCWSTR]
    _k.SetInformationJobObject.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD];_k.SetInformationJobObject.restype = wt.BOOL
    _k.QueryInformationJobObject.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD, ctypes.c_void_p];_k.QueryInformationJobObject.restype = wt.BOOL
    _k.AssignProcessToJobObject.argtypes = [wt.HANDLE, wt.HANDLE];_k.AssignProcessToJobObject.restype = wt.BOOL
    _k.OpenProcess.restype = wt.HANDLE;_k.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
    _k.CloseHandle.argtypes = [wt.HANDLE];_k.CloseHandle.restype = wt.BOOL

class MemoryJob:
    """One job object per worker. Use create(); it returns None where the limit cannot be applied (not Windows, or the call failed)."""
    def __init__(self, handle, limit): self.handle = handle;self.limit = limit

    @classmethod
    def create(cls, limit):
        if os.name != 'nt' or not limit: return None
        handle = _k.CreateJobObjectW(None, None)
        if not handle: return None
        info = _Extended();info.Basic.LimitFlags = JOB_OBJECT_LIMIT_JOB_MEMORY | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;info.JobMemoryLimit = int(limit)
        if not _k.SetInformationJobObject(handle, EXTENDED_LIMIT_INFORMATION, ctypes.byref(info), ctypes.sizeof(info)): _k.CloseHandle(handle);return None
        return cls(handle, int(limit))

    def add(self, proc):
        """Put a just-started worker in the job. False if Windows refuses (the worker then runs without the cap)."""
        if not self.handle: return False
        process = _k.OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, False, proc.pid)
        if not process: return False
        try: return bool(_k.AssignProcessToJobObject(self.handle, process))
        finally: _k.CloseHandle(process)

    def peak(self):
        """Highest committed memory (bytes) the job reached, or 0 when unknown."""
        if not self.handle: return 0
        info = _Extended()
        return int(info.PeakJobMemoryUsed) if _k.QueryInformationJobObject(self.handle, EXTENDED_LIMIT_INFORMATION, ctypes.byref(info), ctypes.sizeof(info), None) else 0

    def exceeded(self):
        """True if something in the job was refused memory because of the limit. Windows records a refused request in the job's peak
        (a request for 700 MiB against a 300 MiB limit shows a peak of about 700 MiB), so a peak above the limit means a refusal."""
        if not self.handle: return False
        if self.peak() > self.limit: return True
        info = _Violation()
        if not _k.QueryInformationJobObject(self.handle, LIMIT_VIOLATION_INFORMATION, ctypes.byref(info), ctypes.sizeof(info), None): return False
        return bool(info.ViolationLimitFlags & JOB_OBJECT_LIMIT_JOB_MEMORY)

    def close(self):
        """Close the handle; with KILL_ON_JOB_CLOSE this ends anything still running in the job."""
        handle, self.handle = self.handle, None
        if handle: _k.CloseHandle(handle)
