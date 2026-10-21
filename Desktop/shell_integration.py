"""Local shell adapters and global selection monitor (GPL-3.0-only)."""
import base64
import ctypes
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from PySide6.QtCore import QObject, Signal, QTimer, QPoint
from PySide6.QtGui import QCursor


class ShiftHold:
    """Debounce a hold or drag gesture once per press; never consume the user's Shift key."""
    def __init__(self, delay=0.35, drag_threshold=8):
        self.delay = delay
        self.drag_threshold = drag_threshold
        self.context = None
        self.since = 0
        self.fired = False
        self.drag_origin = None

    def update(self, shift_down, lbutton_down, context, now, mouse_pos=None, blocked=False):
        if not shift_down:
            self.context = None
            self.fired = False
            self.drag_origin = None
            return None
        if blocked or not context:
            self.context = None
            self.since = now
            self.drag_origin = None
            return None
        if self.fired:
            return None

        if context != self.context:
            self.context = context
            self.since = now
            self.drag_origin = mouse_pos if lbutton_down else None

        # Mode A: Drag + Shift (left mouse button is dragging files with Shift held)
        if lbutton_down and mouse_pos:
            if self.drag_origin is None:
                self.drag_origin = mouse_pos
            elif math.hypot(mouse_pos[0] - self.drag_origin[0], mouse_pos[1] - self.drag_origin[1]) >= self.drag_threshold:
                self.fired = True
                return (context, True)

        # Mode B: Select + Shift (Shift held on selection in Explorer or Desktop)
        if now - self.since >= self.delay:
            self.fired = True
            return (context, False)

        return None


