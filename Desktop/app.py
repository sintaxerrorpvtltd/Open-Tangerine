"""Open Tangerine desktop trial for Windows and Linux."""
import sys
# Worker never imports Qt, creates a window or recursively starts the app.
if '--worker' in sys.argv:
    from engine import worker_main
    raise SystemExit(worker_main())
import os, threading
from pathlib import Path
from PySide6.QtCore import Qt, QThread, Signal, QTimer, QUrl, QSettings
from PySide6.QtGui import QDesktopServices, QIcon
from PySide6.QtWidgets import (QApplication,QMainWindow,QWidget,QVBoxLayout,QHBoxLayout,QLabel,QPushButton,QFileDialog,QComboBox,QListWidget,QProgressBar,QSpinBox,QMessageBox,QAbstractItemView,QCheckBox)
from engine import VERSION, OPERATIONS, source_file
from runner import run_job, Cancelled
from glass_wheel import GlassWheel, WHEEL_STYLE
WEBSITE='https://sintaxerrorpvtltd.github.io/Open-Tangerine/'

class Batch(QThread):
    result=Signal(int,str,list)
    progress=Signal(int,int)
    def __init__(self,paths,target,options):
        super().__init__();self.paths=paths;self.target=target;self.options=options;self.cancel=threading.Event()
    def run(self):
        groups=[self.paths] if self.target=='Merge PDFs' else [[p] for p in self.paths]
        for i,paths in enumerate(groups):
            if self.cancel.is_set(): break
            try:
                outputs=run_job(dict(paths=paths,target=self.target,**self.options),self.cancel)
                self.result.emit(i,'Done',outputs)
            except Cancelled as e:
                self.result.emit(i,str(e),[]);break
            except Exception as e:self.result.emit(i,str(e),[])
            self.progress.emit(i+1,len(groups))

class DropList(QListWidget):
    files=Signal(list)
    def __init__(self):
        super().__init__();self.setAcceptDrops(True);self.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.setMinimumHeight(190)
    def dragEnterEvent(self,event):
        if event.possibleActions() & Qt.CopyAction and event.mimeData().hasUrls() and all(u.isLocalFile() for u in event.mimeData().urls()):
            self.setStyleSheet('border:2px solid #ff610a;background:#2a201a;');event.setDropAction(Qt.CopyAction);event.accept()
        else:event.ignore()
    def dragMoveEvent(self,event): self.dragEnterEvent(event)
    def dragLeaveEvent(self,event): self.setStyleSheet('');event.accept()
    def dropEvent(self,event):
        self.setStyleSheet('')
        if event.possibleActions() & Qt.CopyAction and event.mimeData().hasUrls() and all(u.isLocalFile() for u in event.mimeData().urls()):
            self.files.emit([u.toLocalFile() for u in event.mimeData().urls()]);event.setDropAction(Qt.CopyAction);event.accept()
        else:event.ignore()

