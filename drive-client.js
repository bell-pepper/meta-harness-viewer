'use strict';
window.HarnessDrive = (() => {
 const KEY='harness.drive.device.v1';
 let state;
 try {state=JSON.parse(localStorage.getItem(KEY)||'null');}catch{state=null;}
 const raw=window.HARNESS_SERVICE_URL||'';
 let base='';
 try {
  const url=new URL(raw);
  if((url.protocol==='https:'||(url.protocol==='http:'&&['127.0.0.1','localhost'].includes(url.hostname)))&&!url.username&&!url.password&&!url.search&&!url.hash&&url.pathname==='/')base=url.origin;
 }catch{}
 if(state?.service!==base)state=null;
 function save() {try {if(state)localStorage.setItem(KEY,JSON.stringify(state));else localStorage.removeItem(KEY);}catch{}}
 async function request(path, options={}) {
  if(!base)throw new Error('Private Drive service is not configured yet.');
  const sentState=state;
  const controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),45000);
  try {
   const response=await fetch(base+path,{...options,signal:controller.signal,credentials:'omit',cache:'no-store',headers:{...(state?.token?{Authorization:'Bearer '+state.token}:{}),...options.headers}});
   if(!response.ok){let data;try{data=await response.json();}catch{}if(response.status===401&&state===sentState){state=null;save();}throw new Error(typeof data?.detail==='string'?data.detail:'Drive service request failed.');}
   return response;
  }catch(e){if(e.name==='AbortError')throw new Error('Drive request timed out. Try again.');throw e;}
  finally {clearTimeout(timeout);}
 }
 return {
  configured:()=>!!base,
  paired:()=>!!state?.paired,
  setupURL:()=>base+'/connect',
  async startPair() {
   const data=await(await request('/api/pair/start',{method:'POST'})).json();
   state={service:base,token:data.token,paired:false};save();
   return data;
  },
  async status() {
   const current=state;
   const data=await(await request('/api/device/status')).json();
   if(state!==current)return {paired:false};
   if(data.paired){state.paired=true;save();}return data;
  },
  async documents() {
   let documents=[],cursor='',seen=new Set();
   do {
    const data=await(await request('/api/device/documents?'+new URLSearchParams({cursor}))).json();
    documents.push(...data.documents);cursor=data.next||'';
    if(cursor&&seen.has(cursor))throw new Error('Drive returned repeated pagination. Refresh documents.');
    seen.add(cursor);
    if(documents.length>2000)throw new Error('This folder exceeds the 2000-document limit. Choose a smaller folder.');
   }while(cursor);
   return documents;
  },
  async open(doc) {
   const data=await(await request('/api/device/documents/'+encodeURIComponent(doc.id))).json();
   if(!Number.isInteger(data.page_count)||data.page_count<1||data.page_count>1000)throw new Error('Unsupported PDF page count.');
   return {...doc,revision:data.revision,pages:Array.from({length:data.page_count},(_,i)=>'/api/device/documents/'+encodeURIComponent(doc.id)+'/pages/'+i),private:true};
  },
  async image(path) {return URL.createObjectURL(await(await request(path)).blob());},
  async disconnect() {try {await request('/api/device',{method:'DELETE'});}finally{state=null;save();}},
  forget() {state=null;save();}
 };
})();
