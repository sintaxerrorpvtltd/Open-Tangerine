"""Generated .docx fixtures for tests; no real documents are committed."""
import zipfile

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
CONTENT_TYPES = ('<?xml version="1.0" encoding="UTF-8"?>'
                 '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                 '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                 '<Default Extension="xml" ContentType="application/xml"/>'
                 '<Override PartName="/word/document.xml" ContentType="{kind}"/></Types>')
RELS = ('<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
        'Target="{target}"/></Relationships>')
MAIN = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'


def para(*runs, page_before=False):
    props = '<w:pPr><w:pageBreakBefore/></w:pPr>' if page_before else ''
    return f'<w:p>{props}{"".join(runs)}</w:p>'


def run(text):
    return f'<w:r><w:t xml:space="preserve">{text}</w:t></w:r>'


def document(body, ns=W):
    return (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="{ns}" '
            'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
            'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">'
            f'<w:body>{body}<w:sectPr/></w:body></w:document>')


def write_docx(path, body='', kind=MAIN, target='word/document.xml', xml=None, extra=None, compression=zipfile.ZIP_DEFLATED):
    with zipfile.ZipFile(path, 'w', compression) as z:
        z.writestr('[Content_Types].xml', CONTENT_TYPES.format(kind=kind))
        z.writestr('_rels/.rels', RELS.format(target=target))
        z.writestr('word/document.xml', xml if xml is not None else document(body))
        for name, data in (extra or {}).items():
            z.writestr(name, data)
    return path


SAMPLE_BODY = ''.join([
    para(run('Quarterly report')),
    para(run('Revenue'), '<w:r><w:tab/></w:r>', run('grew 12%'), '<w:r><w:br/></w:r>', run('second line')),
    para(run('Kept '), '<w:ins w:id="1" w:author="a"><w:r><w:t>inserted</w:t></w:r></w:ins>',
         '<w:del w:id="2" w:author="a"><w:r><w:tab/><w:delText>deleted</w:delText><w:br/></w:r></w:del>'),
    para('<w:hyperlink w:anchor="x">' + run('a link') + '</w:hyperlink>',
         '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> PAGE </w:instrText></w:r>'),
    para('<w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><w:t>box text</w:t></w:drawing></mc:Choice>'
         '<mc:Fallback><w:pict><w:t>box text</w:t></w:pict></mc:Fallback></mc:AlternateContent></w:r>', run('after box')),
    '<w:tbl><w:tr><w:tc>' + para(run('Name')) + '</w:tc><w:tc>' + para(run('Score')) + '</w:tc></w:tr>'
    '<w:tr><w:tc>' + para(run('Ada')) + '</w:tc><w:tc>' + para(run('97')) + para(run('(top)')) + '</w:tc></w:tr></w:tbl>',
    '<w:sdt><w:sdtContent>' + para(run('Inside a content control')) + '</w:sdtContent></w:sdt>',
    para(run('Next page'), page_before=True),
])
