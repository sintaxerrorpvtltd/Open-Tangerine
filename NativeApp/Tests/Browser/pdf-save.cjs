// macOS 26 CI has no visible WindowServer for WKWebView. Drive a real browser
// viewport over private pipes (no debugging port, no sandbox disable switch).
const {spawn} = require('node:child_process');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const profile = fs.mkdtempSync(path.join(os.tmpdir(),'ot-editor-ci-'));
const chrome = spawn(process.env.OT_TEST_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ['--headless','--remote-debugging-pipe','--no-first-run','--disable-background-networking','--user-data-dir='+profile,'about:blank'],
  {stdio:['ignore','ignore','inherit','pipe','pipe']});
let seq=0, buf='', pending=new Map();
function send(method,params={},sessionId){
  return new Promise((resolve,reject)=>{let id=++seq;pending.set(id,{resolve,reject});chrome.stdio[3].write(JSON.stringify({id,method,params,sessionId})+'\0');});
}
chrome.stdio[4].setEncoding('utf8');
chrome.stdio[4].on('data',chunk=>{buf+=chunk;let end;while((end=buf.indexOf('\0'))>=0){
  const msg=JSON.parse(buf.slice(0,end));buf=buf.slice(end+1);const p=pending.get(msg.id);
  if(p){pending.delete(msg.id);msg.error?p.reject(Error(msg.error.message)):p.resolve(msg.result);}
}});
function stop(err){for(const p of pending.values())p.reject(err);pending.clear();}
chrome.on('error',stop);chrome.on('exit',()=>stop(Error('Browser exited')));
const timer=setTimeout(()=>{console.error('PDF browser smoke timed out');chrome.kill();process.exitCode=1;},45000);
(async()=>{
  const {targetId}=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  async function evaluate(expression){let r=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},sessionId);
    if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description||r.exceptionDetails.text);return r.result.value;}
  await send('Page.navigate',{url:process.argv[2]},sessionId);
  for(let i=0;i<100;i++){
    if(await evaluate("!!document.querySelector('[name=SampleField]')"))break;
    await new Promise(r=>setTimeout(r,250));
  }
  const bytes=await evaluate(`(async()=>{
    if(PDFViewerApplicationOptions.get('enableScripting')!==false)throw Error('PDF scripting enabled');
    for(const id of ['editorHighlightButton','editorFreeTextButton','editorInkButton'])if(!document.getElementById(id))throw Error(id);
    const field=document.querySelector('[name=SampleField]');if(!field||!field.getBoundingClientRect().width||field.value!=='Original')throw Error('Editable field did not render');
    field.focus();field.value='Edited locally';field.dispatchEvent(new Event('input',{bubbles:true}));field.blur();
    return btoa(Array.from(await PDFViewerApplication.pdfDocument.saveDocument(),x=>String.fromCharCode(x)).join(''));
  })()`);
  fs.writeFileSync(process.argv[3],Buffer.from(bytes,'base64'),{flag:'wx'});
})().catch(e=>{console.error(e.message);process.exitCode=1;}).finally(()=>{clearTimeout(timer);chrome.kill();});
chrome.on('close',()=>{try{fs.rmSync(profile,{recursive:true,force:true});}catch{}});
