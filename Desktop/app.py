"""Open Tangerine desktop trial for Windows and Linux."""
import sys
# Worker never imports Qt, creates a window or recursively starts the app.
if '--worker' in sys.argv:
    from engine import worker_main
    raise SystemExit(worker_main())
import os, threading
from pathlib import Path
from PySide6.QtCore import Qt, QThread, Signal, QTimer, QUrl, QSettings, QPoint
from PySide6.QtGui import QDesktopServices, QIcon, QCursor, QAction
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
                               QLabel, QPushButton, QFileDialog, QComboBox, QListWidget,
                               QProgressBar, QSpinBox, QMessageBox, QAbstractItemView,
                               QSystemTrayIcon, QMenu)
from engine import VERSION, OPERATIONS, source_file
from runner import run_job, Cancelled
from actions import available_actions
from radial import RadialWheel, StatusToast
from shell_integration import GlobalShiftMonitor

WEBSITE = 'https://sintaxerrorpvtltd.github.io/Open-Tangerine/'


class Batch(QThread):
    started_job = Signal(int)
    result = Signal(int, str, list)
    progress = Signal(int, int)

    def __init__(self, paths, target, options):
        super().__init__()
        self.paths = paths
        self.target = target
        self.options = options
        self.cancel = threading.Event()

    def run(self):
        groups = [self.paths] if self.target == 'Merge PDFs' else [[p] for p in self.paths]
        for i, paths in enumerate(groups):
            if self.cancel.is_set():
                break
            self.started_job.emit(i)
            try:
                outputs = run_job(dict(paths=paths, target=self.target, **self.options), self.cancel)
                self.result.emit(i, 'Done', outputs)
            except Cancelled:
                self.result.emit(i, 'Cancelled', [])
                break
            except Exception as e:
                self.result.emit(i, 'Failed: ' + str(e), getattr(e, 'outputs', []))
            self.progress.emit(i + 1, len(groups))


class DropList(QListWidget):
    files = Signal(list)

    def __init__(self):
        super().__init__()
        self.setAcceptDrops(True)
        self.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.setMinimumHeight(190)

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls() and all(u.isLocalFile() for u in event.mimeData().urls()):
            self.setStyleSheet('border:2px solid #ff610a;background:#2a201a;')
            event.acceptProposedAction()
        else:
            event.ignore()

    def dragMoveEvent(self, event):
        self.dragEnterEvent(event)

    def dragLeaveEvent(self, event):
        self.setStyleSheet('')
        event.accept()

    def dropEvent(self, event):
        self.setStyleSheet('')
        if event.mimeData().hasUrls() and all(u.isLocalFile() for u in event.mimeData().urls()):
            self.files.emit([u.toLocalFile() for u in event.mimeData().urls()])
            event.acceptProposedAction()
        else:
            event.ignore()


