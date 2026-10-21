"""Validate the archive users extract, including packaged worker conversions."""
import hashlib, json, os, shutil, subprocess, tarfile, tempfile, zipfile
from pathlib import Path
from PIL import Image
from pypdf import PdfReader, PdfWriter
from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject
from engine import VERSION, IMAGE_OUTPUTS, MEDIA_OUTPUTS
from runner import run_job


def smoke_test():
    root = Path(__file__).resolve().parent
    platform = 'Windows' if os.name == 'nt' else 'Linux'
    extension = 'zip' if os.name == 'nt' else 'tar.gz'
    archive = root / 'dist' / f'Open-Tangerine-{VERSION}-{platform}-x64.{extension}'
    with archive.open('rb') as f:
        digest = hashlib.file_digest(f, 'sha256').hexdigest()
    if digest != archive.with_name(archive.name + '.sha256').read_text().split()[0]:
        raise RuntimeError('Portable archive checksum mismatch')
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg and os.environ.get('OPEN_TANGERINE_REQUIRE_FFMPEG') == '1':
        raise RuntimeError('FFmpeg is required for packaged media verification')
    kwargs = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
    with tempfile.TemporaryDirectory(prefix='Open Tangerine portable ') as folder:
        base = Path(folder).resolve() / 'App ü'
        base.mkdir()
        if os.name == 'nt':
            with zipfile.ZipFile(archive) as bundle: bundle.extractall(base)
        else:
            with tarfile.open(archive) as bundle: bundle.extractall(base, filter='data')
        package = base / 'OpenTangerine'
        exe = package / ('OpenTangerine.exe' if os.name == 'nt' else 'OpenTangerine')
        for source in root.glob('*.py'):
            if (package / 'source/Desktop' / source.name).read_bytes() != source.read_bytes():
                raise RuntimeError('Bundled application source does not match the build')
        for needed in ['_internal', 'licenses/Open-Tangerine-GPL-3.0.txt', 'dependencies.json']:
            if not (package / needed).exists(): raise RuntimeError('Package missing ' + needed)
        subprocess.run([str(exe), '--smoke-test'], check=True, timeout=30, cwd=base, **kwargs)
        files = base / 'Files ü'; files.mkdir()
        image = files / 'input ü.png'
        Image.new('RGBA', (20, 16), (255, 128, 0, 128)).save(image)
        original = image.read_bytes()
        def convert(target, paths, **options):
            outputs = run_job(dict(paths=[str(p) for p in paths], target=target, output=str(files), **options),
                              command=[str(exe), '--worker'], timeout=30)
            if not all(Path(p).is_file() and Path(p).stat().st_size for p in outputs):
                raise RuntimeError('Missing or empty output for ' + target)
            return [Path(p) for p in outputs]
        for target in IMAGE_OUTPUTS:
            output = convert(target, [image])[0]
            with Image.open(output) as im:
                im.load(); assert im.size == (20, 16)
        pdf = convert('Image → PDF', [image])[0]
        assert len(PdfReader(pdf).pages) == 1
        text_pdf = files / 'text.pdf'
        writer = PdfWriter(); page = writer.add_blank_page(100, 100)
        font = DictionaryObject({NameObject('/Type'): NameObject('/Font'), NameObject('/Subtype'): NameObject('/Type1'), NameObject('/BaseFont'): NameObject('/Helvetica')})
        page[NameObject('/Resources')] = DictionaryObject({NameObject('/Font'): DictionaryObject({NameObject('/F1'): font})})
        content = DecodedStreamObject(); content.set_data(b'BT /F1 12 Tf 5 50 Td (Open Tangerine) Tj ET')
        page[NameObject('/Contents')] = writer._add_object(content)
        with text_pdf.open('wb') as f: writer.write(f)
        assert 'Open Tangerine' in convert('PDF → Text', [text_pdf])[0].read_text(encoding='utf8')
        merged = convert('Merge PDFs', [pdf, text_pdf])[0]
        assert len(PdfReader(merged).pages) == 2
        split = convert('Split PDF', [merged]); assert len(split) == 2
        assert all(len(PdfReader(p).pages) == 1 for p in split)
        checksum = convert('SHA-256', [image])[0].read_text(encoding='utf8').split()[0]
        assert checksum == hashlib.sha256(original).hexdigest()
        subtitle = files / 'subtitle.srt'
        subtitle.write_text('1\n00:00:01,000 --> 00:00:02,000\nHello\n', encoding='utf8')
        vtt = convert('SRT → VTT', [subtitle])[0]
        assert '00:00:01,000 --> 00:00:02,000' in convert('VTT → SRT', [vtt])[0].read_text(encoding='utf8')
        # Repeated requests must retain originals and previously published files.
        previous = {p: p.read_bytes() for p in files.glob('*.jpg')}
        repeated = convert('JPEG', [image])[0]
        assert repeated not in previous
        assert all(p.read_bytes() == data for p, data in previous.items())
        assert image.read_bytes() == original
        if ffmpeg:
            media = files / 'media.mp4'
            subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=orange:s=64x64:r=12',
                            '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=24000', '-t', '0.5',
                            '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', str(media)], check=True, timeout=30, **kwargs)
            for target in MEDIA_OUTPUTS:
                output = convert(target, [media], ffmpeg=ffmpeg)[0]
                subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-xerror', '-i', str(output), '-f', 'null', '-'],
                               check=True, timeout=30, **kwargs)
        else:
            print('SKIP: packaged media conversions (FFmpeg not installed)')
    count = 18 if ffmpeg else 12
    print(f'PASS: extracted {platform} GUI, {count} packaged operations, Unicode/spaces paths, originals and existing outputs, source/licenses and archive checksum')

if __name__ == '__main__': smoke_test()
