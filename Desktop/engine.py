"""Local conversion engine. No shell, network clients, deletion of inputs or archive extraction."""
from __future__ import annotations
import errno, hashlib, json, os, re, shutil, stat, subprocess, tempfile, time, warnings
from pathlib import Path

VERSION = '0.2.2'
MAX_BYTES = 100 * 1024 * 1024
MAX_PIXELS = 40_000_000
MAX_OUTPUT = 512 * 1024 * 1024
IMAGE_INPUTS = {'.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tif', '.tiff', '.avif'}
IMAGE_OUTPUTS = {'PNG': 'png', 'JPEG': 'jpg', 'WEBP': 'webp', 'TIFF': 'tiff', 'BMP': 'bmp'}
MEDIA_INPUTS = {'.mp4': 'mov', '.mov': 'mov', '.m4v': 'mov', '.mkv': 'matroska', '.webm': 'matroska', '.mp3': 'mp3', '.wav': 'wav', '.flac': 'flac', '.ogg': 'ogg', '.m4a': 'mov', '.aac': 'aac'}
MEDIA_OUTPUTS = {'MP4': ('mp4', ['-c:v','libx264','-preset','fast','-crf','23','-c:a','aac','-movflags','+faststart']), 'WEBM': ('webm',['-c:v','libvpx-vp9','-deadline','realtime','-cpu-used','6','-c:a','libopus']), 'MP3': ('mp3',['-vn','-c:a','libmp3lame','-b:a','192k']), 'WAV': ('wav',['-vn','-c:a','pcm_s16le']), 'FLAC': ('flac',['-vn','-c:a','flac']), 'OGG': ('ogg',['-vn','-c:a','libvorbis'])}
DOCX_OUTPUTS = {'DOCX → Text': 'txt', 'DOCX → PDF (text only)': 'pdf'}
OPERATIONS = list(IMAGE_OUTPUTS) + ['Image → PDF', 'PDF → Text', 'Merge PDFs', 'Split PDF', *DOCX_OUTPUTS, 'SRT → VTT', 'VTT → SRT', 'SHA-256'] + list(MEDIA_OUTPUTS)
class ConversionError(ValueError): pass

def source_file(raw):
    p=Path(raw).expanduser()
    # Reject devices, symlinks, Windows reparse points and remote UNC paths.
    if not p.is_absolute(): raise ConversionError('Select an absolute local file path.')
    if os.name=='nt' and (str(p).startswith('\\\\') or str(p).startswith('//')): raise ConversionError('Network paths are not supported.')
    s=p.lstat()
    if not stat.S_ISREG(s.st_mode) or p.is_symlink() or getattr(s,'st_file_attributes',0)&0x400:
        raise ConversionError('Select a regular file, not a folder, shortcut or device.')
    if s.st_size==0 or s.st_size>MAX_BYTES: raise ConversionError('Files must be nonempty and no larger than 100 MiB.')
    return checked_resolve(p, s)

def checked_resolve(path, before):
    """Detect replacement during canonicalization; not a filesystem sandbox."""
    resolved=path.resolve(strict=True)
    after=path.lstat();actual=resolved.stat()
    if (before.st_dev,before.st_ino)!=(after.st_dev,after.st_ino) or (before.st_dev,before.st_ino)!=(actual.st_dev,actual.st_ino) or stat.S_ISLNK(after.st_mode) or getattr(after,'st_file_attributes',0)&0x400:
        raise ConversionError('Path changed while being checked; select it again.')
    return resolved

def output_folder(raw):
    folder=Path(raw)
    if not folder.is_absolute():raise ConversionError('Choose an absolute local output folder.')
    info=folder.lstat()
    if not stat.S_ISDIR(info.st_mode) or getattr(info,'st_file_attributes',0)&0x400:
        raise ConversionError('Choose a real local output folder; symbolic links and shortcuts are not supported.')
    return checked_resolve(folder,info)

