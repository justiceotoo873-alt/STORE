// Disposable browser fixtures. Requires a local Next preview; never contacts
// live Supabase or Paystack and does not create/seed real merchant products.
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const url=process.env.STORE_UI_URL||'http://127.0.0.1:3000';
const zone='11111111-1111-4111-8111-111111111111';
const products=[
 {id:'9223372036854775807',name:'Paisley signature necktie',category:'Neckties',description:'A statement tie for the moments that matter.',image_url:'https://assets.example.test/tie.jpg',sizes:['One size'],price_minor:7550,available:true,has_size_chart:true},
 {id:'22222222-2222-4222-8222-222222222222',name:'Classic gold tie clip',category:'Tie clips',description:'A polished finishing touch.',image_url:'https://assets.example.test/clip.jpg',sizes:['One size'],price_minor:2500,available:true,has_size_chart:false},
 {id:'33333333-3333-4333-8333-333333333333',name:'Pharmacy brooch',category:'Brooches',description:'A special detail for pharmacy professionals.',image_url:'https://assets.example.test/pharmacy.jpg',sizes:['One size'],price_minor:3900,available:true,has_size_chart:false},
 {id:'44444444-4444-4444-8444-444444444444',name:'Late-page burgundy tie',category:'Neckties',description:'A second page test style.',image_url:'',sizes:['One size'],price_minor:6500,available:true,has_size_chart:false}
];
const storefront={announcement_enabled:true,announcement_text:'THE DETAIL MAKES THE DIFFERENCE',hero_eyebrow:'THE TIE GUY · THE SIGNATURE EDIT',
 hero_title:'A little detail.',hero_emphasis:'A lasting',hero_final_line:'impression.',hero_description:'Statement neckties, considered accessories, and the finishing touches that make every entrance your own.',
 hero_visual:'four-ties',hero_cta:'Explore the collection',promo_enabled:false,promo_eyebrow:'',promo_title:'',promo_description:'',promo_button:'Shop the edit',promo_image:'hero-tie-gold.jpg',promo_target:'All'};
