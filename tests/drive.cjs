// Integration test: run the backend with the test Google transport (see service README).
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||(process.platform==='linux'?'/usr/bin/chromium':undefined),args:['--no-sandbox']});
 try {
  const context=await browser.newContext({viewport:{width:600,height:600}});
  const errors=[];
  const glasses=await context.newPage();glasses.on('pageerror',e=>errors.push(e.message));
  await glasses.route('**/drive-config.js*',r=>r.fulfill({contentType:'text/javascript',body:"window.HARNESS_SERVICE_URL='http://localhost:8080';"}));
  await glasses.goto('http://localhost:8090/meta-harness-viewer/');
  await glasses.locator('#home-documents').click();
  await glasses.locator('#drive-connect').click();
  await glasses.locator('.pair-code').waitFor();
  const code=await glasses.locator('.pair-code').textContent();
  assert.equal(code.length,8);
  const phone=await context.newPage();phone.on('pageerror',e=>errors.push(e.message));
  await phone.route('https://accounts.google.com/o/oauth2/v2/auth**',r=>{
   const state=new URL(r.request().url()).searchParams.get('state');
   return r.fulfill({status:302,headers:{location:'http://localhost:8080/auth/callback?'+new URLSearchParams({state,code:'alice'})}});
  });
  await phone.goto('http://localhost:8080/connect');
  await phone.locator('#signin').click();
  await phone.getByRole('button',{name:'Select alice folder',exact:true}).click();
  await phone.locator('#code').fill(code);
  await phone.locator('#pair').click();
  await phone.getByText('Glasses paired. Return to the glasses to open your documents.').waitFor();
  await glasses.locator('#drive-library').waitFor();
  await glasses.locator('#drive-library').click();
  await glasses.locator('#document-0').waitFor();
  assert((await glasses.locator('#document-0').textContent()).includes('alice.pdf'));
  await glasses.locator('#document-0').click();
  await glasses.waitForFunction(()=>document.querySelector('#page-status')?.hidden);
  assert.equal(await glasses.locator('#position').textContent(),'PAGE 1 / 2');
  assert(await glasses.locator('header').isHidden());
  assert(await glasses.locator('#reader-tools').isHidden());
  assert((await glasses.locator('#page-image').getAttribute('src')).startsWith('blob:'));
  await glasses.keyboard.press('ArrowRight');
  await glasses.waitForFunction(()=>document.querySelector('#page-status')?.hidden);
  assert.equal(await glasses.locator('#position').textContent(),'PAGE 2 / 2');
  await glasses.keyboard.press('Escape');
  assert.equal(await glasses.locator(':focus').getAttribute('id'),'document-0');
  await glasses.reload();
  await glasses.locator('#home-documents').click();
  await glasses.locator('#document-0').waitFor();
  const saved=await glasses.evaluate(()=>localStorage.getItem('harness.drive.device.v1'));
  assert(!saved.includes('access-alice')&&!saved.includes('refresh-alice'));
  const requests=[];glasses.on('request',r=>requests.push(r.url()));
  await phone.getByRole('button',{name:'Revoke',exact:true}).first().click();
  await glasses.locator('#refresh-library').click();
  await glasses.getByRole('alert').waitFor();
  assert.equal(await glasses.locator('[data-document]').count(),0);
  assert(!requests.some(url=>url.includes('access-alice')||url.includes('refresh-alice')));
  assert.deepEqual(errors,[]);
  console.log('PASS: phone Google sign-in and folder selection, glasses pairing, authenticated real PDF rendering, fullscreen reading, persistence, focus restoration, and remote revocation (Google simulated).');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
