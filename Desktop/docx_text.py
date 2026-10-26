"""Bounded DOCX body/table text extraction. Formatting, images and notes are not kept."""
import posixpath
import zipfile
import xml.etree.ElementTree as ET


class DocxError(ValueError): pass


MAX_MEMBERS = 2000
MAX_PART = 1024 * 1024
MAX_DOCUMENT = 32 * 1024 * 1024
MAX_TEXT = 16 * 1024 * 1024
PAGE_BREAK = '\f'
MAIN_TYPES = {
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml',
}
MACRO_TYPES = {
    'application/vnd.ms-word.document.macroEnabled.main+xml',
    'application/vnd.ms-word.template.macroEnabledTemplate.main+xml',
}
OFFICE_DOCUMENT = ('http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument',
                   'http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument')
# Transitional and Strict WordprocessingML.
WORD_NAMESPACES = ('http://schemas.openxmlformats.org/wordprocessingml/2006/main',
                   'http://purl.oclc.org/ooxml/wordprocessingml/main')
# Images, text boxes and their duplicate fallbacks, deleted revisions and field codes.
SKIPPED = {'drawing', 'pict', 'object', 'AlternateContent', 'del', 'moveFrom', 'delText',
           'instrText', 'footnoteReference', 'endnoteReference', 'commentReference', 'rPr', 'pPr'}


def local(tag):
    return tag.rsplit('}', 1)[-1]


def read_part(archive, name, limit):
    """Read at most limit bytes; never trust the declared size in the ZIP header."""
    try:
        info = archive.getinfo(name)
    except KeyError:
        raise DocxError('This is not a Word document: required part ' + name + ' is missing.') from None
    if info.flag_bits & 0x1:
        raise DocxError('Encrypted ZIP entries are not supported.')
    if info.file_size > limit:
        raise DocxError('The Word document is too large to extract safely.')
    with archive.open(info) as part:
        data = part.read(limit + 1)
    if len(data) > limit:
        raise DocxError('The Word document is too large to extract safely.')
    return data


def parse(data):
    # DOCX parts never need a DTD; refusing one rules out entity expansion.
    if b'<!DOCTYPE' in data or b'<!ENTITY' in data:
        raise DocxError('Word documents with DTD or entity declarations are not supported.')
    try:
        return ET.fromstring(data)
    except ET.ParseError as e:
        raise DocxError('The Word document XML is damaged.') from e


def main_part(archive):
    types = parse(read_part(archive, '[Content_Types].xml', MAX_PART))
    rels = parse(read_part(archive, '_rels/.rels', MAX_PART))
    target = next((r.get('Target', '') for r in rels if local(r.tag) == 'Relationship'
                   and r.get('Type') in OFFICE_DOCUMENT and r.get('TargetMode') != 'External'), '')
    name = posixpath.normpath(target.lstrip('/'))
    if not target or name.startswith('..') or '\\' in target or ':' in name:
        raise DocxError('This is not a Word document: no main document part.')
    try:
        archive.getinfo(name)
    except KeyError:
        raise DocxError('This is not a Word document: required part ' + name + ' is missing.') from None
    declared = {o.get('PartName', '').lstrip('/'): o.get('ContentType', '')
                for o in types if local(o.tag) == 'Override'}
    # Without an Override, OPC assigns the type by extension.
    defaults = {d.get('Extension', '').lower(): d.get('ContentType', '')
                for d in types if local(d.tag) == 'Default'}
    kind = declared.get(name) or defaults.get(posixpath.splitext(name)[1][1:].lower(), '')
    if kind in MACRO_TYPES:
        raise DocxError('Macro-enabled Word documents are not supported.')
    if kind not in MAIN_TYPES:
        raise DocxError('This is not a Word .docx document.')
    return name


def switched_on(properties, flag):
    """True when a run/paragraph property such as w:vanish is present and not set to false."""
    if properties is None:
        return False
    element = next((c for c in properties if local(c.tag) == flag), None)
    if element is None:
        return False
    return next((v for k, v in element.attrib.items() if local(k) == 'val'), 'true') not in ('0', 'false', 'off')


