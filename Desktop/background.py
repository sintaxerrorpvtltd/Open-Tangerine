"""Tray lifecycle for a Windows desktop session with no main window."""
from PySide6.QtCore import QObject
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon, QStyle, QPushButton


class BackgroundController(QObject):
    def __init__(self, window):
        super().__init__(window)
        if not QSystemTrayIcon.isSystemTrayAvailable():
            raise RuntimeError('Background mode requires an available system tray.')
        self.window = window
        icon = window.windowIcon()
        if icon.isNull():
            icon = window.style().standardIcon(QStyle.SP_ComputerIcon)
        self.tray = QSystemTrayIcon(icon, self)
        self.tray.setToolTip('Open Tangerine · Ready')
        self.menu = QMenu(window)
        self.status = self.menu.addAction('Ready'); self.status.setEnabled(False)
        self.menu.addSeparator()
        self.menu.addAction('Open Open Tangerine', self.show_window)
        self.menu.addAction('Run in background', window.hide)
        self.output = self.menu.addAction('Open output folder', window.open_output)
        self.output.setEnabled(False)
        self.cancel = self.menu.addAction('Cancel conversion', window.cancel_batch)
        self.cancel.setEnabled(False)
        if window.shift_wheel:
            self.shift = self.menu.addAction('Enable Shift wheel')
            self.shift.setCheckable(True)
            self.shift.setChecked(window.shift_toggle.isChecked())
            self.shift.toggled.connect(window.shift_toggle.setChecked)
            window.shift_toggle.toggled.connect(self.shift.setChecked)
        self.menu.addSeparator()
        self.menu.addAction('Quit', window.request_quit)
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.activated)
        self.tray.messageClicked.connect(self.show_window)
        self.tray.show()
        button = QPushButton('Run in background', window)
        button.clicked.connect(window.hide)
        window.centralWidget().layout().addWidget(button)
        QApplication.instance().setQuitOnLastWindowClosed(False)

    def activated(self, reason):
        if reason == QSystemTrayIcon.DoubleClick:
            self.show_window()

    def show_window(self):
        self.window.showNormal(); self.window.raise_(); self.window.activateWindow()

    def started(self):
        label = 'Converting to ' + self.window.target.currentText() + '…'
        self.status.setText(label); self.tray.setToolTip('Open Tangerine · ' + label)
        self.cancel.setEnabled(True); self.output.setEnabled(False)

    def finished(self):
        count = len(self.window.outputs)
        errors = self.window.batch_errors
        cancelled = bool(self.window.batch and self.window.batch.cancel.is_set())
        label = f'{count} output file(s)' + (f' · {len(errors)} failed/cancelled' if errors else ' · Cancelled' if cancelled else ' · Done')
        self.status.setText(label); self.tray.setToolTip('Open Tangerine · ' + label)
        self.cancel.setEnabled(False); self.output.setEnabled(bool(count))
        # The progress island already shows this result; avoid a second notification.
        island = self.window.island
        if not self.window.isVisible() and not (island and island.handles(self.window.batch)):
            detail = (errors[0][:240] if errors else 'Saved to ' + str(self.window.outputs[-1])) if (errors or count) else 'Conversion cancelled.'
            self.tray.showMessage('Open Tangerine · ' + label, detail,
                                  QSystemTrayIcon.Warning if errors else QSystemTrayIcon.Information)

    def stop(self):
        self.tray.hide()
