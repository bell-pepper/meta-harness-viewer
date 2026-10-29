'use strict';
const screen = document.getElementById('screen');
const position = document.getElementById('position');
const hint = document.getElementById('hint');
const stack = [];
let route = 'home';
let step = 0;
let page = 0;
let zoom = 1;
let panX = 0;
let panY = 0;
let moving = false;
let toolsOpen = false;
let imageReady = false;
let renderID = 0;
let documents = [];
let selectedDocument = null;
let pageCount = 0;
let libraryLoading = false;
let libraryError = '';
let libraryRequest = null;
let libraryGeneration = 0;
let opening = false;
let navigationGeneration = 0;
let pageBlob = null;
let pairing = null;
let pairingError = '';
let pairTimer = null;
let pairBusy = false;
let pairGeneration = 0;
const drive = window.HarnessDrive;
async function beginPairing() {
 if(pairBusy)return;
 clearTimeout(pairTimer);
 const attempt=++pairGeneration;
 if (!drive.configured()) { pairingError = 'Private Drive service is not deployed yet. Please use the setup instructions on your phone.'; render(); return; }
 pairBusy=true;pairingError = ''; pairing = null; render();
 try {
  if (drive.paired()) { pairing = {connected:true}; pairBusy=false;if(route === 'drive') render(); return; }
  const result = await drive.startPair();
  if (route !== 'drive' || attempt !== pairGeneration) return;
  pairBusy=false;pairing = result; render(); pollPairing();
 } catch(e) { pairingError=e.message;pairBusy=false;if(route==='drive')render(); }
 finally {pairBusy=false;}
}
async function pollPairing() {
 const attempt=pairGeneration;
 clearTimeout(pairTimer);
 if(route!=='drive'||!pairing||pairing.connected)return;
 try {
  const status=await drive.status();
  if(route!=='drive'||attempt!==pairGeneration)return;
  if(status.paired){pairing={connected:true};documents=[];libraryGeneration++;render();return;}
  pairTimer=setTimeout(pollPairing,4000);
 }catch(e){pairingError=e.message;if(route==='drive')render();}
}