# COM and Win32 structures for Windows
if os.name == 'nt':
    from ctypes import wintypes, HRESULT, POINTER, c_void_p, c_int, c_long, byref, cast, Structure

    ole32 = ctypes.oledll.ole32
    oleaut32 = ctypes.oledll.oleaut32

    class GUID(Structure):
        _fields_ = [
            ("Data1", wintypes.DWORD),
            ("Data2", wintypes.WORD),
            ("Data3", wintypes.WORD),
            ("Data4", wintypes.BYTE * 8)
        ]
        @classmethod
        def from_str(cls, s):
            g = cls()
            ole32.CLSIDFromString(ctypes.c_wchar_p(s), byref(g))
            return g

    CLSID_ShellWindows = GUID.from_str("{9BA05972-F6A8-11CF-A442-00A0C90A8F39}")
    IID_IShellWindows = GUID.from_str("{85CB6900-4D95-11CF-960C-0080C7F4EE85}")
    IID_NULL = GUID()

    class VARIANT(Structure):
        class _U(ctypes.Union):
            class _RECORD(Structure):
                _fields_ = [("pvRecord", c_void_p), ("pRecInfo", c_void_p)]
            _fields_ = [
                ("lVal", c_long),
                ("bVal", wintypes.BYTE),
                ("iVal", wintypes.SHORT),
                ("fltVal", ctypes.c_float),
                ("dblVal", ctypes.c_double),
                ("boolVal", wintypes.VARIANT_BOOL),
                ("scode", wintypes.LONG),
                ("bstrVal", ctypes.c_wchar_p),
                ("punkVal", c_void_p),
                ("pdispVal", c_void_p),
                ("record", _RECORD),
            ]
        _fields_ = [
            ("vt", wintypes.USHORT),
            ("wReserved1", wintypes.WORD),
            ("wReserved2", wintypes.WORD),
            ("wReserved3", wintypes.WORD),
            ("_u", _U)
        ]

    class DISPPARAMS(Structure):
        _fields_ = [
            ("rgvarg", POINTER(VARIANT)),
            ("rgdispidNamedArgs", POINTER(c_long)),
            ("cArgs", wintypes.UINT),
            ("cNamedArgs", wintypes.UINT)
        ]

    def _vcall(ptr, index, restype, argtypes, *args):
        vtable = cast(ptr, POINTER(POINTER(c_void_p))).contents
        func_ptr = vtable[index]
        prototype = ctypes.WINFUNCTYPE(restype, c_void_p, *argtypes)
        return prototype(func_ptr)(ptr, *args)

    def _invoke_get_id(pdisp, name):
        dispid = c_long()
        rgszNames = (ctypes.c_wchar_p * 1)(name)
        hr = _vcall(pdisp, 5, HRESULT, [POINTER(GUID), POINTER(ctypes.c_wchar_p), wintypes.UINT, wintypes.LCID, POINTER(c_long)],
                    byref(IID_NULL), rgszNames, 1, 0, byref(dispid))
        return dispid.value if hr == 0 else None

    def _invoke_get(pdisp, name):
        dispid = _invoke_get_id(pdisp, name)
        if dispid is None:
            return None
        var_res = VARIANT()
        oleaut32.VariantInit(byref(var_res))
        dp = DISPPARAMS()
        hr = _vcall(pdisp, 6, HRESULT, [c_long, POINTER(GUID), wintypes.LCID, wintypes.WORD, POINTER(DISPPARAMS), POINTER(VARIANT), c_void_p, POINTER(wintypes.UINT)],
                    dispid, byref(IID_NULL), 0, 1 | 2, byref(dp), byref(var_res), None, None)
        return var_res if hr == 0 else None

    def _extract_selected_paths(p_disp):
        doc_res = _invoke_get(p_disp, "Document")
        if not doc_res or doc_res.vt != 9 or not doc_res._u.pdispVal:
            return []
        p_doc = doc_res._u.pdispVal
        sel_res = _invoke_get(p_doc, "SelectedItems")
        if not sel_res or sel_res.vt != 9 or not sel_res._u.pdispVal:
            return []
        p_sel = sel_res._u.pdispVal
        count_res = _invoke_get(p_sel, "Count")
        cnt = count_res._u.lVal if count_res else 0
        if cnt <= 0 or cnt > 100:
            return []

        item_dispid = _invoke_get_id(p_sel, "Item")
        if item_dispid is None:
            return []

        paths = []
        for j in range(cnt):
            v_j = VARIANT(); v_j.vt = 3; v_j._u.lVal = j
            dp = DISPPARAMS(); dp.rgvarg = cast(byref(v_j), POINTER(VARIANT)); dp.cArgs = 1
            var_item = VARIANT(); oleaut32.VariantInit(byref(var_item))
            hr = _vcall(p_sel, 6, HRESULT, [c_long, POINTER(GUID), wintypes.LCID, wintypes.WORD, POINTER(DISPPARAMS), POINTER(VARIANT), c_void_p, POINTER(wintypes.UINT)],
                        item_dispid, byref(IID_NULL), 0, 1, byref(dp), byref(var_item), None, None)
            if hr == 0 and var_item.vt == 9 and var_item._u.pdispVal:
                path_res = _invoke_get(var_item._u.pdispVal, "Path")
                if path_res and path_res.vt == 8 and path_res._u.bstrVal:
                    p = Path(path_res._u.bstrVal)
                    if p.is_file():
                        paths.append(str(p.resolve()))
        return paths

    def query_com_selection(target_hwnd=None):
        """Query Explorer or Desktop selected items via COM."""
        ole32.CoInitialize(None)
        try:
            p_shell_windows = c_void_p()
            hr = ole32.CoCreateInstance(byref(CLSID_ShellWindows), None, 1 | 2 | 4 | 16, byref(IID_IShellWindows), byref(p_shell_windows))
            if hr != 0 or not p_shell_windows.value:
                return []

            # If Desktop (target_hwnd == -1)
            if target_hwnd == -1:
                var_loc = VARIANT(); oleaut32.VariantInit(byref(var_loc))
                var_empty = VARIANT(); oleaut32.VariantInit(byref(var_empty))
                desktop_hwnd = c_long()
                p_desktop_disp = c_void_p()
                hr = _vcall(p_shell_windows, 15, HRESULT, [POINTER(VARIANT), POINTER(VARIANT), c_int, POINTER(c_long), c_int, POINTER(c_void_p)],
                            byref(var_loc), byref(var_empty), 8, byref(desktop_hwnd), 1, byref(p_desktop_disp))
                if hr == 0 and p_desktop_disp.value:
                    return _extract_selected_paths(p_desktop_disp.value)
                return []

            # Search open Explorer windows
            count = c_long()
            hr = _vcall(p_shell_windows, 7, HRESULT, [POINTER(c_long)], byref(count))
            if hr != 0:
                return []

            for i in range(count.value):
                var_idx = VARIANT(); var_idx.vt = 3; var_idx._u.lVal = i
                p_window = c_void_p()
                hr = _vcall(p_shell_windows, 8, HRESULT, [VARIANT, POINTER(c_void_p)], var_idx, byref(p_window))
                if hr == 0 and p_window.value:
                    hwnd_res = _invoke_get(p_window, "HWND")
                    hwnd = hwnd_res._u.lVal if hwnd_res else 0
                    if target_hwnd is None or hwnd == target_hwnd:
                        paths = _extract_selected_paths(p_window.value)
                        if paths:
                            return paths
            return []
        except Exception:
            return []
        finally:
            ole32.CoUninitialize()