def publish(stage, folder, stem, suffix):
    """Never overwrite. Prefer atomic hardlink; exclusive copy supports removable disks."""
    if not stage.is_file() or not 0<stage.stat().st_size<=MAX_OUTPUT: raise ConversionError('Empty or oversized output.')
    stem=re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', stem).rstrip('. ')[:100] or 'converted'
    if stem.upper() in {'CON','PRN','AUX','NUL',*[f'COM{i}' for i in range(1,10)],*[f'LPT{i}' for i in range(1,10)]}: stem='file-'+stem
    for n in range(1,10001):
        target=folder/(stem+('-'+str(n) if n>1 else '')+'.'+suffix)
        try:
            os.link(stage,target)
            return str(target)
        except FileExistsError: continue
        except OSError as e:
            if e.errno not in (errno.EPERM,errno.EOPNOTSUPP,errno.EXDEV,errno.ENOSYS):
                raise ConversionError('Cannot write to the output folder. Check permissions and free space.') from e
            try:
                fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_BINARY',0),0o600)
            except FileExistsError:continue
            identity=os.fstat(fd)
            try:
                with os.fdopen(fd,'wb') as out, stage.open('rb') as source:
                    shutil.copyfileobj(source,out,1024*1024)
                    out.flush();os.fsync(out.fileno())
                return str(target)
            except BaseException:
                # Remove only the incomplete file this call created, never a replacement.
                try:
                    current=target.lstat()
                    if (current.st_dev,current.st_ino)==(identity.st_dev,identity.st_ino):target.unlink()
                except OSError:pass
                raise
    raise ConversionError('Too many existing output names; choose another folder.')

def open_image(p):
    from PIL import Image, ImageOps
    Image.MAX_IMAGE_PIXELS=MAX_PIXELS
    warnings.simplefilter('error', Image.DecompressionBombWarning)
    with Image.open(p) as im:
        if im.width*im.height>MAX_PIXELS: raise ConversionError('Image exceeds 40 megapixels.')
        if getattr(im,'n_frames',1)!=1: raise ConversionError('Animated or multipage images are not supported; use a single-frame image.')
        im.load()
        result=ImageOps.exif_transpose(im).copy()
    return result

def read_pdf(p):
    from pypdf import PdfReader
    pdf=PdfReader(str(p),strict=False)
    if pdf.is_encrypted: raise ConversionError('Password-protected PDFs are not supported.')
    if not 0<len(pdf.pages)<=200: raise ConversionError('PDFs must contain 1–200 pages.')
    return pdf

def media(p, stage, target, ffmpeg):
    if not ffmpeg: raise ConversionError('Choose a trusted FFmpeg executable in Settings for audio/video conversion.')
    exe=Path(ffmpeg)
    if not exe.is_absolute() or not exe.is_file() or exe.is_symlink(): raise ConversionError('FFmpeg must be an existing absolute executable path.')
    if p.suffix.lower() not in MEDIA_INPUTS: raise ConversionError('Unsupported media input; playlists and URLs are not accepted.')
    ext,args=MEDIA_OUTPUTS[target]
    # Input demuxer selected explicitly; network protocols unavailable to the job.
    cmd=[str(exe),'-nostdin','-hide_banner','-loglevel','error','-n','-protocol_whitelist','file,pipe','-threads','1','-filter_threads','1','-filter_complex_threads','1','-f',MEDIA_INPUTS[p.suffix.lower()],'-i',str(p),'-map_metadata','-1','-threads','1',*args,'-fs',str(MAX_OUTPUT),'-f',ext,str(stage)]
    with tempfile.TemporaryFile() as log:
        proc=subprocess.Popen(cmd,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=log)
        start=time.monotonic()
        try:
            while proc.poll() is None:
                if time.monotonic()-start>150 or log.tell()>65536 or (stage.exists() and stage.stat().st_size>=MAX_OUTPUT):
                    raise ConversionError('Media job exceeded its time, output or diagnostic limit.')
                time.sleep(.05)
            if proc.returncode:
                log.seek(0);detail=log.read(2000).decode('utf8','replace')
                raise ConversionError(('FFmpeg reached a memory/thread resource limit. Try a smaller file. ' if 'pthread_create' in detail or 'Cannot allocate memory' in detail else 'FFmpeg could not convert this file; check the file and installed codecs. ')+detail[-500:])
        finally:
            if proc.poll() is None: proc.kill()
            proc.wait()
    if stage.stat().st_size>=MAX_OUTPUT: raise ConversionError('Output exceeded 512 MiB; no partial file was published.')

