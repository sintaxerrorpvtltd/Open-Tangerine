import json,os,subprocess,tempfile
from pathlib import Path
from PIL import Image
root=Path(__file__).resolve().parent
exe=root/'dist/OpenTangerine'/('OpenTangerine.exe' if os.name=='nt' else 'OpenTangerine')
subprocess.run([str(exe),'--smoke-test'],check=True,timeout=30)
with tempfile.TemporaryDirectory() as folder:
 p=Path(folder)/'input.png';Image.new('RGB',(20,20),'orange').save(p)
 r=subprocess.run([str(exe),'--worker'],input=json.dumps({'paths':[str(p)],'target':'JPEG','output':folder}),text=True,capture_output=True,timeout=30)
 # A Windows --windowed executable has no standard streams. Build uses console
 # mode so the conversion worker protocol remains available on both platforms.
 if r.returncode!=0:raise RuntimeError(r.stderr or r.stdout)
 data=json.loads(r.stdout);assert data['ok'];out=Path(data['outputs'][0])
 with Image.open(out) as im:assert im.size==(20,20)
print('PASS: packaged GUI launch and actual PNG to JPEG worker conversion')

# Exercise the FFmpeg subprocess under the packaged worker's Linux resource limits.
import shutil
ff=shutil.which('ffmpeg')
if ff:
 with tempfile.TemporaryDirectory() as folder:
  clip=Path(folder)/'clip.mp4'
  subprocess.run([ff,'-nostdin','-v','error','-f','lavfi','-i','testsrc2=s=640x480:r=25','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','3','-threads','1','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac',str(clip)],check=True,timeout=30)
  result=subprocess.run([str(exe),'--worker'],input=json.dumps({'paths':[str(clip)],'target':'MP4','output':folder,'ffmpeg':str(Path(ff).resolve())}),text=True,capture_output=True,timeout=60)
  assert result.returncode==0,result.stdout+result.stderr
  data=json.loads(result.stdout);assert data['ok']
  subprocess.run([ff,'-nostdin','-v','error','-xerror','-threads','1','-i',data['outputs'][0],'-f','null','-'],check=True,timeout=30)
 print('PASS: packaged video conversion and full output decode')

# DOCX parsing and the PDF writer load lazily inside the frozen worker.
import sys
sys.path.insert(0,str(root/'tests'))
from docx_fixtures import write_docx,para,run
from pypdf import PdfReader
with tempfile.TemporaryDirectory() as folder:
 p=write_docx(Path(folder)/'input.docx',para(run('Packaged DOCX check'))+para(run('Second page'),page_before=True))
 r=subprocess.run([str(exe),'--worker'],input=json.dumps({'paths':[str(p)],'target':'DOCX → PDF (text only)','output':folder}),text=True,capture_output=True,timeout=30)
 if r.returncode!=0:raise RuntimeError(r.stderr or r.stdout)
 data=json.loads(r.stdout);assert data['ok'];pdf=PdfReader(data['outputs'][0])
 assert len(pdf.pages)==2 and 'Packaged DOCX check' in pdf.pages[0].extract_text(),data
print('PASS: packaged DOCX to text-only PDF worker conversion')