class Window(QMainWindow):
    def __init__(self, global_wheel=True):
        super().__init__();self.paths=[];self.outputs=[];self.batch=None
        self.background=None;self.quitting=False;self.batch_errors=[]
        self.settings=QSettings('Sintax Error Private Limited','Open Tangerine Desktop')
        self.setWindowTitle('Open Tangerine · Windows / Linux trial');self.resize(800,690)
        icon=Path(__file__).with_name('icon.png')
        if icon.exists():self.setWindowIcon(QIcon(str(icon)))
        box=QWidget();self.setCentralWidget(box);layout=QVBoxLayout(box);layout.setContentsMargins(28,24,28,24);layout.setSpacing(12)
        title=QLabel('Open Tangerine');title.setStyleSheet('font-size:30px;font-weight:bold;color:#ff762b');layout.addWidget(title)
        layout.addWidget(QLabel('Drop your files. Choose an output. Keep working.'))
        note=QLabel('Local processing · Originals kept\n'+('Enable the optional wheel below. Drag files from Explorer/Desktop and hold Shift. Escape cancels.' if os.name=='nt' else 'Drop files into this window to convert.'));note.setWordWrap(True);layout.addWidget(note)
        workspace=QHBoxLayout();layout.addLayout(workspace)
        self.wheel=GlassWheel();self.wheel.setStyleSheet(WHEEL_STYLE);workspace.addWidget(self.wheel)
        self.list=DropList();self.list.files.connect(self.add_paths);workspace.addWidget(self.list,1)
        row=QHBoxLayout();layout.addLayout(row)
        self.add=QPushButton('Add files…');self.add.clicked.connect(self.pick);row.addWidget(self.add)
        self.clear=QPushButton('Clear');self.clear.clicked.connect(self.clear_files);row.addWidget(self.clear)
        self.folder=QPushButton('Save beside originals');self.folder.clicked.connect(self.choose_folder);row.addWidget(self.folder)
        self.output=''
        row=QHBoxLayout();layout.addLayout(row);row.addWidget(QLabel('Convert / tool'))
        self.target=QComboBox();self.target.addItems(OPERATIONS);row.addWidget(self.target,1)
        self.wheel.selected.connect(self.target.setCurrentText)
        self.target.currentTextChanged.connect(self.wheel.set_current)
        self.wheel.set_current(self.target.currentText())
        self.width=QSpinBox();self.width.setRange(0,10000);self.width.setSpecialValueText('Original size');self.width.setSuffix(' px max side');self.width.setAccessibleName('Maximum image side in pixels');row.addWidget(self.width)
        self.rotate=QComboBox();self.rotate.addItems(['No rotation','90° clockwise','180°','270° clockwise']);row.addWidget(self.rotate)
        self.target.currentTextChanged.connect(self.update_options);self.update_options()
        row=QHBoxLayout();layout.addLayout(row)
        self.convert=QPushButton('Convert files');self.convert.setStyleSheet('background:#ff610a;color:#101010;font-weight:bold;padding:12px;');self.convert.clicked.connect(self.start);row.addWidget(self.convert)
        self.cancel=QPushButton('Cancel');self.cancel.setEnabled(False);self.cancel.clicked.connect(self.cancel_batch);row.addWidget(self.cancel)
        self.open=QPushButton('Open output folder');self.open.setEnabled(False);self.open.clicked.connect(self.open_output);row.addWidget(self.open)
        self.progress=QProgressBar();self.progress.setValue(0);layout.addWidget(self.progress)
        self.status=QLabel('Ready. Up to 100 files per batch; 100 MiB per input.');self.status.setWordWrap(True);self.status.setTextFormat(Qt.PlainText);layout.addWidget(self.status)
        row=QHBoxLayout();layout.addLayout(row)
        ff=QPushButton('Set FFmpeg…');ff.clicked.connect(self.set_ffmpeg);row.addWidget(ff)
        updates=QPushButton('Downloads / updates');updates.clicked.connect(lambda:QDesktopServices.openUrl(QUrl(WEBSITE+'?platform=desktop&version='+VERSION+'#desktop')));row.addWidget(updates)
        limits=QPushButton('Supported features');limits.clicked.connect(self.show_limits);row.addWidget(limits)
        layout.addWidget(QLabel('Sintax Error Private Limited · GPL-3.0-only · v'+VERSION))
        self.shift_wheel=None
        if os.name=='nt' and global_wheel and '--smoke-test' not in sys.argv:
            from windows_wheel import WindowsShiftWheel
            self.shift_wheel=WindowsShiftWheel(self)
            self.shift_toggle=QCheckBox('Enable experimental Shift drag wheel in Explorer / Desktop')
            self.shift_toggle.setChecked(self.settings.value('shiftWheel', False, type=bool))
            self.shift_wheel.set_enabled(self.shift_toggle.isChecked())
            self.shift_toggle.toggled.connect(self.toggle_shift_wheel)
            layout.addWidget(self.shift_toggle)
    def toggle_shift_wheel(self, enabled):
        self.settings.setValue('shiftWheel',enabled)
        self.shift_wheel.set_enabled(enabled)
    def update_options(self):
        enabled=self.target.currentText() in ['PNG','JPEG','WEBP','TIFF','BMP','Image → PDF'];self.width.setEnabled(enabled);self.rotate.setEnabled(enabled)
    def add_paths(self,paths):
        if self.batch and self.batch.isRunning():return
        errors=[]
        for raw in paths:
            try:
                p=str(source_file(raw))
                if p in self.paths:continue
                if len(self.paths)>=100:raise ValueError('Batch limit: 100 files.')
                self.paths.append(p);self.list.addItem(Path(p).name)
            except Exception as e:errors.append(str(e))
        self.status.setText('; '.join(errors[:3]) if errors else f'{len(self.paths)} files ready.')
    def pick(self): self.add_paths(QFileDialog.getOpenFileNames(self,'Select files')[0])
    def clear_files(self):self.paths=[];self.list.clear();self.outputs=[];self.open.setEnabled(False);self.status.setText('Ready.')
    def choose_folder(self):
        folder=QFileDialog.getExistingDirectory(self,'Choose output folder')
        if folder:self.output=folder;self.folder.setText('Output: '+Path(folder).name)
    def set_ffmpeg(self):
        path=QFileDialog.getOpenFileName(self,'Select FFmpeg from a trusted installation')[0]
        if path:
            self.settings.setValue('ffmpeg',str(Path(path).resolve()));self.status.setText('FFmpeg selected. It runs only when you request media conversion.')
    def ffmpeg_path(self):return self.settings.value('ffmpeg','')
    def show_limits(self):
        QMessageBox.information(self,'Trial capabilities','Images: PNG, JPEG, WebP, TIFF, BMP output; PNG/JPEG/WebP/TIFF/BMP/AVIF input. Resize and rotate. Single-frame only; 40 megapixels. HEIC and SVG are not supported in this trial.\n\nPDF: image to PDF, merge (up to 200 pages), split and extract text. No OCR or password-protected PDFs.\n\nWord: .docx body and table text to plain text, or to a text-only PDF in Helvetica (Latin text only). Formatting, images, hidden text, headers, footers and notes are not kept. No .doc, macro-enabled or encrypted files.\n\nMedia: MP4/WebM/MP3/WAV/FLAC/Ogg using a separately selected FFmpeg. Codecs depend on your installation. No FFmpeg download is performed.\n\nSimple SRT/VTT conversion and SHA-256 checksums.\n\nWorkers have time/output limits but are not an operating-system security sandbox. Process trusted files. Archives and the Mac notch are not included. Windows offers an opt-in Explorer/Desktop Shift drag wheel and tray mode; Linux uses the app window. Failed files do not stop the batch.')
    def start(self):
        if not self.paths or (self.batch and self.batch.isRunning()):return
        self.batch_errors=[]
        self.outputs=[];self.open.setEnabled(False);self.progress.setValue(0)
        for button in (self.add,self.clear,self.folder,self.convert,self.target,self.wheel):button.setEnabled(False)
        self.cancel.setEnabled(True);self.status.setText('Converting…')
        self.batch=Batch(list(self.paths),self.target.currentText(),{'output':self.output,'width':self.width.value(),'rotation':self.rotate.currentIndex()*90,'ffmpeg':self.ffmpeg_path()})
        self.batch.result.connect(self.result);self.batch.progress.connect(lambda n,total:self.progress.setValue(round(n/total*100)));self.batch.finished.connect(self.finished);self.batch.start()
        if self.background:self.background.started()
    def result(self,index,status,outputs):
        if status!='Done':self.batch_errors.append(status)
        self.outputs.extend(outputs)
        indexes=range(len(self.paths)) if self.batch and self.batch.target=='Merge PDFs' else [index]
        for i in indexes:
            item=self.list.item(i)
            if item:item.setText(Path(self.paths[i]).name+' — '+status);item.setToolTip('\n'.join(outputs) or status)
        self.status.setText(status);self.open.setEnabled(bool(self.outputs))
    def finished(self):
        for button in (self.add,self.clear,self.folder,self.convert,self.target,self.wheel):button.setEnabled(True)
        self.cancel.setEnabled(False);self.status.setText(f'Finished: {len(self.outputs)} output file(s). Check each row for failures or cancellation.');self.update_options()
        if self.background:self.background.finished()
    def cancel_batch(self):
        if self.batch:self.batch.cancel.set();self.status.setText('Cancelling… Completed outputs will be kept.')
    def open_output(self):
        if self.outputs:QDesktopServices.openUrl(QUrl.fromLocalFile(str(Path(self.outputs[-1]).parent)))
    def request_quit(self):
        self.quitting=True
        self.close()
    def closeEvent(self,event):
        if self.background and not self.quitting:
            self.hide();event.ignore();return
        if self.batch and self.batch.isRunning():
            self.batch.cancel.set();event.ignore();self.status.setText('Stopping conversion before closing…');QTimer.singleShot(200,self.close)
        else:
            if self.shift_wheel:self.shift_wheel.stop()
            if self.background:
                self.background.stop()
                QApplication.instance().quit()
            event.accept()