def convert(job):
    target=job.get('target')
    if target not in OPERATIONS: raise ConversionError('Unsupported operation.')
    raws=job.get('paths',[])
    if not isinstance(raws,list) or not 1<=len(raws)<=100: raise ConversionError('Select 1–100 files.')
    paths=[source_file(p) for p in raws]
    if target!='Merge PDFs' and len(paths)!=1: raise ConversionError('Each conversion job accepts one input; use the batch queue.')
    folder=output_folder(job.get('output') or paths[0].parent)
    work_root=folder
    if job.get('_work_root'):
        work_root=output_folder(job['_work_root'])
        if work_root.parent!=folder or not work_root.name.startswith('.opentangerine-job-'):
            raise ConversionError('Invalid job staging folder.')
    p=paths[0]; stem=p.stem+'-converted';results=[]
    with tempfile.TemporaryDirectory(prefix='.opentangerine-',dir=work_root) as work:
        stage=Path(work)/'output'
        if target in IMAGE_OUTPUTS or target=='Image → PDF':
            if p.suffix.lower() not in IMAGE_INPUTS: raise ConversionError('This operation requires a supported image.')
            from PIL import Image
            im=open_image(p)
            try:
                width=int(job.get('width',0));rotation=int(job.get('rotation',0));quality=int(job.get('quality',90))
                if not 0<=width<=10000 or rotation not in (0,90,180,270) or not 1<=quality<=100: raise ConversionError('Invalid image options.')
                if width: im.thumbnail((width,width),Image.Resampling.LANCZOS)
                if rotation: im=im.rotate(-rotation,expand=True)
                if target in ('JPEG','BMP','Image → PDF'):
                    rgba=im.convert('RGBA');base=Image.new('RGB',rgba.size,'white');base.paste(rgba,mask=rgba.getchannel('A'));im=base
                elif im.mode not in ('RGB','RGBA','L','LA'): im=im.convert('RGBA')
                # Drop ancillary metadata; this is not a certified anonymizer.
                im.info.clear()
                fmt='PDF' if target=='Image → PDF' else target
                im.save(stage,format=fmt,quality=quality)
                ext='pdf' if fmt=='PDF' else IMAGE_OUTPUTS[target]
                results.append(publish(stage,folder,stem,ext))
            finally: im.close()
        elif target in ('PDF → Text','Merge PDFs','Split PDF'):
            if any(x.suffix.lower()!='.pdf' for x in paths): raise ConversionError('Select only PDF files.')
            from pypdf import PdfWriter
            if target=='Merge PDFs':
                writer=PdfWriter();total=0
                for path in paths:
                    pdf=read_pdf(path);total+=len(pdf.pages)
                    if total>200: raise ConversionError('Merged PDF cannot exceed 200 pages.')
                    for page in pdf.pages: writer.add_page(page)
                with stage.open('wb') as f: writer.write(f)
                results.append(publish(stage,folder,'merged','pdf'))
            else:
                pdf=read_pdf(p)
                if target=='PDF → Text':
                    with stage.open('w',encoding='utf8') as f:
                        for page in pdf.pages:
                            f.write(page.extract_text() or '');f.write('\n')
                            if f.tell()>MAX_OUTPUT: raise ConversionError('Extracted text is too large.')
                    results.append(publish(stage,folder,stem,'txt'))
                else:
                    # Prepare all pages before publishing; no output before parser success.
                    pieces=[]
                    for i,page in enumerate(pdf.pages):
                        item=Path(work)/str(i);w=PdfWriter();w.add_page(page)
                        with item.open('wb') as f:w.write(f)
                        pieces.append(item)
                        if sum(x.stat().st_size for x in pieces)>MAX_OUTPUT: raise ConversionError('Split outputs exceed 512 MiB.')
                    for i,item in enumerate(pieces):results.append(publish(item,folder,f'{p.stem}-page-{i+1}','pdf'))
        elif target in DOCX_OUTPUTS:
            if p.suffix.lower()!='.docx': raise ConversionError('Select a Word .docx document.')
            from docx_text import extract_docx, DocxError, PAGE_BREAK
            from text_pdf import write_text_pdf, TextPdfError
            try:
                lines=extract_docx(p)
                if not any(line.strip() for line in lines if line!=PAGE_BREAK):
                    raise ConversionError('No body or table text found; images, text boxes, headers and footers are not extracted.')
                if target=='DOCX → Text':
                    with stage.open('w',encoding='utf8',newline='\n') as f:
                        f.write('\n'.join('' if line==PAGE_BREAK else line for line in lines)+'\n')
                else:write_text_pdf(lines,stage)
            except (DocxError,TextPdfError) as e: raise ConversionError(str(e)) from e
            results.append(publish(stage,folder,stem,DOCX_OUTPUTS[target]))
        elif target in MEDIA_OUTPUTS:
            media(p,stage,target,job.get('ffmpeg',''));results.append(publish(stage,folder,stem,MEDIA_OUTPUTS[target][0]))
        elif target=='SHA-256':
            h=hashlib.sha256()
            with p.open('rb') as f:
                for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
            if any(c in p.name for c in ('\n','\r','\\')):
                raise ConversionError('Rename this file without newlines or backslashes before creating a checksum.')
            stage.write_text(h.hexdigest()+'  '+p.name+'\n',encoding='utf8')
            results.append(publish(stage,folder,p.stem,'sha256'))
        else:
            expected='.srt' if target=='SRT → VTT' else '.vtt'
            if p.suffix.lower()!=expected or p.stat().st_size>5*1024*1024: raise ConversionError('Select a matching subtitle file under 5 MiB.')
            value=p.read_text(encoding='utf-8-sig');value=value.replace('\r\n','\n')
            if target=='SRT → VTT':
                if '-->' not in value: raise ConversionError('No subtitle timestamps found.')
                lines=value.splitlines()
                for i,line in enumerate(lines):
                    if '-->' not in line:continue
                    m=re.fullmatch(r'((?:\d{2,}:)?\d{2}:\d{2}),([0-9]{3}) --> ((?:\d{2,}:)?\d{2}:\d{2}),([0-9]{3})',line)
                    if not m:raise ConversionError('Only simple SRT timestamps are supported.')
                    times=[]
                    for t,ms in ((m[1],m[2]),(m[3],m[4])):
                        if any(int(v)>59 for v in t.split(':')[-2:]):raise ConversionError('Invalid subtitle timestamp.')
                        times.append(('00:'+t if t.count(':')==1 else t)+'.'+ms)
                    lines[i]=' --> '.join(times)
                value='\n'.join(lines)+'\n'
                value='WEBVTT\n\n'+value;ext='vtt'
            else:
                if not value.startswith('WEBVTT') or '-->' not in value: raise ConversionError('Invalid WebVTT file.')
                blocks=value.split('\n\n')[1:];out=[]
                for block in blocks:
                    lines=block.strip().splitlines();stamp=next((i for i,l in enumerate(lines) if '-->' in l),None)
                    if stamp is None: continue
                    timing=lines[stamp]
                    # Cue settings/styles are deliberately not silently discarded.
                    m=re.fullmatch(r'((?:\d{2}:)?\d{2}:\d{2}\.\d{3}) --> ((?:\d{2}:)?\d{2}:\d{2}\.\d{3})',timing)
                    if not m: raise ConversionError('Only simple WebVTT cues without positioning settings are supported.')
                    times=[('00:'+v if v.count(':')==1 else v).replace('.',',') for v in m.groups()]
                    out.append(str(len(out)+1)+'\n'+' --> '.join(times)+'\n'+'\n'.join(lines[stamp+1:]))
                if not out: raise ConversionError('No supported subtitle cues.')
                value='\n\n'.join(out)+'\n';ext='srt'
            stage.write_text(value,encoding='utf8');results.append(publish(stage,folder,stem,ext))
    return results

def worker_main():
    import sys
    try:
        if sys.platform.startswith('linux'):
            import resource
            resource.setrlimit(resource.RLIMIT_AS,(1536*1024*1024,1536*1024*1024))
            resource.setrlimit(resource.RLIMIT_FSIZE,(MAX_OUTPUT,MAX_OUTPUT))
            resource.setrlimit(resource.RLIMIT_CPU,(160,160))
        raw=sys.stdin.buffer.read(65537)
        if len(raw)>65536: raise ConversionError('Job request too large.')
        result={'ok':True,'outputs':convert(json.loads(raw))}
    except Exception as e: result={'ok':False,'error':str(e)[:1000] or type(e).__name__}
    print(json.dumps(result,ensure_ascii=True),flush=True)
    return 0 if result['ok'] else 1