class Window(QMainWindow):
    def __init__(self):
        super().__init__()
        self.paths = []
        self.outputs = []
        self.batch = None
        self.busy = False
        self.states = []
        self.active_wheel = None
        self.toast = StatusToast()
        self.tray = None
        self._force_quit = False

        self.settings = QSettings('Sintax Error Private Limited', 'Open Tangerine Desktop')
        self.setWindowTitle('Open Tangerine · Windows / Linux trial')
        self.resize(800, 710)
        self.icon_path = Path(__file__).with_name('icon.png')
        if self.icon_path.exists():
            self.setWindowIcon(QIcon(str(self.icon_path)))

        box = QWidget()
        self.setCentralWidget(box)
        layout = QVBoxLayout(box)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(12)

        title = QLabel('Open Tangerine')
        title.setStyleSheet('font-size:30px;font-weight:bold;color:#ff762b')
        layout.addWidget(title)
        layout.addWidget(QLabel('Drop your files. Choose an output. Keep working.'))

        note = QLabel('Windows / Linux trial · Local processing · Originals kept\n'
                      'Global Shift Wheel: select file(s) in Explorer or Desktop, then hold Shift (or drag + Shift) to convert at the same location.')
        note.setWordWrap(True)
        layout.addWidget(note)

        self.list = DropList()
        self.list.setAccessibleName('Files and conversion results')
        self.list.files.connect(self.add_paths)
        layout.addWidget(self.list)

        row = QHBoxLayout()
        layout.addLayout(row)
        self.add = QPushButton('Add files…')
        self.add.clicked.connect(self.pick)
        row.addWidget(self.add)
        self.wheel_btn = QPushButton('Quick wheel…')
        self.wheel_btn.setStyleSheet('color:#ff762b;font-weight:bold;')
        self.wheel_btn.clicked.connect(self.trigger_wheel_picker)
        row.addWidget(self.wheel_btn)
        self.clear = QPushButton('Clear')
        self.clear.clicked.connect(self.clear_files)
        row.addWidget(self.clear)
        self.folder = QPushButton('Choose output folder…')
        self.folder.clicked.connect(self.choose_folder)
        row.addWidget(self.folder)
        self.reset_folder = QPushButton('Save beside originals')
        self.reset_folder.clicked.connect(self.use_original_folders)
        self.reset_folder.hide()
        row.addWidget(self.reset_folder)

        self.output = ''
        row = QHBoxLayout()
        layout.addLayout(row)
        row.addWidget(QLabel('Convert / tool'))
        self.target = QComboBox()
        self.target.setAccessibleName('Conversion or tool')
        self.target.addItems(OPERATIONS)
        row.addWidget(self.target, 1)
        self.width = QSpinBox()
        self.width.setRange(0, 10000)
        self.width.setSpecialValueText('Original size')
        self.width.setSuffix(' px max side')
        self.width.setAccessibleName('Maximum image side in pixels')
        row.addWidget(self.width)
        self.rotate = QComboBox()
        self.rotate.setAccessibleName('Clockwise image rotation')
        self.rotate.addItems(['No rotation', '90° clockwise', '180°', '270° clockwise'])
        row.addWidget(self.rotate)
        self.target.currentTextChanged.connect(self.update_options)
        self.update_options()

        row = QHBoxLayout()
        layout.addLayout(row)
        self.convert = QPushButton('Convert files')
        self.convert.setStyleSheet('background:#ff610a;color:#101010;font-weight:bold;padding:12px;')
        self.convert.clicked.connect(self.start)
        row.addWidget(self.convert)
        self.cancel = QPushButton('Cancel')
        self.cancel.setEnabled(False)
        self.cancel.clicked.connect(self.cancel_batch)
        row.addWidget(self.cancel)
        self.open = QPushButton('Open output folder')
        self.open.setEnabled(False)
        self.open.clicked.connect(self.open_output)
        row.addWidget(self.open)

        self.progress = QProgressBar()
        self.progress.setValue(0)
        layout.addWidget(self.progress)
        self.status = QLabel('Ready. Up to 100 files per batch; 100 MiB per input. Shift wheel active.')
        self.status.setWordWrap(True)
        self.status.setTextFormat(Qt.PlainText)
        layout.addWidget(self.status)

        row = QHBoxLayout()
        layout.addLayout(row)
        self.ffmpeg = QPushButton('Set FFmpeg…')
        self.ffmpeg.clicked.connect(self.set_ffmpeg)
        row.addWidget(self.ffmpeg)
        updates = QPushButton('Downloads / updates')
        updates.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(WEBSITE + '?platform=desktop&version=' + VERSION + '#desktop')))
        row.addWidget(updates)
        limits = QPushButton('Supported features')
        limits.clicked.connect(self.show_limits)
        row.addWidget(limits)
        layout.addWidget(QLabel('Sintax Error Private Limited · GPL-3.0-only · v' + VERSION))

        # Global selection monitor for Windows
        self.monitor = GlobalShiftMonitor(self)
        self.monitor.trigger_wheel.connect(self.show_radial_wheel)
        self.monitor.start()

        # System tray icon
        self._init_tray()

    def _init_tray(self):
        if not QSystemTrayIcon.isSystemTrayAvailable():
            return
        icon = QIcon(str(self.icon_path)) if self.icon_path.exists() else self.windowIcon()
        self.tray = QSystemTrayIcon(icon, self)
        self.tray.setToolTip('Open Tangerine · Select files + Shift to convert')

        menu = QMenu(self)
        show_act = QAction('Open Tangerine', self)
        show_act.triggered.connect(self.show_normal)
        menu.addAction(show_act)

        wheel_act = QAction('Convert Files (Wheel)…', self)
        wheel_act.triggered.connect(self.trigger_wheel_picker)
        menu.addAction(wheel_act)

        menu.addSeparator()
        self.tray_wheel_toggle = QAction('Global Shift Wheel (Active)', self)
        self.tray_wheel_toggle.setCheckable(True)
        self.tray_wheel_toggle.setChecked(True)
        self.tray_wheel_toggle.toggled.connect(self._toggle_monitor)
        menu.addAction(self.tray_wheel_toggle)

        menu.addSeparator()
        exit_act = QAction('Exit', self)
        exit_act.triggered.connect(self.quit_app)
        menu.addAction(exit_act)

        self.tray.setContextMenu(menu)
        self.tray.activated.connect(self._tray_activated)
        self.tray.show()

    def show_normal(self):
        self.show()
        self.setWindowState(self.windowState() & ~Qt.WindowMinimized | Qt.WindowActive)
        self.raise_()
        self.activateWindow()

    def _tray_activated(self, reason):
        if reason in (QSystemTrayIcon.DoubleClick, QSystemTrayIcon.Trigger):
            if self.isVisible():
                self.hide()
            else:
                self.show_normal()

    def _toggle_monitor(self, enabled):
        if enabled:
            self.monitor.start()
            self.tray_wheel_toggle.setText('Global Shift Wheel (Active)')
            self.status.setText('Global Shift wheel enabled.')
        else:
            self.monitor.stop()
            self.tray_wheel_toggle.setText('Global Shift Wheel (Paused)')
            self.status.setText('Global Shift wheel paused.')

    def quit_app(self):
        self._force_quit = True
        if self.busy:
            self.cancel_batch()
        self.monitor.stop()
        if self.active_wheel:
            self.active_wheel.close()
        self.toast.close()
        if self.tray:
            self.tray.hide()
        self.close()
        QApplication.quit()

    def update_options(self):
        enabled = not self.busy and self.target.currentText() in ['PNG', 'JPEG', 'WEBP', 'TIFF', 'BMP', 'Image → PDF']
        self.width.setEnabled(enabled)
        self.rotate.setEnabled(enabled)

    def add_paths(self, paths):
        if self.busy:
            return
        errors = []
        for raw in paths:
            try:
                p = str(source_file(raw))
                if p in self.paths:
                    continue
                if len(self.paths) >= 100:
                    raise ValueError('Batch limit: 100 files.')
                self.paths.append(p)
                self.list.addItem(Path(p).name)
            except Exception as e:
                errors.append(str(e))
        self.status.setText('; '.join(errors[:3]) if errors else f'{len(self.paths)} files ready.')

    def pick(self):
        self.add_paths(QFileDialog.getOpenFileNames(self, 'Select files')[0])

    def trigger_wheel_picker(self):
        files = QFileDialog.getOpenFileNames(self, 'Select files for quick conversion')[0]
        if files:
            self.show_radial_wheel(files, QCursor.pos())

    def clear_files(self):
        if self.busy:
            return
        self.paths = []
        self.states = []
        self.list.clear()
        self.outputs = []
        self.open.setEnabled(False)
        self.progress.setValue(0)
        self.status.setText('Ready.')

    def choose_folder(self):
        if self.busy:
            return
        folder = QFileDialog.getExistingDirectory(self, 'Choose output folder')
        if folder:
            self.output = folder
            self.folder.setText('Output: ' + Path(folder).name)
            self.folder.setToolTip(folder)
            self.reset_folder.show()

    def use_original_folders(self):
        if self.busy:
            return
        self.output = ''
        self.folder.setText('Choose output folder…')
        self.folder.setToolTip('')
        self.reset_folder.hide()

    def set_ffmpeg(self):
        if self.busy:
            return
        path = QFileDialog.getOpenFileName(self, 'Select FFmpeg from a trusted installation')[0]
        if path:
            self.settings.setValue('ffmpeg', str(Path(path).resolve()))
            self.status.setText('FFmpeg selected. It runs only when you request media conversion.')

    def show_limits(self):
        QMessageBox.information(self, 'Desktop capabilities',
                                'Global Shift wheel: select file(s) in Windows Explorer or Desktop, then hold Shift (or drag + Shift) to trigger the wheel.\n\n'
                                'Images: PNG, JPEG, WebP, TIFF, BMP output; PNG/JPEG/WebP/TIFF/BMP/AVIF input. Resize and rotate. Single-frame only; 40 megapixels. HEIC and SVG are not supported in this trial.\n\n'
                                'PDF: image to PDF, merge (up to 200 pages), split and extract text. No OCR, Word conversion or password-protected PDFs.\n\n'
                                'Media: MP4/WebM/MP3/WAV/FLAC/Ogg using a separately selected FFmpeg. Codecs depend on your installation. No FFmpeg download is performed.\n\n'
                                'Simple SRT/VTT conversion and SHA-256 checksums.\n\n'
                                'Workers have time/output limits but are not an operating-system security sandbox. Process trusted files. Failed files do not stop the batch.')

    def set_row(self, index, state, detail='', outputs=()):
        self.states[index] = state
        item = self.list.item(index)
        if item:
            item.setText(Path(self.paths[index]).name + ' — ' + (detail or state))
            item.setToolTip('\n'.join(outputs) or detail or state)

    def job_rows(self, index):
        return range(len(self.paths)) if self.batch.target == 'Merge PDFs' else (index,)

    def job_started(self, index):
        for row in self.job_rows(index):
            self.set_row(row, 'Converting')

    def start(self):
        if self.busy or not self.paths:
            return
        if self.batch:
            self.batch.deleteLater()
        self.busy = True
        self.outputs = []
        self.states = ['Queued'] * len(self.paths)
        self.open.setEnabled(False)
        self.progress.setValue(0)
        for i in range(len(self.paths)):
            self.set_row(i, 'Queued')
        for button in (self.add, self.wheel_btn, self.clear, self.folder, self.reset_folder, self.convert, self.target, self.ffmpeg):
            button.setEnabled(False)
        self.list.setAcceptDrops(False)
        self.update_options()
        self.cancel.setEnabled(True)
        self.status.setText('Converting…')
        self.batch = Batch(list(self.paths), self.target.currentText(),
                           {'output': self.output, 'width': self.width.value(),
                            'rotation': self.rotate.currentIndex() * 90,
                            'ffmpeg': self.settings.value('ffmpeg', '')})
        self.batch.started_job.connect(self.job_started)
        self.batch.result.connect(self.result)
        self.batch.progress.connect(lambda n, total: self.progress.setValue(round(n / total * 100)))
        self.batch.finished.connect(self.finished)
        self.batch.start()

    def result(self, index, status, outputs):
        self.outputs.extend(outputs)
        state = status if status in ('Done', 'Cancelled') else 'Failed'
        for row in self.job_rows(index):
            self.set_row(row, state, status, outputs)
        self.status.setText(status)
        self.open.setEnabled(bool(self.outputs))

    def finished(self):
        for i, state in enumerate(self.states):
            if state in ('Queued', 'Converting'):
                state = 'Cancelled' if (self.batch and self.batch.cancel.is_set()) else 'Failed'
                self.set_row(i, state)
        self.busy = False
        for button in (self.add, self.wheel_btn, self.clear, self.folder, self.reset_folder, self.convert, self.target, self.ffmpeg):
            button.setEnabled(True)
        self.list.setAcceptDrops(True)
        self.cancel.setEnabled(False)
        self.update_options()
        prefix = 'Cancelled' if 'Cancelled' in self.states else 'Finished'
        self.status.setText(f'{prefix}: {self.states.count("Done")} succeeded, {self.states.count("Failed")} failed, {self.states.count("Cancelled")} cancelled. {len(self.outputs)} output file(s) kept.')

    def cancel_batch(self):
        if self.busy and self.batch:
            self.batch.cancel.set()
            self.cancel.setEnabled(False)
            self.status.setText('Cancelling… Completed outputs will be kept.')

    def open_output(self):
        if self.outputs:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(Path(self.outputs[-1]).parent)))

    def show_radial_wheel(self, paths, pos=None, is_drag=False):
        """Present the radial wheel for quick selection conversion."""
        if not paths:
            return
        actions = available_actions(paths)
        if not actions:
            return

        if self.active_wheel:
            try:
                self.active_wheel.close()
                self.active_wheel.deleteLater()
            except Exception:
                pass
            self.active_wheel = None

        wheel = RadialWheel(paths, actions)
        self.active_wheel = wheel
        self.monitor.active_wheel = True

        wheel.action_selected.connect(self.quick_convert)
        wheel.cancelled.connect(self.on_wheel_closed)
        wheel.destroyed.connect(self.on_wheel_closed)

        wheel.show_animated(pos)

    def on_wheel_closed(self):
        self.monitor.active_wheel = False
        self.active_wheel = None

    def quick_convert(self, target, paths):
        """Convert selected files and save beside originals."""
        self.on_wheel_closed()
        if not paths:
            return
        if self.busy:
            self.toast.show_error("Converter is busy with another batch.")
            return

        self.toast.show_converting(len(paths), target)
        self.busy = True
        self.outputs = []
        self.paths = list(paths)
        self.states = ['Queued'] * len(paths)
        self.list.clear()
        for p in paths:
            self.list.addItem(Path(p).name)
        for i in range(len(paths)):
            self.set_row(i, 'Queued')

        for button in (self.add, self.wheel_btn, self.clear, self.folder, self.reset_folder, self.convert, self.target, self.ffmpeg):
            button.setEnabled(False)
        self.list.setAcceptDrops(False)
        self.update_options()
        self.cancel.setEnabled(True)
        self.status.setText(f'Converting {len(paths)} file(s) to {target} beside originals…')

        # Output folder is empty string ('') -> saves beside original files!
        options = {
            'output': '',
            'width': self.width.value(),
            'rotation': self.rotate.currentIndex() * 90,
            'ffmpeg': self.settings.value('ffmpeg', '')
        }
        self.batch = Batch(list(paths), target, options)
        self.batch.started_job.connect(self.job_started)
        self.batch.result.connect(self.result)
        self.batch.progress.connect(lambda n, total: self.progress.setValue(round(n / total * 100)))

        def on_quick_finished():
            self.finished()
            self.toast.show_finished(self.outputs)

        self.batch.finished.connect(on_quick_finished)
        self.batch.start()

    def closeEvent(self, event):
        if self.busy:
            self.cancel_batch()
            event.ignore()
            self.status.setText('Stopping conversion before closing…')
            QTimer.singleShot(200, self.close)
            return

        if getattr(self, '_force_quit', False) or not event.spontaneous() or os.environ.get('QT_QPA_PLATFORM') == 'offscreen':
            self.monitor.stop()
            if self.active_wheel:
                self.active_wheel.close()
            self.toast.close()
            if self.tray:
                self.tray.hide()
            event.accept()
        else:
            # User closed window: keep running constantly in background tray ("Show hidden items")
            event.ignore()
            self.hide()
            if self.tray and not getattr(self, '_notified_tray', False):
                self._notified_tray = True
                self.tray.showMessage(
                    'Open Tangerine',
                    'Running in background. Select files + hold Shift to convert, or right-click icon in hidden items to Exit.',
                    QSystemTrayIcon.Information,
                    3000
                )


