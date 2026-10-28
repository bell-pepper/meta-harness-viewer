const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const base = process.env.HARNESS_TEST_URL || 'http://127.0.0.1:8090/meta-harness-viewer/';
(async () => {
 const browser = await chromium.launch({executablePath:process.env.CHROMIUM_PATH || (process.platform==='linux'?'/usr/bin/chromium':undefined),args:['--no-sandbox']});
 try {
  const page = await browser.newPage({viewport:{width:600,height:600}});
  let payload = {version:1,documents:[
   {id:'first',title:'Single page',pages:['demo/page-1.png']},
   {id:'second',title:'<img src=x onerror="window.injected=true">',revision:'Rev <B>',pages:['demo/page-1.png','demo/page-2.png','demo/page-1.png']}
  ]};
  let fail = false;
  await page.route('**/assets/documents.json', r => fail ? r.fulfill({status:503,body:'Unavailable'}) : r.fulfill({contentType:'application/json',body:JSON.stringify(payload)}));
  await page.goto(base);
  await page.locator('#home-documents').click();
  await page.locator('#document-0').waitFor();
  assert.equal(await page.locator('[data-document]').count(),2);
  assert.equal(await page.locator('#document-1 img').count(),0,'titles cannot inject markup');
  assert.equal(await page.evaluate(()=>window.injected),undefined);
  await page.locator('#document-0').click();
  await page.waitForFunction(()=>document.querySelector('#page-status')?.hidden);
  assert(await page.locator('#prev-page').isDisabled());
  assert(await page.locator('#next-page').isDisabled());
  await page.keyboard.press('Escape');
  assert.equal(await page.locator(':focus').getAttribute('id'),'document-0');
  await page.locator('#document-1').click();
  await page.waitForFunction(()=>document.querySelector('#page-status')?.hidden);
  await page.keyboard.press('ArrowRight');await page.keyboard.press('ArrowRight');
  await page.waitForFunction(()=>document.querySelector('#page-status')?.hidden);
  assert.equal(await page.locator('#position').textContent(),'PAGE 3 / 3');
  assert(await page.locator('#next-page').isDisabled());
  await page.keyboard.press('Escape');
  fail = true;
  await page.locator('#refresh-library').click();
  await page.getByRole('alert').waitFor();
  assert.equal(await page.locator('[data-document]').count(),0,'failed refresh does not show stale rows');
  fail = false;payload={version:1,documents:[]};
  await page.locator('#refresh-library').click();
  await page.getByText('No documents are available.').waitFor();
  payload={version:1,documents:[{id:'invalid',title:'Bad page',pages:['javascript:alert(1)']}]};
  await page.locator('#refresh-library').click();
  await page.getByRole('alert').waitFor();
  assert.equal(await page.locator('[data-document]').count(),0);
  console.log('PASS: variable document/page counts, title escaping, selection focus, empty library, failed refresh, and unsafe page rejection.');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