class WindowsState:
    def __init__(self):
        if os.name != 'nt':
            return
        from ctypes import wintypes
        self.user = ctypes.WinDLL('user32', use_last_error=True)
        self.user.GetForegroundWindow.restype = wintypes.HWND
        self.user.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
        self.user.GetAsyncKeyState.argtypes = [ctypes.c_int]
        self.user.GetAsyncKeyState.restype = ctypes.c_short

        class POINT(ctypes.Structure):
            _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]
        self.POINT = POINT
        self.user.GetCursorPos.argtypes = [ctypes.POINTER(POINT)]

    def foreground(self):
        if os.name != 'nt':
            return None
        handle = self.user.GetForegroundWindow()
        name = ctypes.create_unicode_buffer(256)
        self.user.GetClassNameW(handle, name, len(name))
        cname = name.value
        if cname in ('CabinetWClass', 'ExploreWClass'):
            return int(handle or 0)
        elif cname in ('Progman', 'WorkerW'):
            # Desktop window marker
            return -1
        return None

    def cursor_pos(self):
        if os.name != 'nt':
            return (0, 0)
        pt = self.POINT()
        self.user.GetCursorPos(ctypes.byref(pt))
        return (pt.x, pt.y)

    def sample(self):
        # Inspect only modifier/mouse-button states, never typed characters.
        if os.name != 'nt':
            return False, False, None, False
        pressed = lambda key: bool(self.user.GetAsyncKeyState(key) & 0x8000)
        shift = pressed(0x10)
        lbutton = pressed(0x01)
        fg = self.foreground()
        blocked = any(pressed(k) for k in (0x11, 0x12, 0x5B, 0x5C, 2)) # Ctrl, Alt, Win, RButton
        return shift, lbutton, fg, blocked


