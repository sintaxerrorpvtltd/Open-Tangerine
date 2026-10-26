import os
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from docx_fixtures import write_docx, document, para, run, SAMPLE_BODY, MAIN
import docx_text
from docx_text import extract_docx, DocxError, PAGE_BREAK
import text_pdf
from text_pdf import layout, write_text_pdf, TextPdfError, PAGE_WIDTH, MARGIN, SIZE
from engine import convert, ConversionError, DOCX_OUTPUTS
from runner import run_job

SAMPLE_LINES = ['Quarterly report', 'Revenue\tgrew 12%', 'second line', 'Kept inserted', 'a link', 'after box',
                'Name\tScore', 'Ada\t97 (top)', 'Inside a content control', PAGE_BREAK, 'Next page']


class DocxTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory(); self.root = Path(self.dir.name)

    def tearDown(self):
        self.dir.cleanup()

    def docx(self, body='', name='doc.docx', **kw):
        return write_docx(self.root/name, body, **kw)

    def test_body_tables_and_revisions(self):
        # Insertions kept, deletions, field codes and text-box duplicates dropped.
        self.assertEqual(extract_docx(self.docx(SAMPLE_BODY)), SAMPLE_LINES)

    def test_hidden_text_is_not_extracted(self):
        # Word leaves hidden (w:vanish) runs out of its own PDF export; so does this.
        hidden = '<w:r><w:rPr><w:vanish/></w:rPr><w:t>secret</w:t></w:r>'
        shown = '<w:r><w:rPr><w:vanish w:val="false"/></w:rPr><w:t>shown</w:t></w:r>'
        self.assertEqual(extract_docx(self.docx(para(run('visible '), hidden, shown))), ['visible shown'])

    def test_strict_ooxml_namespace(self):
        xml = document(para(run('strict')), ns='http://purl.oclc.org/ooxml/wordprocessingml/main')
        self.assertEqual(extract_docx(self.docx(xml=xml)), ['strict'])

    def test_main_part_type_from_default_extension(self):
        # Valid OPC: the main part's type comes from a Default, not an Override (POI 55733.docx).
        source = self.docx(para(run('TEST')))
        with zipfile.ZipFile(source) as z: parts = {n: z.read(n) for n in z.namelist()}
        parts['[Content_Types].xml'] = ('\ufeff<?xml version="1.0" encoding="utf-8"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            f'<Default Extension="xml" ContentType="{MAIN}"/>'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '</Types>').encode('utf-8')
        with zipfile.ZipFile(source, 'w') as z:
            for name, data in parts.items(): z.writestr(name, data)
        self.assertEqual(extract_docx(source), ['TEST'])

    def test_worker_text_output_preserves_original_and_never_overwrites(self):
        source = self.docx(SAMPLE_BODY, name='report.docx'); before = source.read_bytes()
        (self.root/'report-converted.txt').write_text('existing', encoding='utf8')
        out = run_job({'paths': [str(source)], 'target': 'DOCX → Text'})
        self.assertEqual(Path(out[0]).name, 'report-converted-2.txt')
        self.assertEqual(Path(out[0]).read_text(encoding='utf8'),
                         '\n'.join('' if l == PAGE_BREAK else l for l in SAMPLE_LINES) + '\n')
        self.assertEqual((self.root/'report-converted.txt').read_text(encoding='utf8'), 'existing')
        self.assertEqual(source.read_bytes(), before)

    def test_worker_pdf_output_is_searchable_helvetica(self):
        from pypdf import PdfReader
        source = self.docx(SAMPLE_BODY, name='report.docx'); before = source.read_bytes()
        out = run_job({'paths': [str(source)], 'target': 'DOCX → PDF (text only)'})
        pdf = PdfReader(out[0])
        self.assertEqual(len(pdf.pages), 2)
        first, second = (page.extract_text() for page in pdf.pages)
        for text in ('Quarterly report', 'grew 12%', 'Kept inserted', 'Ada', '97 (top)'):
            self.assertIn(text, first)
        self.assertNotIn('deleted', first); self.assertNotIn('PAGE', first)
        self.assertEqual(first.count('box text'), 0)
        self.assertIn('Next page', second)
        font = pdf.pages[0]['/Resources']['/Font']['/F1']
        self.assertEqual((font['/BaseFont'], font['/Encoding']), ('/Helvetica', '/WinAnsiEncoding'))
        self.assertEqual(source.read_bytes(), before)

    def test_latin_characters_and_pdf_escaping(self):
        from pypdf import PdfReader
        text = 'Café (draft) \\ 50 € – naïve “quotes” ® :-)'
        out = self.root/'latin.pdf'
        write_text_pdf([text], out)
        self.assertEqual(PdfReader(out).pages[0].extract_text().strip(), text)

    def test_compatibility_characters_fold_to_latin_in_pdf(self):
        from pypdf import PdfReader
        out = self.root/'folded.pdf'
        write_text_pdf(['ﬁnal ﬂow 𝑆um ＡＢＣ 5 − 3 non‑breaking'], out)
        self.assertEqual(PdfReader(out).pages[0].extract_text().strip(), 'final flow Sum ABC 5 - 3 non-breaking')
        with self.assertRaisesRegex(TextPdfError, r'U\+010C'):
            write_text_pdf(['Český'], self.root/'czech.pdf')

    def test_non_latin_text_rejected_for_pdf_but_kept_in_text(self):
        source = self.docx(para(run('Hello नमस्ते 中文')))
        with self.assertRaisesRegex(ConversionError, r'U\+0928.*DOCX → Text'):
            convert({'paths': [str(source)], 'target': 'DOCX → PDF (text only)'})
        self.assertEqual(list(self.root.glob('*.pdf')), [])
        out = convert({'paths': [str(source)], 'target': 'DOCX → Text'})
        self.assertEqual(Path(out[0]).read_text(encoding='utf8'), 'Hello नमस्ते 中文\n')

    def test_rejects_dtd_and_entities(self):
        bomb = ('<?xml version="1.0"?><!DOCTYPE w:document [<!ENTITY a "aaaaaaaaaa">'
                '<!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>' + document(para(run('&b;'))).split('?>', 1)[1])
        with self.assertRaisesRegex(DocxError, 'DTD or entity'):
            extract_docx(self.docx(xml=bomb))

    def test_rejects_wrong_or_hostile_packages(self):
        cases = {
            'macro': (dict(kind='application/vnd.ms-word.document.macroEnabled.main+xml'), 'Macro-enabled'),
            'slides': (dict(kind='application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml'), 'not a Word'),
            'traversal': (dict(target='../../evil.xml'), 'no main document part'),
            'backslash': (dict(target='word\\document.xml'), 'no main document part'),
            'missing': (dict(target='word/missing.xml'), 'missing'),
            'not word xml': (dict(xml='<?xml version="1.0"?><html><body/></html>'), 'not a Word'),
            'damaged xml': (dict(xml='<w:document'), 'damaged'),
        }
        for label, (kw, message) in cases.items():
            with self.subTest(label), self.assertRaisesRegex(DocxError, message):
                extract_docx(self.docx(para(run('x')), name=label + '.docx', **kw))

    def test_rejects_external_main_relationship(self):
        source = self.docx(para(run('x')))
        with zipfile.ZipFile(source) as z: parts = {n: z.read(n) for n in z.namelist()}
        parts['_rels/.rels'] = parts['_rels/.rels'].replace(b'Target=', b'TargetMode="External" Target=')
        with zipfile.ZipFile(source, 'w') as z:
            for name, data in parts.items(): z.writestr(name, data)
        with self.assertRaisesRegex(DocxError, 'no main document part'):
            extract_docx(source)

    def test_rejects_encrypted_legacy_and_corrupt_files(self):
        legacy = self.root/'locked.docx'; legacy.write_bytes(b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1' + b'\0' * 512)
        with self.assertRaisesRegex(DocxError, 'Password-protected or legacy'):
            extract_docx(legacy)
        corrupt = self.root/'corrupt.docx'; corrupt.write_bytes(b'PK\x03\x04 not really a zip')
        with self.assertRaisesRegex(DocxError, 'not a valid .docx'):
            extract_docx(corrupt)

    def test_size_and_member_limits_use_actual_bytes(self):
        # Highly compressible body: a few KiB on disk, but over the (patched) limit once inflated.
        bomb = self.docx(para(run(' ' * 300_000)))
        self.assertLess(bomb.stat().st_size, 20_000)
        with patch.object(docx_text, 'MAX_DOCUMENT', 100_000), self.assertRaisesRegex(DocxError, 'too large'):
            extract_docx(bomb)
        many = self.docx(para(run('x')), name='many.docx', extra={f'custom/{i}.xml': '<a/>' for i in range(20)})
        with patch.object(docx_text, 'MAX_MEMBERS', 10), self.assertRaisesRegex(DocxError, 'too many parts'):
            extract_docx(many)
        with patch.object(docx_text, 'MAX_TEXT', 50), self.assertRaisesRegex(DocxError, 'Extracted text is too large'):
            extract_docx(self.docx(''.join(para(run('twenty characters...')) for _ in range(5)), name='text.docx'))

    def test_deep_nesting_is_iterative(self):
        depth = 3000
        body = '<w:sdt><w:sdtContent>' * depth + para(run('deep')) + '</w:sdtContent></w:sdt>' * depth
        self.assertEqual(extract_docx(self.docx(body)), ['deep'])

    def test_no_text_reports_what_is_skipped(self):
        source = self.docx(para('<w:r><w:drawing/></w:r>'))
        with self.assertRaisesRegex(ConversionError, 'images, text boxes, headers and footers'):
            convert({'paths': [str(source)], 'target': 'DOCX → Text'})

    def test_engine_requires_docx_suffix(self):
        source = self.docx(para(run('x')), name='old.doc')
        for target in DOCX_OUTPUTS:
            with self.subTest(target), self.assertRaisesRegex(ConversionError, 'Word .docx'):
                convert({'paths': [str(source)], 'target': target})

    def test_wrapping_stays_inside_margins_without_empty_pages(self):
        metrics = text_pdf.widths()
        words = ' '.join(['interoperability', 'of', 'local-first', 'converters'] * 1500)
        pages = layout([words, 'x' * 400, '\tindented\tcolumns'])
        self.assertGreater(len(pages), 3)
        self.assertTrue(all(pages))
        for runs in pages:
            for x, y, text in runs:
                right = x + sum(metrics.get(c, 556) for c in text) * SIZE / 1000
                self.assertLessEqual(right, PAGE_WIDTH - MARGIN + 0.01, text)
                self.assertGreaterEqual(y, MARGIN)
        joined = ''.join(text for runs in pages for _, _, text in runs)
        # The 400-character word is split at the margin, not lost.
        self.assertEqual(joined.count('x'), 400)

    def test_table_columns_align_across_rows(self):
        rows = ['Phase\tScope\tBudget', '1\tGround floor\t€48,500', '2\tFirst floor\t€61,200']
        runs = layout(['Intro paragraph'] + rows + ['After'])[0]
        x = {text.strip(): left for left, _, text in runs}
        self.assertEqual(x['Scope'], x['Ground floor'])
        self.assertEqual(x['Scope'], x['First floor'])
        self.assertEqual(x['Budget'], x['€48,500'])
        self.assertEqual(x['Budget'], x['€61,200'])
        self.assertGreater(x['Budget'], x['Scope'])
        # Narrow columns still extract as separate words: a real space ends each cell before a tab
        # (Poppler merged 'a' and 'b' from POI WithTabs.docx without it).
        self.assertEqual([t for _, _, t in layout(['a\tb', 'c\td'])[0]], ['a ', 'b', 'c ', 'd'])
        from pypdf import PdfReader
        out = self.root/'narrow.pdf'; write_text_pdf(['a\tb', 'c\td'], out)
        self.assertEqual(PdfReader(out).pages[0].extract_text().split(), ['a', 'b', 'c', 'd'])
        # A block too wide for aligned columns falls back to fixed tab stops.
        wide = layout(['a' * 60 + '\tb', 'c\t' + 'd' * 60])[0]
        self.assertEqual([t[:1] for _, _, t in wide], ["a", "b", "c", "d"])
        self.assertEqual(wide[3][0] - MARGIN, 36)

    def test_page_breaks_and_page_limit(self):
        self.assertEqual(len(layout(['one', PAGE_BREAK, 'two', PAGE_BREAK, 'three'])), 3)
        with self.assertRaisesRegex(TextPdfError, 'more than 200'):
            layout(['line'] * (49 * 201))

    def test_failed_file_does_not_stop_batch(self):
        from PySide6.QtCore import QEventLoop, QTimer
        from PySide6.QtWidgets import QApplication
        from app import Window
        app = QApplication.instance() or QApplication([])
        bad = self.root/'bad.docx'; bad.write_bytes(b'not a zip at all')
        good = self.docx(para(run('fine')), name='good.docx')
        window = Window(global_wheel=False); window.add_paths([str(bad), str(good)])
        window.target.setCurrentText('DOCX → Text'); window.start()
        loop = QEventLoop(); window.batch.finished.connect(loop.quit)
        QTimer.singleShot(20000, loop.quit); loop.exec(); app.processEvents()
        self.assertEqual(len(window.outputs), 1)
        self.assertEqual(Path(window.outputs[0]).read_text(encoding='utf8'), 'fine\n')
        self.assertEqual(len(window.batch_errors), 1)
        self.assertIn('not a valid .docx', window.batch_errors[0])
        window.close()

    def test_core_font_metrics_still_available(self):
        # Guards the private pypdf module used for Helvetica widths; fails loudly after an upgrade.
        table = text_pdf.widths()
        self.assertEqual((table[' '], table['W'], table['\u00a0']), (278, 944, 278))


if __name__ == '__main__':
    unittest.main()
