"""Plain text to a searchable PDF with the built-in Helvetica font (WinAnsi, Latin text only)."""
import re
import unicodedata

PAGE_BREAK = '\f'
PAGE_WIDTH, PAGE_HEIGHT, MARGIN = 595.28, 841.89, 72
SIZE, LEADING, TAB, COLUMN_GAP = 11, 14.5, 36, 12
MAX_PAGES = 200
# Invisible characters that need no glyph, and hyphen/minus variants WinAnsi lacks.
DROP = dict.fromkeys(map(ord, '\u00ad\u200b\u200c\u200d\u2060\ufeff'))
DROP.update({0x2010: '-', 0x2011: '-', 0x2212: '-'})


class TextPdfError(ValueError): pass


def widths():
    # Adobe Core-14 Helvetica metrics as shipped by pypdf (already a dependency).
    from pypdf._codecs.core_font_metrics import CORE_FONT_METRICS
    table = dict(CORE_FONT_METRICS['Helvetica'].character_widths)
    table.setdefault('\u00a0', table[' '])
    return table


def fold(char):
    """Compatibility forms such as ligatures or styled math letters fold to Latin when they can."""
    try:
        char.encode('cp1252')
        return char
    except UnicodeEncodeError:
        folded = unicodedata.normalize('NFKC', char)
        try:
            folded.encode('cp1252')
            return folded
        except UnicodeEncodeError:
            return char


def clean(line):
    line = line.translate(DROP)
    return ''.join(fold(c) for c in line if c == '\t' or unicodedata.category(c) != 'Cc')


def check_latin(lines):
    for line in lines:
        for char in line:
            if char != '\t':
                try:
                    char.encode('cp1252')
                except UnicodeEncodeError:
                    raise TextPdfError(f'This document contains text outside Western European Latin '
                                       f'(“{char}”, U+{ord(char):04X}). Text-only PDF supports Latin text in this '
                                       'trial; use DOCX → Text instead.') from None


def layout(lines, table=None):
    """Wrap lines into pages of (x, y, text) runs using real glyph widths."""
    table = table or widths()
    default = table.get('default', 556)
    measure = lambda text: sum(table.get(c, default) for c in text) * SIZE / 1000
    usable = PAGE_WIDTH - 2 * MARGIN
    pages, runs = [], []
    y = PAGE_HEIGHT - MARGIN - SIZE

    def new_page():
        nonlocal runs, y
        pages.append(runs); runs = []; y = PAGE_HEIGHT - MARGIN - SIZE
        if len(pages) >= MAX_PAGES:
            raise TextPdfError(f'The text needs more than {MAX_PAGES} PDF pages.')

    def place(x, text):
        # Pages open only when text lands on them, so no empty trailing page.
        if y < MARGIN:
            new_page()
        runs.append((MARGIN + x, y, text))

    def next_line():
        nonlocal y
        y -= LEADING

    def aligned_stops(block):
        """One x per column for consecutive tabbed lines, or None when they cannot fit the page."""
        rows = [[cell.strip(' ') for cell in clean(line).split('\t')] for line in block]
        columns = max(len(cells) for cells in rows)
        width = [max((measure(cells[i]) for cells in rows if i < len(cells)), default=0) for i in range(columns)]
        stops = []
        for i in range(columns - 1):
            stops.append((stops[-1] if stops else 0) + width[i] + COLUMN_GAP)
        if any(stops[len(cells) - 2] + measure(cells[-1]) > usable for cells in rows if len(cells) > 1):
            return None
        return stops

    # Table rows arrive as consecutive tab-separated lines; align each run as a block.
    line_stops, block = [None] * len(lines), []
    for i, line in enumerate(lines + [PAGE_BREAK]):
        if line != PAGE_BREAK and '\t' in line:
            block.append(i); continue
        if block:
            stops = aligned_stops([lines[j] for j in block])
            for j in block: line_stops[j] = stops
            block = []

    for line, stops in zip(lines, line_stops):
        if line == PAGE_BREAK:
            new_page(); continue
        x, wrapped, column = 0.0, False, 0
        # Aligned rows keep each cell whole; other lines wrap word by word.
        for token in re.findall(r'\t|[^\t]+' if stops is not None else r'\t| +|[^\t ]+', clean(line)):
            if token == '\t':
                if stops is not None:
                    # A real space keeps cells apart for copy and search, whatever the gap.
                    if runs and runs[-1][1] == y and not runs[-1][2].endswith(' '):
                        runs[-1] = runs[-1][:2] + (runs[-1][2] + ' ',)
                    x = stops[column]; column += 1
                    continue
                x = (int(x // TAB) + 1) * TAB
                if x >= usable:
                    next_line(); x = 0.0
                continue
            if stops is not None:
                # Aligned blocks were checked to fit, so each cell is one run.
                cell = token.strip(' ')
                if cell:
                    place(x, cell)
                continue
            if token.startswith(' '):
                if x or not wrapped:
                    x += measure(token)
                continue
            while token:
                width = measure(token)
                if x + width <= usable:
                    place(x, token); x += width; break
                if x:
                    next_line(); x, wrapped = 0.0, True; continue
                # A single word wider than the page is split at the margin.
                cut = 1
                while cut < len(token) and measure(token[:cut + 1]) <= usable:
                    cut += 1
                place(0, token[:cut]); token = token[cut:]
                next_line(); wrapped = True
        next_line()
    pages.append(runs)
    return pages


def literal(text):
    out = []
    for byte in text.encode('cp1252'):
        if byte in b'()\\':
            out.append('\\' + chr(byte))
        elif 32 <= byte < 127:
            out.append(chr(byte))
        else:
            out.append('\\%03o' % byte)
    return '(' + ''.join(out) + ')'


def write_text_pdf(lines, target):
    from pypdf import PdfWriter
    from pypdf.generic import ContentStream, DictionaryObject, NameObject
    lines = [clean(line) if line != PAGE_BREAK else line for line in lines]
    check_latin(lines)
    pages = layout(lines)
    writer = PdfWriter()
    font = DictionaryObject({NameObject('/Type'): NameObject('/Font'), NameObject('/Subtype'): NameObject('/Type1'),
                             NameObject('/BaseFont'): NameObject('/Helvetica'),
                             NameObject('/Encoding'): NameObject('/WinAnsiEncoding')})
    for runs in pages:
        page = writer.add_blank_page(PAGE_WIDTH, PAGE_HEIGHT)
        page[NameObject('/Resources')] = DictionaryObject(
            {NameObject('/Font'): DictionaryObject({NameObject('/F1'): font})})
        content = ContentStream(None, writer)
        content.set_data(''.join(f'BT /F1 {SIZE} Tf {x:.2f} {y:.2f} Td {literal(text)} Tj ET\n'
                                 for x, y, text in runs).encode('ascii'))
        page.replace_contents(content)
        page.compress_content_streams()
    with open(target, 'wb') as f:
        writer.write(f)
    return len(pages)
