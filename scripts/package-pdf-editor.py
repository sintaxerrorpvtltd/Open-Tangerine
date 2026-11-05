"""Install our pinned, unmodified upstream distribution; customize only the viewer entry."""
import hashlib, pathlib, sys, zipfile
root = pathlib.Path(__file__).resolve().parents[1]
src = root / 'Vendor/PDFJS/pdfjs.zip'
if hashlib.sha256(src.read_bytes()).hexdigest() != '55138aa33b5f1f6f68809895338b947f395f344eb6381d424b2420d6daa6a844':
    sys.exit('Unexpected PDF.js distribution hash')
dest = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(src) as z:
    for item in z.infolist():
        if not item.filename.endswith(('.map', '.pdf')): z.extract(item, dest)
entry = dest / 'web/viewer.html'
html = entry.read_text().replace("connect-src *", "connect-src 'self'").replace('<script src="viewer.mjs"', '<script src="local-options.js"></script>\n  <script src="viewer.mjs"')
entry.write_text(html)
(dest / 'web/local-options.js').write_text("""document.addEventListener('webviewerloaded', () => {
  const options = window.PDFViewerApplicationOptions;
  options.set('disablePreferences', true);
  options.set('enableScripting', false);
  options.set('enablePermissions', true);
  options.set('enableGuessAltText', false);
  options.set('enableAltTextModelDownload', false);
  options.set('enableSignatureEditor', true);
});""")