def paragraph_text(paragraph):
    """Text of one paragraph in document order, skipping SKIPPED subtrees and hidden runs."""
    out = []
    stack = [iter(paragraph)]
    while stack:
        element = next(stack[-1], None)
        if element is None:
            stack.pop(); continue
        name = local(element.tag)
        if name in SKIPPED:
            continue
        # Hidden text stays hidden, as in Word's own PDF export.
        if name == 'r' and switched_on(next((c for c in element if local(c.tag) == 'rPr'), None), 'vanish'):
            continue
        if name == 't':
            out.append(element.text or '')
        elif name == 'tab':
            out.append('\t')
        elif name == 'br':
            kind = next((v for k, v in element.attrib.items() if local(k) == 'type'), '')
            out.append(PAGE_BREAK if kind == 'page' else '\n')
        elif name == 'cr':
            out.append('\n')
        elif name == 'noBreakHyphen':
            out.append('-')
        elif name == 'softHyphen':
            out.append('\u00ad')
        elif name == 'p':
            # A paragraph nested in a run-level container keeps its own line.
            out.append('\n')
            stack.append(iter(element))
        else:
            stack.append(iter(element))
    return ''.join(out)


def page_break_before(paragraph):
    return switched_on(next((c for c in paragraph if local(c.tag) == 'pPr'), None), 'pageBreakBefore')


def flatten_cell(cell):
    """One cell as a single line; nested tables are flattened in reading order."""
    parts = []
    stack = [iter(cell)]
    while stack:
        element = next(stack[-1], None)
        if element is None:
            stack.pop(); continue
        name = local(element.tag)
        if name == 'p':
            text = paragraph_text(element).replace(PAGE_BREAK, ' ')
            parts.append(' '.join(text.replace('\t', ' ').split()))
        elif name not in SKIPPED:
            stack.append(iter(element))
    return ' '.join(p for p in parts if p)


def table_rows(table):
    rows = []
    stack = [iter(table)]
    while stack:
        element = next(stack[-1], None)
        if element is None:
            stack.pop(); continue
        name = local(element.tag)
        if name == 'tr':
            cells = []
            row_stack = [iter(element)]
            while row_stack:
                child = next(row_stack[-1], None)
                if child is None:
                    row_stack.pop(); continue
                if local(child.tag) == 'tc':
                    cells.append(flatten_cell(child))
                elif local(child.tag) in ('sdt', 'sdtContent', 'customXml'):
                    row_stack.append(iter(child))
            rows.append('\t'.join(cells).rstrip('\t'))
        elif name in ('sdt', 'sdtContent', 'customXml'):
            stack.append(iter(element))
    return rows


def extract_docx(path):
    """Return body paragraphs and table rows as lines; PAGE_BREAK lines mark page breaks."""
    with open(path, 'rb') as f:
        head = f.read(8)
    if head.startswith(b'\xd0\xcf\x11\xe0'):
        raise DocxError('Password-protected or legacy .doc files are not supported; save as an unprotected .docx.')
    try:
        archive = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError) as e:
        raise DocxError('This is not a valid .docx file.') from e
    with archive:
        if len(archive.infolist()) > MAX_MEMBERS:
            raise DocxError('The Word document has too many parts to extract safely.')
        root = parse(read_part(archive, main_part(archive), MAX_DOCUMENT))
    if local(root.tag) != 'document' or root.tag[1:].split('}')[0] not in WORD_NAMESPACES:
        raise DocxError('This is not a Word .docx document.')
    body = next((c for c in root if local(c.tag) == 'body'), None)
    if body is None:
        raise DocxError('The Word document has no body.')
    lines, size = [], 0

    def add(new):
        nonlocal size
        size += sum(len(line) + 1 for line in new)
        if size > MAX_TEXT:
            raise DocxError('Extracted text is too large.')
        lines.extend(new)

    stack = [iter(body)]
    while stack:
        element = next(stack[-1], None)
        if element is None:
            stack.pop(); continue
        name = local(element.tag)
        if name == 'p':
            if page_break_before(element) and lines:
                add([PAGE_BREAK])
            pieces = paragraph_text(element).split(PAGE_BREAK)
            for i, piece in enumerate(pieces):
                add(piece.split('\n') + ([PAGE_BREAK] if i < len(pieces) - 1 else []))
        elif name == 'tbl':
            add(table_rows(element))
        elif name in ('sdt', 'sdtContent', 'customXml', 'ins', 'moveTo'):
            stack.append(iter(element))
    while lines and lines[-1] in ('', PAGE_BREAK):
        lines.pop()
    return lines