def main():
    if os.name == 'nt' and getattr(sys, 'frozen', False):
        import ctypes
        handle = ctypes.windll.kernel32.GetConsoleWindow()
        if handle:
            ctypes.windll.user32.ShowWindow(handle, 0)

    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setStyle('Fusion')
    app.setStyleSheet('QWidget{background:#171717;color:#f5f3ed;font-size:13px} '
                      'QPushButton,QComboBox,QSpinBox{padding:8px;border:1px solid #666;border-radius:6px} '
                      'QPushButton:disabled{color:#888} '
                      'QListWidget{background:#222;border:2px dashed #777;border-radius:10px;padding:8px} '
                      'QProgressBar{border:1px solid #666;border-radius:4px;text-align:center} '
                      'QProgressBar::chunk{background:#ff610a}')
    window = Window()

    # CLI wheel trigger (e.g. app.py --wheel path1 path2 or --quick-actions -- path1 path2)
    cli_files = []
    args = sys.argv[1:]
    if '--quick-actions' in args or '--wheel' in args:
        idx = args.index('--quick-actions') if '--quick-actions' in args else args.index('--wheel')
        targets = args[idx + 1:]
        if targets and targets[0] == '--':
            targets = targets[1:]
        cli_files = [str(Path(p).resolve()) for p in targets if Path(p).is_file()]

    if cli_files:
        window.show_radial_wheel(cli_files)
    elif '--tray' not in args:
        window.show()

    if '--smoke-test' in sys.argv:
        QTimer.singleShot(400, app.quit)
    return app.exec()


if __name__ == '__main__':
    raise SystemExit(main())