def explorer_selection(handle):
    """Retrieve Explorer or Desktop selection via COM, with fallback to PowerShell."""
    if os.name != 'nt':
        return []
    # 1. Fast direct COM query (~6ms)
    paths = query_com_selection(handle)
    if paths:
        return paths

    # 2. Fallback to PowerShell if COM was not available
    if not isinstance(handle, int) or handle <= 0:
        return []

    script = r'''$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$shell = New-Object -ComObject Shell.Application
$views = @($shell.Windows() | Where-Object { [int64]$_.HWND -eq HANDLE })
if ($views.Count -ne 1) { throw 'Cannot identify the active Explorer view.' }
$items = @($views[0].Document.SelectedItems())
if ($items.Count -gt 100) { throw 'Select at most 100 files.' }
$paths = @()
foreach ($item in $items) {
    if (-not $item.IsFileSystem -or $item.IsFolder) { continue }
    $paths += [string]$item.Path
}
ConvertTo-Json -InputObject @($paths) -Compress
'''.replace('HANDLE', str(handle))
    encoded = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
    executable = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        process = subprocess.Popen([str(executable), '-NoLogo', '-NoProfile', '-NonInteractive', '-STA', '-EncodedCommand', encoded],
                                   stdin=subprocess.DEVNULL, stdout=out, stderr=err, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=2)
            return []
        if process.returncode:
            return []
        out.seek(0)
        data = out.read(65537)
    if len(data) > 65536:
        return []
    try:
        paths = json.loads(data.decode('utf-8-sig'))
        return [p for p in paths if isinstance(p, str) and Path(p).is_file()]
    except Exception:
        return []


class GlobalShiftMonitor(QObject):
    """Watches for selection + Shift hold or drag on Windows."""
    trigger_wheel = Signal(list, object, bool) # paths, QPoint, is_drag

    def __init__(self, parent=None):
        super().__init__(parent)
        self.enabled = (os.name == 'nt' and os.environ.get('QT_QPA_PLATFORM') != 'offscreen')
        self.state = WindowsState() if self.enabled else None
        self.holder = ShiftHold(delay=0.32, drag_threshold=8)
        self.timer = QTimer(self)
        self.timer.setInterval(32) # ~30 Hz sampling
        self.timer.timeout.connect(self._poll)
        self.active_wheel = False

    def start(self):
        if self.enabled:
            self.timer.start()

    def stop(self):
        self.timer.stop()

    def _poll(self):
        if not self.enabled or self.active_wheel:
            return
        shift, lbutton, fg, blocked = self.state.sample()
        pos = self.state.cursor_pos() if self.enabled else (0, 0)
        fired = self.holder.update(shift, lbutton, fg, time.monotonic(), mouse_pos=pos, blocked=blocked)

        if fired:
            target_context, is_drag = fired
            # Fetch selected paths
            paths = explorer_selection(target_context)
            if paths:
                self.trigger_wheel.emit(paths, QPoint(pos[0], pos[1]), is_drag)


def launch_command():
    if getattr(sys, 'frozen', False):
        return [str(Path(sys.executable).resolve())]
    return [str(Path(sys.executable).resolve()), str(Path(__file__).with_name('app.py').resolve())]


def desktop_entry(command):
    def quote(value):
        if any(c in value for c in ('\n', '\r', '\x00')):
            raise ValueError('The application path contains unsupported control characters.')
        value = value.replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%')
        return '"' + value.replace('\\', '\\\\') + '"'
    return ('[Desktop Entry]\nType=Application\nName=Open Tangerine\n'
            'Comment=Show local conversion actions for selected files\n'
            'Exec=' + ' '.join(quote(p) for p in command) + ' --quick-actions -- %F\n'
            'Terminal=false\nNoDisplay=false\nCategories=Utility;Graphics;\n'
            'MimeType=image/png;image/jpeg;image/webp;image/tiff;image/bmp;image/avif;application/pdf;video/mp4;video/webm;video/x-matroska;video/quicktime;audio/mpeg;audio/x-wav;audio/flac;audio/ogg;audio/mp4;application/x-subrip;text/vtt;\n')


def install_linux_entry():
    if not sys.platform.startswith('linux'):
        raise ValueError('This integration is for Linux desktops.')
    base = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
    if not base.is_absolute():
        raise ValueError('XDG_DATA_HOME must be an absolute directory.')
    target = base / 'applications/open-tangerine.desktop'
    target.parent.mkdir(parents=True, exist_ok=True)
    contents = desktop_entry(launch_command())
    if target.exists() and 'Name=Open Tangerine\n' not in target.read_text(encoding='utf-8'):
        raise ValueError('An unrelated launcher already exists; it was kept.')
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=target.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(contents)
    try:
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target
