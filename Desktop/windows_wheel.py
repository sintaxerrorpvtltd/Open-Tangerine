"""Windows Shift selection monitor and nonactivating file-drop overlay."""
import ctypes
import json
import os
import time
from pathlib import Path

from PySide6.QtCore import Qt, QObject, QTimer, QProcess, Signal
from PySide6.QtGui import QCursor, QPainter, QRegion
from PySide6.QtWidgets import QWidget, QApplication
from engine import IMAGE_INPUTS, IMAGE_OUTPUTS, MEDIA_INPUTS, MEDIA_OUTPUTS, DOCX_OUTPUTS, source_file
from glass_design import draw_ring, draw_hub, target_at


def available_formats(paths, ffmpeg=False):
    """Only offer operations shared by every input; workers validate contents."""
    if not paths or len(paths) > 100:
        return []
    suffixes = {Path(p).suffix.lower() for p in paths}
    if suffixes <= IMAGE_INPUTS:
        return [*IMAGE_OUTPUTS, 'Image → PDF']
    if suffixes == {'.pdf'}:
        return ['PDF → Text', 'Split PDF'] + (['Merge PDFs'] if len(paths) > 1 else [])
    if suffixes == {'.srt'}:
        return ['SRT → VTT']
    if suffixes == {'.vtt'}:
        return ['VTT → SRT']
    if suffixes == {'.docx'}:
        return list(DOCX_OUTPUTS)
    if suffixes <= MEDIA_INPUTS.keys() and ffmpeg:
        audio = {'.mp3', '.wav', '.flac', '.ogg', '.m4a', '.aac'}
        return list(MEDIA_OUTPUTS) if not suffixes & audio else ['MP3', 'WAV', 'FLAC', 'OGG']
    return []


class DragWheel(QWidget):
    convert = Signal(list, str)

    def __init__(self, ffmpeg, parent=None):
        super().__init__(parent, Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
                         | Qt.WindowDoesNotAcceptFocus)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        self.setAcceptDrops(True)
        self.setAccessibleName('Shift file conversion wheel')
        self.resize(380, 380)
        self.ffmpeg = ffmpeg
        self.paths = []
        self.formats = []
        self.hover = -1
        self.notice = ''
        self.companion = WheelCompanion(self)
        # A hollow window keeps the selected Explorer item reachable for dragging.
        self.setMask(QRegion(8, 8, 364, 364, QRegion.Ellipse)
                     - QRegion(125, 125, 130, 130, QRegion.Ellipse))

    def present(self, paths, point):
        self.paths = paths
        self.formats = available_formats(paths, bool(self.ffmpeg()))
        self.notice = ''
        suffixes = {Path(p).suffix.lower() for p in paths}
        if paths and not self.formats:
            if suffixes <= MEDIA_INPUTS.keys() and not self.ffmpeg():
                self.notice = 'Set FFmpeg in app for audio/video'
        self.hover = -1
        screen = QApplication.screenAt(point) or QApplication.primaryScreen()
        area = screen.availableGeometry()
        self.move(max(area.left(), min(point.x()-190, area.right()-379)),
                  max(area.top(), min(point.y()-190, area.bottom()-424)))
        self.show()
        self.update()

    def sector(self, point):
        return target_at(point, self.formats)

    def adopt(self, event):
        mime = event.mimeData()
        if not mime.hasUrls() or not all(u.isLocalFile() for u in mime.urls()):
            return False
        try:
            urls = mime.urls()
            if not 1 <= len(urls) <= 100:
                return False
            paths = [str(source_file(u.toLocalFile())) for u in urls]
        except (OSError, ValueError):
            return False
        formats = available_formats(paths, bool(self.ffmpeg()))
        if not formats:
            return False
        self.paths, self.formats = paths, formats
        self.notice = ''
        return True

    def dragEnterEvent(self, event):
        if self.adopt(event) and event.possibleActions() & Qt.CopyAction:
            self.hover = self.sector(event.position())
            event.setDropAction(Qt.CopyAction); event.accept(); self.update()
        else:
            event.ignore()

    def dragMoveEvent(self, event):
        self.hover = self.sector(event.position())
        if self.hover >= 0 and event.possibleActions() & Qt.CopyAction:
            event.setDropAction(Qt.CopyAction); event.accept()
        else:
            event.ignore()
        self.update()

    def dragLeaveEvent(self, event):
        self.hover = -1; self.update(); event.accept()

    def dropEvent(self, event):
        if self.adopt(event) and event.possibleActions() & Qt.CopyAction:
            index = self.sector(event.position())
            if index >= 0:
                paths, target = list(self.paths), self.formats[index]
                event.setDropAction(Qt.CopyAction); event.accept(); self.hide()
                self.convert.emit(paths, target)
                return
        event.ignore()

    def showEvent(self, event):
        self.companion.move(self.pos())
        self.companion.show()
        super().showEvent(event)

    def hideEvent(self, event):
        self.companion.hide()
        super().hideEvent(event)

    def moveEvent(self, event):
        self.companion.move(self.pos())
        super().moveEvent(event)

    def paintEvent(self, event):
        p = QPainter(self); p.setRenderHint(QPainter.Antialiasing)
        draw_ring(p, self.formats or (['SETUP'] if self.notice else []), self.hover)
        self.companion.update()


