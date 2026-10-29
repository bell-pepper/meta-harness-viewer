'use strict';
let setup;
let cursor = '';
let parent = '';
const $ = id => document.getElementById(id);
function message(text) { $('status').textContent = text; }
async function api(path, method='GET', body) {
 const response = await fetch(path, {method, credentials:'same-origin', headers:{'Content-Type':'application/json', ...(method !== 'GET' ? {'X-CSRF-Token':setup.csrf} : {})}, body:body === undefined ? undefined : JSON.stringify(body)});
 const data = await response.json();
 if (!response.ok) throw new Error(typeof data.detail === 'string' ? data.detail : 'Request failed. Refresh this page and try again.');
 return data;
}
function task(fn) { return async () => { try { await fn(); } catch(e) { message(e.message); } }; }
async function refresh() {
 setup = await api('/api/setup');
 $('signed-out').hidden = !!setup.account;
 $('signed-in').hidden = !setup.account;
 $('signin').disabled = !setup.configured;
 if (!setup.configured) {message('The administrator must configure Google sign-in before this service can connect accounts.');return;}
 if (!setup.account) {message(new URL(location.href).searchParams.has('error') ? 'Google sign-in was cancelled. You can try again.' : 'Sign in to choose your private folder.');return;}
 $('account').textContent = setup.account.name;
 $('selected').textContent = setup.account.folder_name ? 'Selected folder: '+setup.account.folder_name : 'No folder selected yet.';
 $('pair').disabled = !setup.account.folder;
 $('devices').replaceChildren();
 for (const [i,device] of setup.devices.entries()) {
  const row = document.createElement('div');row.className='row';
  const label = document.createElement('span');label.textContent=`Glasses ${i+1} · paired ${new Date(device.created*1000).toLocaleDateString()}`;
  const button=document.createElement('button');button.textContent='Revoke';button.onclick=task(async()=>{await api('/api/setup/devices/'+encodeURIComponent(device.id),'DELETE');await refresh();message('Glasses access revoked.');});
  row.append(label,button);$('devices').append(row);
 }
 if (!setup.devices.length) $('devices').textContent='No glasses paired yet.';
 message('Choose a folder, then enter the code from your glasses.');
}
async function folders(append=false) {
 const data=await api('/api/folders?'+new URLSearchParams({parent,cursor:append?cursor:''}));
 if(!append)$('folders').replaceChildren();
 for(const folder of data.files||[]) {
  const row=document.createElement('div');row.className='row';
  const label=document.createElement('span');label.textContent=folder.name;
  const select=document.createElement('button');select.textContent='Select';select.setAttribute('aria-label','Select '+folder.name);
  select.onclick=task(async()=>{await api('/api/folder','POST',{folder_id:folder.id});await refresh();message('Folder selected: '+folder.name);});
  const browse=document.createElement('button');browse.textContent='Open';browse.onclick=task(async()=>{parent=folder.id;await folders();});
  row.append(label,select,browse);$('folders').append(row);
 }
 cursor=data.nextPageToken||'';$('more').hidden=!cursor;
 if(!data.files?.length&&!append)$('folders').textContent='No folders here. Paste a folder link above, or reload this page to browse all folders.';
}
$('signin').onclick=task(async()=>{const data=await api('/auth/start','POST');location.assign(data.url);});
$('use-link').onclick=task(async()=>{
 const url=new URL($('folder-url').value.trim());
 const match=url.pathname.match(/\/folders\/([A-Za-z0-9_-]+)/);
 if(url.protocol!=='https:'||url.hostname!=='drive.google.com'||!match)throw new Error('Paste a Google Drive folder link.');
 const result=await api('/api/folder','POST',{folder_id:match[1]});await refresh();message('Folder selected: '+result.folder);
});
$('pair').onclick=task(async()=>{const code=$('code').value.trim().toUpperCase().replace(/[-\s]/g,'');if(!/^[A-Z2-9]{8}$/.test(code))throw new Error('Enter the eight-character code shown on your glasses.');await api('/api/pair/claim','POST',{code});$('code').value='';await refresh();message('Glasses paired. Return to the glasses to open your documents.');});
$('more').onclick=task(()=>folders(true));
$('disconnect').onclick=task(async()=>{if(!confirm('Disconnect this Google account and revoke all its paired glasses?'))return;const result=await api('/api/disconnect','POST');await refresh();message(result.google_revoked?'Google access and paired glasses disconnected.':'Server access and paired glasses disconnected. Google could not confirm token revocation; you can also remove Harness HUD in your Google Account connections.');});
task(async()=>{await refresh();if(setup.account)await folders();})();
