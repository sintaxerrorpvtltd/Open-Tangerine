(function(root){
'use strict';
const version='0.2.3';
const tag='desktop-v'+version,base='https://github.com/sintaxerrorpvtltd/Open-Tangerine/releases/download/'+tag+'/';
function assetFor(release,platform){
 if(!release||release.draft||release.tag_name!==tag||!['Windows','Linux'].includes(platform))return null;
 const name='Open-Tangerine-'+version+'-'+platform+'-x64.'+(platform==='Windows'?'zip':'tar.gz');
 return (release.assets||[]).find(a=>a.name===name&&a.state==='uploaded'&&a.browser_download_url===base+name)||null;
}
if(typeof module!=='undefined'){module.exports={assetFor,version};return;}
async function load(){
 const status=document.getElementById('desktop-status');if(!status)return;
 const c=new AbortController(),timer=setTimeout(()=>c.abort(),8000);
 try{
  const response=await fetch('https://api.github.com/repos/sintaxerrorpvtltd/Open-Tangerine/releases/tags/'+tag,{signal:c.signal,headers:{Accept:'application/vnd.github+json'}});
  if(!response.ok)throw Error('Not published');const release=await response.json();
  const win=assetFor(release,'Windows'),linux=assetFor(release,'Linux');if(!win||!linux)throw Error('Packages incomplete');
  for(const [id,asset,label] of [['windows-download',win,'Download Windows x64 ZIP'],['linux-download',linux,'Download Linux x64 tar.gz']]){
   const a=document.getElementById(id);a.href=asset.browser_download_url;a.textContent=label+' ↓';a.removeAttribute('aria-disabled');
  }
  const current=new URLSearchParams(location.search);status.textContent=current.get('platform')==='desktop'&&current.get('version')===version?'You have desktop trial '+version+', the version offered here. Updates are installed manually.':'Desktop trial '+version+' packages are available. Feature coverage differs from the Mac app.';
 }catch{status.textContent='Windows/Linux packages are being verified or could not be checked. Browse releases for the current availability; no unverified download is offered here.';}
 finally{clearTimeout(timer);}
}
load();
})(typeof window!=='undefined'?window:this);