const files={tie:'hero-tie-burgundy.jpg',clip:'tieclips-collection.jpg',pharmacy:'brooch-pharmacy-bowl.jpg'};
const browser=await chromium.launch({headless:true});
try {
 for (const [label,width,height] of [['desktop',1440,900],['mobile',390,844]]) {
  const page=await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
  await page.route('**/api/catalog?*',r=>{
   const params=new URL(r.request().url()).searchParams;
   const category=params.get('category')||'All';const search=params.get('q')||'';
   const filtered=products.filter(p=>(category==='All' || (category==='Ties' ? p.name.includes('tie') && !p.name.includes('clip') : category==='Clips' ? p.name.includes('clip') : category==='Brooches' ? p.name.includes('brooch') : false)) &&
      `${p.name} ${p.category} ${p.description}`.toLowerCase().includes(search.toLowerCase()));
   const selected=category==='All'&&!search ? params.get('page')==='2'?[products[3]]:products.slice(0,3) : filtered;
   return r.fulfill({status:200,json:{business:{name:'@thetieguy',availability:'available',unavailable_message:''},
    storefront,products:selected,total_count:category==='All'&&!search?25:filtered.length,page:Number(params.get('page')||1),page_size:24,
    delivery_zones:[{id:zone,name:'Fixture zone — not a real rate',fee_minor:1500}]}});
  });
  await page.route('**/api/cart-products?*',r=>{
   const ids=new URL(r.request().url()).searchParams.getAll('id');
   return r.fulfill({json:{products:products.filter(p=>ids.includes(p.id))}});
  });
  await page.route('**/api/size-chart?*',r=>r.fulfill({json:{chart:{title:'Fixture size guide',units:'cm',columns:['Style','Length'],rows:[['Classic','Test entry only']],notes:'Test-only chart; no real measurements.'}}}));
  await page.route('**/api/config',r=>r.fulfill({json:{checkout_enabled:true,test_mode:true}}));
  await page.route('**/api/quote',async r=>{
   const input=JSON.parse(r.request().postData()||'{}');
   const subtotal=input.items.reduce((sum,line)=>sum+products.find(p=>p.id===line.id).price_minor*line.quantity,0);
   const fee=input.fulfillment_method==='pickup'?0:input.zone_id===zone?1500:null;
   const withCode=input.discount_code==='SAVE10';
   const discount=withCode?Math.round(subtotal*.10):500;
   const deliveryDiscount=withCode?(fee||0):0;
   return r.fulfill({json:{subtotal_minor:subtotal,delivery_fee_minor:fee,discount_minor:discount,delivery_discount_minor:deliveryDiscount,
    amount_minor:subtotal+(fee||0)-discount-deliveryDiscount,promotion_name:withCode?'Fixture code (test)':'Fixture automatic (test)',promotion_code:withCode?'SAVE10':null,message:null}});
  });
  await page.route('https://assets.example.test/**',r=>{
   const file=files[r.request().url().split('/').at(-1)?.split('.')[0]];
   return r.fulfill({path:path.join(root,'public/images',file||files.tie),contentType:'image/jpeg'});
  });
  let checkout=null;
  await page.route('**/api/checkout',async r=>{
   checkout=JSON.parse(r.request().postData()||'{}');
   await r.fulfill({status:201,json:{authorization_url:'https://checkout.paystack.com/test-local-only',reference:'TG'+'a'.repeat(32),token:'11111111-1111-4111-8111-111111111111',order_number:'TG-TEST'}});
  });
  await page.route('https://checkout.paystack.com/**',r=>r.fulfill({status:200,body:'LOCAL TEST GATEWAY. NO REAL PAYMENT.'}));
  await page.goto(url,{waitUntil:'networkidle'});
  await page.getByRole('heading',{name:'Find your signature.'}).waitFor();
  // New chrome: floating support button + footer WhatsApp CTA (support number, not the group).
  const support=page.locator('.support-float');
  assert.equal(await support.count(),1,`${label}: floating WhatsApp support button`);
  assert.match(await support.getAttribute('href')||'',/^https:\/\/wa\.me\/233592060208/,`${label}: support button uses the business number`);
  assert.equal(await page.locator('.site-footer').getByRole('link',{name:/Chat with us on WhatsApp/}).count(),1,`${label}: footer WhatsApp CTA`);
  assert.equal(await page.getByText('DM @thetieguy').count(),0,`${label}: Instagram DM line removed`);
  // The drawer must never trap scrolling when it is closed.
  assert.notEqual(await page.evaluate(()=>getComputedStyle(document.body).overflow),'hidden',`${label}: page scrolls freely on arrival`);
  const horizontal=await page.evaluate(()=>({scroll:document.documentElement.scrollWidth,width:window.innerWidth}));
  assert.ok(horizontal.scroll<=horizontal.width,`${label}: horizontal scroll ${JSON.stringify(horizontal)}`);
  await page.getByRole('button',{name:'View Paisley signature necktie'}).click();
  await page.getByRole('button',{name:'Size guide'}).click();
  await page.getByText('Fixture size guide').waitFor();
  await page.getByRole('button',{name:/Add to bag/}).click();
  await page.getByRole('button',{name:'Close bag'}).click();
  await page.getByRole('button',{name:'Next →'}).click();
  await page.getByText('Late-page burgundy tie').waitFor();
  await page.getByRole('button',{name:/Open bag/}).click();
  await page.getByRole('heading',{name:/Your bag/}).waitFor();
  await page.getByRole('button',{name:/Continue to checkout/}).click();
  await page.getByRole('textbox',{name:'Full name'}).fill('Local Test Buyer');
  await page.getByRole('textbox',{name:'Email address'}).fill('buyer@example.com');
  await page.getByRole('textbox',{name:'Phone number'}).fill('+233200000000');
  await page.getByRole('combobox',{name:/Delivery zone/}).selectOption(zone);
  await page.getByRole('textbox',{name:'Delivery address'}).fill('Accra, this is a disposable test address');
  await page.getByText('Fixture automatic (test)').waitFor();
  await page.getByRole('textbox',{name:/Discount code/}).fill('SAVE10');
  await page.getByText('Fixture code (test)').waitFor();
  await page.getByRole('button',{name:/Pay GH₵67\.95/}).click();
  await page.waitForURL('https://checkout.paystack.com/test-local-only');
  assert.equal(checkout.items.length,1);
  assert.equal(checkout.items[0].id,'9223372036854775807');
  assert.equal(checkout.items[0].price_minor,undefined);
  assert.equal(checkout.expected_amount_minor,6795);
  assert.equal(checkout.discount_code,'SAVE10');
  assert.equal(checkout.zone_id,zone);
  console.log(`PASS ${label}: server pagination, cart across pages, size chart, automatic + code offer, live quote and safe Paystack payload`);
  await page.close();
 }
} finally {await browser.close();}