const catalogURL = new URL('assets/documents.json', document.baseURI);
function escapeText(value) {
 return String(value).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
}
function parseCatalog(data) {
 if (data?.version !== 1 || !Array.isArray(data.documents) || data.documents.length > 1000) throw new Error('Invalid document library.');
 const ids = new Set();
 return data.documents.map(item => {
  if (typeof item.id !== 'string' || !item.id || ids.has(item.id) || typeof item.title !== 'string' || !item.title.trim() || !Array.isArray(item.pages) || !item.pages.length || item.pages.length > 2000) throw new Error('Invalid document entry.');
  ids.add(item.id);
  const pages = item.pages.map(source => {
   if (typeof source !== 'string' || !source) throw new Error('Invalid page address.');
   const url = new URL(source, catalogURL);
   if (url.username || url.password || (url.origin !== location.origin && url.protocol !== 'https:') || !['https:', 'http:'].includes(url.protocol)) throw new Error('Unsupported page address.');
   return url.href;
  });
  return {id:item.id, title:item.title, revision:typeof item.revision === 'string' ? item.revision : '', pages};
 });
}
async function loadLibrary() {
 if (libraryRequest) return libraryRequest;
 libraryLoading = true; libraryError = '';
 const generation = libraryGeneration;
 if (route === 'documents') render();
 libraryRequest = (async () => {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  try {
   if(drive.paired()) {
    const loaded=await drive.documents();
    if(generation === libraryGeneration) documents=loaded;
    return;
   }
   const response = await fetch(catalogURL, {cache:'no-store', signal:controller.signal});
   if (!response.ok) throw new Error('Could not load the document library.');
   const loaded = parseCatalog(await response.json());
   if(generation === libraryGeneration) documents = loaded;
  } catch(e) { libraryError = drive.paired() ? e.message : 'Could not load documents. Check your connection or reconnect Drive.'; }
  finally {
   clearTimeout(timeout); libraryLoading = false; libraryRequest = null;
   if (route === 'documents') {if(generation!==libraryGeneration)loadLibrary();else render();}
  }
 })();
 return libraryRequest;
}
async function openDocument(index) {
 const selected = documents[index];
 const originalFocus=document.activeElement?.id;
 const navigation=navigationGeneration;
 if (!selected || opening) return;
 opening=true;
 try {
  let resolved=selected;
  if(selected.private) {
   libraryLoading=true;render();
   resolved=await drive.open(selected);
  }
  if(route!=='documents'||navigation!==navigationGeneration)return;
  selectedDocument = resolved; pageCount = resolved.pages.length;
  libraryLoading=false;go('reader');stack[stack.length-1].focus=originalFocus;
 } catch(e) {libraryError=e.message;libraryLoading=false;if(route==='documents')render();}
 finally {opening=false;libraryLoading=false;if(route==='documents')render();}
}
const steps = [
 ['Prepare the wire', 'Cut one sample wire to the length specified by your approved drawing.', 'Confirm wire ID and inspect the insulation.'],
 ['Strip and terminate', 'Strip to the terminal manufacturer’s specified length. Crimp with the approved tool.', 'Inspect the crimp and perform the required retention check.'],
 ['Insert and inspect', 'Insert the terminal into cavity 1 until the retention feature engages.', 'Verify cavity, terminal seating and continuity against the approved drawing.']
];
function focusButton(id) {
 const target = (id && document.getElementById(id)) || screen.querySelector('button:not(:disabled)');
 target?.focus({preventScroll:true});
 target?.scrollIntoView({block:'nearest'});
}
function go(next) {
 navigationGeneration++;
 stack.push({route, step, focus:document.activeElement?.id});
 route = next;
 if (next === 'assembly') step = 0;
 if (next === 'reader') { page = 0; resetView(); }
 render();
 if (next === 'documents' && !documents.length && !libraryLoading) loadLibrary();
 if (next === 'drive') beginPairing();
}
function back() {
 if (moving) { moving = false; toolsOpen = false; }
 if (route === 'reader' && toolsOpen) { showTools(false); return; }
 const prior = stack.pop();
 if (!prior) return;
 navigationGeneration++;
 route = prior.route; step = prior.step;
 render(prior.focus);
}
function resetView() { zoom = 1; panX = 0; panY = 0; moving = false; }
function bind() {
 screen.querySelectorAll('[data-go]').forEach(el => el.onclick = () => go(el.dataset.go));
 screen.querySelectorAll('[data-back]').forEach(el => el.onclick = back);
}
function render(focusID) {
 const id = ++renderID;
 if(pageBlob) {URL.revokeObjectURL(pageBlob);pageBlob=null;}
 if(route!=='drive')clearTimeout(pairTimer);
 moving = false;
 toolsOpen = false;
 document.getElementById('hud').classList.toggle('reading', route === 'reader');
 screen.className = route === 'reader' ? 'reader' : route === 'assembly' ? 'assembly' : '';
 position.textContent = route === 'home' ? 'HOME' : route === 'assembly' ? `${step + 1} / 3` : route === 'reader' ? `PAGE ${page + 1} / ${pageCount}` : route.toUpperCase();
 hint.textContent = 'Arrows Navigate · Enter Select · Back Return';
 if (route === 'home') screen.innerHTML = `<h1>Field reference</h1><p class="muted">Choose a workspace</p><nav aria-label="Main menu"><button id="home-pinouts" data-go="pinouts">Pinouts<small>Connector cavities & signals</small></button><button id="home-documents" data-go="documents">Documents<small>Saved datasheets · no typing</small></button><button id="home-quick" data-go="quick">Quick Reference<small>Assembly steps & checks</small></button></nav>`;
 if (route === 'pinouts') screen.innerHTML = `<h1>Connector J1</h1><p class="tag">EXAMPLE ONLY · MATING FACE</p><div class="card"><h2>4-position connector</h2><table><thead><tr><th scope="col">Pin</th><th scope="col">Signal</th><th scope="col">Wire</th></tr></thead><tbody><tr><td>1</td><td>+12 V</td><td>Red</td></tr><tr><td>2</td><td>Ground</td><td>Black</td></tr><tr><td>3</td><td>CAN H</td><td>White</td></tr><tr><td>4</td><td>CAN L</td><td>Blue</td></tr></tbody></table></div><p class="muted">Use the approved drawing for actual wiring and orientation.</p><button data-back>Back</button>`;
 if (route === 'documents') {
  screen.innerHTML = `<h1>Documents</h1>${libraryLoading ? '<p role="status">Loading documents…</p>' : libraryError ? `<p role="alert">${escapeText(libraryError)}</p>` : '<p class="muted">Choose a datasheet</p>'}<nav>${libraryError || libraryLoading ? '' : documents.map((doc, index) => `<button id="${doc.id === 'demo' ? 'demo-document' : `document-${index}`}" data-document="${index}">${escapeText(doc.title)}<small>${doc.private ? 'Private PDF' : doc.pages.length + (doc.pages.length === 1 ? ' page' : ' pages')}${doc.revision ? ` · ${escapeText(doc.revision)}` : ''}</small></button>`).join('')}${!libraryLoading ? `<button id="refresh-library">${libraryError ? 'Retry' : 'Refresh documents'}</button>` : ''}<button id="drive-connect" data-go="drive">${drive.paired() ? 'Manage Google Drive' : 'Connect Google Drive'}</button><button data-back>Back</button></nav>${!documents.length && !libraryLoading && !libraryError ? '<p class="muted">No documents are available.</p>' : ''}`;
  screen.querySelectorAll('[data-document]').forEach(el => el.onclick = () => openDocument(Number(el.dataset.document)));
  const refresh = document.getElementById('refresh-library');
  if (refresh) refresh.onclick = loadLibrary;
 }
 if(route === 'drive') {
  screen.innerHTML=`<h1>Google Drive</h1>${pairingError ? `<p role="alert">${escapeText(pairingError)}</p>` : pairing?.connected ? '<p>Your private library is connected.</p>' : pairing ? `<p>On your phone, open:</p><p class="pair-url">${escapeText(pairing.setup_url)}</p><p>Sign in, select a folder, then enter:</p><p class="pair-code">${escapeText(pairing.code)}</p><p class="muted">Code expires in 10 minutes. No typing on glasses.</p>` : '<p role="status">Preparing connection…</p>'}<nav>${pairing?.connected ? '<button id="drive-library">Open my datasheets</button><button id="drive-forget">Disconnect these glasses</button>' : `<button id="drive-retry" ${pairBusy?'disabled':''}>New pairing code</button>`}<button data-back>Back</button></nav>`;
  const retry=document.getElementById('drive-retry');if(retry)retry.onclick=beginPairing;
  const library=document.getElementById('drive-library');if(library)library.onclick=()=>{back();loadLibrary();};
  const forget=document.getElementById('drive-forget');if(forget)forget.onclick=async()=>{
   try {await drive.disconnect();}catch{}
   documents=[];libraryGeneration++;pairing=null;pairingError='';back();loadLibrary();
  };
 }
 if (route === 'quick') screen.innerHTML = `<h1>Quick Reference</h1><nav><button id="assembly" data-go="assembly">Harness assembly<small>Three example steps</small></button><button id="checks" data-go="checks">Inspection checklist<small>Before releasing a harness</small></button><button data-back>Back</button></nav>`;
 if (route === 'checks') screen.innerHTML = `<h1>Inspection</h1><ol><li>Verify drawing revision.</li><li>Check wire IDs and cavities.</li><li>Inspect crimps and strain relief.</li><li>Test continuity and isolation.</li></ol><p class="muted">Follow your approved acceptance criteria.</p><button data-back>Back</button>`;
 if (route === 'assembly') {
  const s = steps[step];
  screen.innerHTML = `<h1>${s[0]}</h1><p class="tag">EXAMPLE · STEP ${step + 1} OF 3</p><div class="card"><p>${s[1]}</p><p class="muted">Check: ${s[2]}</p></div><nav style="margin-top:12px"><button id="next">${step === 2 ? 'Finish' : 'Next step →'}</button>${step ? '<button id="previous">← Previous step</button>' : ''}<button class="compact" data-back>Back to reference</button></nav>`;
  document.getElementById('next').onclick = () => { if (step < 2) { step++; render(); } else back(); };
  const prev = document.getElementById('previous');
  if (prev) prev.onclick = () => { step--; render(); };
 }
 if (route === 'reader') renderReader(id);
 bind();
 if (route === 'reader') document.getElementById('paper').focus({preventScroll:true});
 else focusButton(focusID);
}
function renderReader(id) {
 imageReady = false;
 screen.innerHTML = `<div id="paper" tabindex="0" role="button" aria-label="Document page. Select to show controls."><img id="page-image" alt="${escapeText(selectedDocument.title)} page ${page + 1}" draggable="false"><div id="page-status" role="status">Loading page…</div></div><section id="reader-tools" aria-label="Document controls" hidden><h1>${escapeText(selectedDocument.title)} · ${page + 1}/${pageCount}</h1><p class="tag" id="view-label">${escapeText(selectedDocument.revision)} · FIT PAGE</p><div class="controls" aria-label="Page controls"><button id="prev-page" ${page === 0 ? 'disabled' : ''}>← Page</button><button id="next-page" ${page === pageCount-1 ? 'disabled' : ''}>Page →</button><button id="zoom" disabled>Zoom 2×</button><button id="fit" disabled>Fit page</button><button id="move" disabled>Move</button><button id="documents">Documents</button></div><button id="resume" class="compact">Read full screen</button></section>`;
 const image = document.getElementById('page-image');
 const status = document.getElementById('page-status');
 image.onload = () => {
  if (route !== 'reader' || renderID !== id) return;
  imageReady = true; status.hidden = true;
  document.getElementById('zoom').disabled = false;
  updateImage();
 };
 image.onerror = () => {
  if (route !== 'reader' || renderID !== id) return;
  showTools(true);
  status.textContent = 'Page could not load. Check connection, then select Retry.';
  document.getElementById('zoom').textContent = 'Retry';
  document.getElementById('zoom').disabled = false;
  document.getElementById('zoom').onclick = () => render('zoom');
 };
 if(selectedDocument.private) {
  drive.image(selectedDocument.pages[page]).then(url=>{
   if(route!=='reader'||renderID!==id){URL.revokeObjectURL(url);return;}
   pageBlob=url;image.src=url;
  }).catch(e=>{
   if(route!=='reader'||renderID!==id)return;
   image.onerror();status.textContent=e.message;
  });
 } else image.src = selectedDocument.pages[page];
 document.getElementById('prev-page').onclick = () => changePage(-1);
 document.getElementById('next-page').onclick = () => changePage(1);
 document.getElementById('zoom').onclick = () => { if (moving) setMoving(false); zoom = zoom === 1 ? 2 : zoom === 2 ? 3 : 1; panX = panY = 0; updateImage(); showTools(false); };
 document.getElementById('fit').onclick = () => { resetView(); updateImage(); showTools(false); };
 document.getElementById('move').onclick = () => showTools(false);
 document.getElementById('resume').onclick = () => showTools(false);
 document.getElementById('documents').onclick = () => { toolsOpen = false; moving = false; back(); };
 const paper = document.getElementById('paper');
 let pointer = null;
 let dragged = false;
 paper.onclick = () => { if (!dragged) showTools(!toolsOpen); };
 paper.onpointerdown = e => {
  dragged = false;
  if (!moving) return;
  pointer = {x:e.clientX, y:e.clientY};
  paper.setPointerCapture(e.pointerId);
 };
 paper.onpointermove = e => {
  if (!moving || !pointer) return;
  if (Math.abs(e.clientX-pointer.x) + Math.abs(e.clientY-pointer.y) > 2) dragged = true;
  panX += e.clientX - pointer.x; panY += e.clientY - pointer.y;
  pointer = {x:e.clientX, y:e.clientY}; updateImage();
 };
 paper.onpointerup = paper.onpointercancel = () => { pointer = null; };
}
function changePage(delta) {
 const next = Math.max(0, Math.min(pageCount - 1, page + delta));
 if (next === page) return;
 page = next; resetView(); render(delta > 0 && page < pageCount - 1 ? 'next-page' : 'prev-page');
}
function updateImage() {
 if (route !== 'reader' || !imageReady) return;
 const paper = document.getElementById('paper');
 const image = document.getElementById('page-image');
 const fit = Math.min(paper.clientWidth / image.naturalWidth, paper.clientHeight / image.naturalHeight);
 const width = image.naturalWidth * fit * zoom;
 const height = image.naturalHeight * fit * zoom;
 const maxX = Math.max(0, (width - paper.clientWidth) / 2);
 const maxY = Math.max(0, (height - paper.clientHeight) / 2);
 panX = Math.max(-maxX, Math.min(maxX, panX));
 panY = Math.max(-maxY, Math.min(maxY, panY));
 Object.assign(image.style, {width:`${width}px`,height:`${height}px`,left:`${(paper.clientWidth-width)/2+panX}px`,top:`${(paper.clientHeight-height)/2+panY}px`});
 document.getElementById('view-label').textContent = `${selectedDocument.revision ? selectedDocument.revision + ' · ' : ''}${zoom === 1 ? 'FIT PAGE' : `${zoom}× ZOOM`}`;
 document.getElementById('zoom').textContent = zoom === 1 ? 'Zoom 2×' : zoom === 2 ? 'Zoom 3×' : 'Zoom 1×';
 document.getElementById('move').disabled = zoom === 1;
 document.getElementById('fit').disabled = zoom === 1;
 if (toolsOpen && document.activeElement?.disabled) focusButton('zoom');
}
function showTools(value) {
 toolsOpen = value;
 moving = !value && zoom > 1 && imageReady;
 document.getElementById('reader-tools').hidden = !value;
 if (value) focusButton(imageReady ? 'zoom' : 'documents');
 else document.getElementById('paper').focus({preventScroll:true});
}
function setMoving(value) {
 if (!value) showTools(true);
 else showTools(false);
}
document.addEventListener('keydown', e => {
 if (e.altKey || e.ctrlKey || e.metaKey) return;
 if (e.key === 'Escape' || e.key === 'Backspace' || e.key === 'BrowserBack' || e.key === 'GoBack') { if (moving || stack.length) { e.preventDefault(); back(); } return; }
 if (route === 'reader' && !toolsOpen && !moving) {
  if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); showTools(true); return; }
  if (e.key.startsWith('Arrow')) { e.preventDefault(); if (e.key === 'ArrowRight') changePage(1); if (e.key === 'ArrowLeft') changePage(-1); return; }
 }
 if (moving) {
  if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setMoving(false); return; }
  if (e.key.startsWith('Arrow')) {
   e.preventDefault();
   const distance = 64;
   if (e.key === 'ArrowLeft') panX += distance;
   if (e.key === 'ArrowRight') panX -= distance;
   if (e.key === 'ArrowUp') panY += distance;
   if (e.key === 'ArrowDown') panY -= distance;
   updateImage();
  }
  return;
 }
 const directions = ['ArrowDown', 'ArrowRight', 'ArrowUp', 'ArrowLeft'];
 if (!directions.includes(e.key)) return;
 e.preventDefault();
 const items = [...screen.querySelectorAll('button:not(:disabled), a[href]')];
 const current = items.indexOf(document.activeElement);
 let next;
 if (route === 'reader') {
  const all = [...screen.querySelectorAll('.controls button, #resume')];
  const at = all.indexOf(document.activeElement);
  const delta = e.key === 'ArrowDown' ? 3 : e.key === 'ArrowUp' ? -3 : e.key === 'ArrowRight' ? 1 : -1;
  let target = (at + delta + all.length) % all.length;
  for (let i = 0; i < all.length && all[target].disabled; i++) target = (target + (delta < 0 ? -1 : 1) + all.length) % all.length;
  next = all[target];
 } else {
  const delta = e.key === 'ArrowDown' || e.key === 'ArrowRight' ? 1 : -1;
  next = items[(current + delta + items.length) % items.length];
 }
 next?.focus();
 next?.scrollIntoView({block:'nearest'});
});
window.addEventListener('resize', updateImage);
render();
