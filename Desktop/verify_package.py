"""Verify release bytes and required notices/source inside the actual archive."""
import hashlib, json, os, struct, tarfile, zipfile
from pathlib import Path
from engine import VERSION
root=Path(__file__).resolve().parent
platform='Windows-x64.zip' if os.name=='nt' else 'Linux-x64.tar.gz'
p=root/'dist'/f'Open-Tangerine-{VERSION}-{platform}'
assert p.with_name(p.name+'.sha256').read_text().split()[0]==hashlib.sha256(p.read_bytes()).hexdigest()
if os.name=='nt':
    with zipfile.ZipFile(p) as archive:
        names=archive.namelist()
        for executable, subsystem in [('OpenTangerine.exe',2),('OpenTangerineWorker.exe',3)]:
            data=archive.read('OpenTangerine/'+executable)
            assert data[:2]==b'MZ',executable
            pe=struct.unpack_from('<I',data,0x3c)[0]
            assert data[pe:pe+4]==b'PE\0\0',executable
            assert struct.unpack_from('<H',data,pe+24+68)[0]==subsystem,executable+' has wrong console/GUI subsystem'
        assert 'OpenTangerine/source/Desktop/windows.spec' in names
else:
    with tarfile.open(p) as archive:names=archive.getnames()
for name in ['licenses/explicit/LGPL-3.0-only.txt','licenses/explicit/Python-3.12-LICENSE.txt','licenses/Open-Tangerine-GPL-3.0.txt','THIRD_PARTY_NOTICES.md','source/THIRD_PARTY_NOTICES.md','source/Desktop/engine.py','source/Desktop/licenses/LGPL-3.0-only.txt']:
    assert 'OpenTangerine/'+name in names,name
print('PASS: archive checksum, explicit notices and rebuildable source')
