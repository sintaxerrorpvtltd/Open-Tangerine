# PyInstaller: GUI entry point without a console, plus a piped conversion worker.
from PyInstaller.utils.hooks import collect_all

datas, binaries, hiddenimports = collect_all('pypdf')
a = Analysis(['app.py'], pathex=[], binaries=binaries,
             datas=[('icon.png', '.')] + datas, hiddenimports=hiddenimports)
pyz = PYZ(a.pure)
gui = EXE(pyz, a.scripts, [], exclude_binaries=True,
          name='OpenTangerine', console=False)
worker = EXE(pyz, a.scripts, [], exclude_binaries=True,
             name='OpenTangerineWorker', console=True)
COLLECT(gui, worker, a.binaries, a.datas, name='OpenTangerine')