def background_startup(arguments, windows=None):
    if windows is None:windows=os.name=='nt'
    return '--window' not in arguments and '--smoke-test' not in arguments and any(flag in arguments for flag in ('--background','--headless'))

def main():
    if os.name=='nt' and getattr(sys,'frozen',False):
        import ctypes
        handle=ctypes.windll.kernel32.GetConsoleWindow()
        if handle: ctypes.windll.user32.ShowWindow(handle,0)
    app=QApplication(sys.argv);app.setStyle('Fusion');app.setStyleSheet('QWidget{background:#171717;color:#f5f3ed;font-size:13px} QPushButton,QComboBox,QSpinBox{padding:8px;border:1px solid #666;border-radius:6px} QPushButton:disabled{color:#888} QListWidget{background:#222;border:2px dashed #777;border-radius:10px;padding:8px} QProgressBar{border:1px solid #666;border-radius:4px;text-align:center} QProgressBar::chunk{background:#ff610a}')
    window=Window()
    background=background_startup(sys.argv)
    explicit_background=any(flag in sys.argv for flag in ('--background','--headless')) and '--window' not in sys.argv
    if os.name=='nt' and '--smoke-test' not in sys.argv:
        from background import BackgroundController
        try:
            window.background=BackgroundController(window)
        except RuntimeError as error:
            if explicit_background:
                if window.shift_wheel:window.shift_wheel.stop()
                print(str(error),file=sys.stderr);return 2
            background=False
    if background and not window.background and '--smoke-test' not in sys.argv:
        print('Background wheel mode is supported on Windows with a system tray.',file=sys.stderr)
        return 2
    if not background:window.show()
    if '--smoke-test' in sys.argv:QTimer.singleShot(400,app.quit)
    return app.exec()
if __name__=='__main__':raise SystemExit(main())