class WheelCompanion(QWidget):
    """Visible hub/caption with native input pass-through to the source file."""
    def __init__(self, wheel):
        super().__init__(wheel, Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
                         | Qt.WindowDoesNotAcceptFocus | Qt.WindowTransparentForInput)
        self.wheel = wheel
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_TransparentForMouseEvents)
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        self.resize(380, 425)
        # Limit this window to just the visible hub and caption.
        self.setMask(QRegion(125, 125, 130, 130, QRegion.Ellipse)
                     | QRegion(54, 384, 272, 33))

    def paintEvent(self, event):
        p = QPainter(self); p.setRenderHint(QPainter.Antialiasing)
        draw_hub(p, self.wheel.formats, self.wheel.hover, self.wheel.notice)


# Fixed script, selected file paths are data returned as JSON, never shell code.
SELECTION_SCRIPT = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$shell = New-Object -ComObject Shell.Application
$result = @()
$view = $null
foreach ($window in $shell.Windows()) {
    if ([long]$window.HWND -eq FOREGROUND_HANDLE) {
        $view = $window.Document
        break
    }
}
if ($null -eq $view -and IS_DESKTOP) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DesktopSelection {
    [ComImport, Guid("85CB6900-4D95-11CF-960C-0080C7F4EE85"), InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
    interface ShellWindows {
        [return: MarshalAs(UnmanagedType.IDispatch)]
        object FindWindowSW(ref object location, ref object root, int kind, out int hwnd, int flags);
    }
    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ServiceProvider {
        [return: MarshalAs(UnmanagedType.Interface)] object QueryService(ref Guid service, ref Guid iid);
    }
    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface Browser {
        void GetWindow(); void ContextSensitiveHelp(); void InsertMenusSB();
        void SetMenuSB(); void RemoveMenusSB(); void SetStatusTextSB();
        void EnableModelessSB(); void TranslateAcceleratorSB(); void BrowseObject();
        void GetViewStateStream(); void GetControlWindow(); void SendControlMsg();
        View QueryActiveShellView();
    }
    [ComImport, Guid("000214E3-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface View {
        void GetWindow(); void ContextSensitiveHelp(); void TranslateAccelerator();
        void EnableModeless(); void UIActivate(); void Refresh(); void CreateViewWindow();
        void DestroyViewWindow(); void GetCurrentInfo(); void AddPropertySheetPages();
        void SaveViewState(); void SelectItem();
        [return: MarshalAs(UnmanagedType.IDispatch)] object GetItemObject(uint kind, ref Guid iid);
    }
    public static object GetView() {
        var type = Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39"));
        var windows = (ShellWindows)Activator.CreateInstance(type);
        object location = 0, root = null; int hwnd;
        var provider = (ServiceProvider)windows.FindWindowSW(ref location, ref root, 8, out hwnd, 1);
        var service = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");
        var browserId = typeof(Browser).GUID;
        var browser = (Browser)provider.QueryService(ref service, ref browserId);
        var dispatch = new Guid("00020400-0000-0000-C000-000000000046");
        return browser.QueryActiveShellView().GetItemObject(0, ref dispatch);
    }
}
'@
    $view = [DesktopSelection]::GetView()
}
if ($null -ne $view) {
    foreach ($item in $view.SelectedItems()) {
        if (-not $item.IsFolder) { $result += [string]$item.Path }
        if ($result.Count -gt 100) { break }
    }
}
ConvertTo-Json -InputObject @($result) -Compress
'''


class WindowsShiftWheel(QObject):
    """Poll modifier state, without consuming keys or recording typed input."""
    def __init__(self, window):
        super().__init__(window)
        self.window = window
        self.overlay = DragWheel(window.ffmpeg_path)
        self.overlay.convert.connect(self.convert)
        self.down = False
        self.gesture_started = None
        self.enabled = False
        self.cancelled = False
        self.dragging = False
        self.lookup = QProcess(self)
        self.lookup.finished.connect(self.selection_ready)
        self.lookup.setProcessChannelMode(QProcess.SeparateChannels)
        self.timeout = QTimer(self); self.timeout.setSingleShot(True)
        self.timeout.timeout.connect(self.lookup.kill)
        self.timer = QTimer(self); self.timer.timeout.connect(self.poll)
        self.user = ctypes.WinDLL('user32', use_last_error=True)
        self.user.GetAsyncKeyState.argtypes = [ctypes.c_int]
        self.user.GetAsyncKeyState.restype = ctypes.c_short
        self.user.GetForegroundWindow.restype = ctypes.c_void_p
        self.user.GetClassNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]

    def set_enabled(self, enabled):
        self.enabled = bool(enabled)
        self.cancelled = True
        self.gesture_started = None
        self.down = False
        if self.enabled:
            self.timer.start(40)
        else:
            self.timer.stop()
            self.timeout.stop()
            self.lookup.kill()
            self.overlay.hide()

    def held(self, key):
        return bool(self.user.GetAsyncKeyState(key) & 0x8000)

    def poll(self):
        shift = self.held(0x10)
        mouse = self.held(2 if self.user.GetSystemMetrics(23) else 1)
        modified = any(self.held(k) for k in (0x11, 0x12, 0x5B, 0x5C))
        if (not self.enabled or self.held(0x1B) or modified
                or (self.window.batch and self.window.batch.isRunning())):
            self.cancelled = True
            self.overlay.hide()
            self.gesture_started = None
            self.down = shift and mouse
            return
        if not (shift and mouse):
            self.overlay.hide()
            self.cancelled = True
            self.gesture_started = None
            self.down = False
            return
        # Only Explorer/Desktop file drags may trigger the wheel, never editor drags
        # or Shift typing. A brief hold avoids flashing during ordinary selection.
        if self.down:
            return
        hwnd = self.user.GetForegroundWindow() or 0
        name = ctypes.create_unicode_buffer(256)
        self.user.GetClassNameW(hwnd, name, 256)
        if name.value not in ('Progman', 'WorkerW', 'CabinetWClass', 'ExploreWClass'):
            self.gesture_started = None
            return
        if self.gesture_started is None:
            self.gesture_started = time.monotonic()
            return
        if time.monotonic() - self.gesture_started < .3 or self.lookup.state() != QProcess.NotRunning:
            return
        self.down = True
        self.cancelled = False
        self.point = QCursor.pos()
        self.source_handle = hwnd
        script = SELECTION_SCRIPT.replace('FOREGROUND_HANDLE', str(int(hwnd)))
        script = script.replace('IS_DESKTOP', '$true' if name.value in ('Progman', 'WorkerW') else '$false')
        powershell = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        if not powershell.is_absolute():
            self.cancelled = True
            return
        import base64
        self.lookup.start(str(powershell), ['-NoProfile', '-NonInteractive', '-STA',
            '-EncodedCommand', base64.b64encode(script.encode('utf-16le')).decode('ascii')])
        self.timeout.start(5000)

    def selection_ready(self, code, status):
        self.timeout.stop()
        if (self.cancelled or not self.enabled or not self.held(0x10) or code != 0
                or not self.held(2 if self.user.GetSystemMetrics(23) else 1)):
            return
        if self.user.GetForegroundWindow() != self.source_handle:
            return
        try:
            paths = json.loads(bytes(self.lookup.readAllStandardOutput()).decode('utf-8-sig'))
            if not isinstance(paths, list) or not 1 <= len(paths) <= 100: return
            paths = [str(source_file(p)) for p in paths]
        except (OSError, ValueError, TypeError):
            return
        suffixes = {Path(p).suffix.lower() for p in paths}
        needs_setup = bool(paths) and suffixes <= MEDIA_INPUTS.keys()
        if paths and (available_formats(paths, bool(self.window.ffmpeg_path())) or needs_setup):
            self.overlay.present(paths, self.point)

    def convert(self, paths, target):
        if self.window.batch and self.window.batch.isRunning(): return
        self.window.clear_files(); self.window.add_paths(paths)
        if len(self.window.paths) != len(paths): return
        self.window.target.setCurrentText(target)
        self.window.start()

    def stop(self):
        self.timer.stop(); self.timeout.stop(); self.overlay.close(); self.lookup.kill()
        self.lookup.waitForFinished(1000)
