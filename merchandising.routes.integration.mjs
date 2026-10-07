// HTTP integration against a disposable fake Supabase + Paystack. NO real
// merchant secrets, live SQL or external payment/network requests.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {once} from 'node:events';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const testPort=31572;const appPort=3002;
const origin='https://store.example.test';
const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';const zone='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const orderId='cccccccc-cccc-4ccc-8ccc-cccccccccccc';const reference='TG'+'a'.repeat(32);
const token='dddddddd-dddd-4ddd-8ddd-dddddddddddd';
let paystackCalls=0;let blockedCalls=0;let lastQuote=null;let lastCheckout=null;
const product={id,name:'Fixture tie',category:'Neckties',description:'Local test only',image_url:'',sizes:['One size'],price_minor:7550,available:true,has_size_chart:true};
const storefront={announcement_enabled:true,announcement_text:'Fixture',hero_eyebrow:'Fixture',hero_title:'Fixture',hero_emphasis:'Fixture',hero_final_line:'Fixture',hero_description:'Fixture',hero_visual:'four-ties',hero_cta:'Shop',promo_enabled:false,promo_eyebrow:'',promo_title:'',promo_description:'',promo_button:'Shop',promo_image:'hero-tie-gold.jpg',promo_target:'All'};
const backend=http.createServer(async(req,res)=>{
 const url=new URL(req.url||'/',`http://127.0.0.1:${testPort}`);
 const send=(data,status=200)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(data));};
 let raw='';for await(const part of req)raw+=part;
 const args=raw?JSON.parse(raw):{};
 if(url.pathname==='/paystack/transaction/initialize'){
   paystackCalls++;
   assert.equal(req.headers.authorization,'Bearer sk_test_LOCAL_INTEGRATION_ONLY');
   assert.equal(args.amount,'6795');assert.equal(args.currency,'GHS');
   assert.equal(JSON.parse(args.metadata).order_id,orderId);
   return send({status:true,data:{reference,authorization_url:'https://checkout.paystack.com/test-merch-only'}});
 }
 if(url.pathname==='/supabase/rest/v1/rpc/thetieguy_store_catalog_v3'){
   assert.equal(req.headers.apikey,'sb_publishable_LOCAL_FIXTURE');
   assert.equal(args.p_limit,24);assert.equal(args.p_page,2);
   return send({business:{name:'@thetieguy',availability:'available',unavailable_message:''},storefront,
     products:[product],delivery_zones:[{id:zone,name:'Fixture zone',fee_minor:1500}],total_count:25,page:2,page_size:24});
 }
 if(url.pathname==='/supabase/rest/v1/rpc/store_cart_products_v1')return send([product]);
 if(url.pathname==='/supabase/rest/v1/rpc/store_size_chart_for_product_v1'){
   assert.equal(args.p_product_id,id);
   return send({title:'Fixture chart',units:'cm',columns:['Style','Length'],rows:[['TEST','Not real']],notes:'No real measurements supplied'});
 }
 if(url.pathname==='/supabase/rest/v1/rpc/store_quote_v1'){
   lastQuote=args;
   assert.equal(args.p_items[0].price_minor,undefined);
   if(args.p_code==='BADCODE')return send({message:'Discount code is unavailable or does not apply to this order',code:'P0001'},400);
   const fee=args.p_zone_id===zone?1500:args.p_method==='pickup'?0:null;
   const savings=args.p_code==='SAVE10'?755:500;
   const deliverySavings=args.p_code==='SAVE10'?(fee||0):0;
   return send({subtotal_minor:7550,delivery_fee_minor:fee,discount_minor:savings,
     delivery_discount_minor:deliverySavings,amount_minor:7550+(fee||0)-savings-deliverySavings,
     promotion_name:args.p_code==='SAVE10'?'Fixture code':'Fixture automatic',promotion_code:args.p_code==='SAVE10'?'SAVE10':null,message:null});
 }
 if(url.pathname==='/supabase/rest/v1/rpc/store_create_checkout_order_v2'){
   lastCheckout=args;
   if(args.p_items[0].id==='blocked')return send({message:'Not enough stock left for Fixture tie. Refresh your bag.',code:'P0001'},400);
   if(args.p_expected_amount_minor!==6795)return send({message:'Price or promotion changed. Refresh your quote before paying.',code:'P0001'},400);
   return send({id:orderId,reference,token,amount_minor:6795,order_number:'TG-TEST'});
 }
 if(url.pathname==='/supabase/rest/v1/rpc/store_note_checkout_stock_issue'){
   blockedCalls++;return send(null);
 }
 return send({message:`Unexpected fake request: ${url.pathname}`,code:'LOCAL'},404);
});
backend.listen(testPort,'127.0.0.1');await once(backend,'listening');
let child;
try{
 child=spawn(path.join(root,'node_modules/.bin/next'),['dev','-H','0.0.0.0','-p',String(appPort)],{
  cwd:root,detached:true,env:{...process.env,MOCK_FETCH_STUB_PORT:String(testPort),
    NODE_OPTIONS:`--require ${path.join(root,'tests/redirect-paystack-fetch.cjs')}`,
    NEXT_PUBLIC_SUPABASE_URL:'https://test-supabase.internal',NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:'sb_publishable_LOCAL_FIXTURE',
    SUPABASE_SERVICE_ROLE_KEY:'service_role_LOCAL_FIXTURE',PAYSTACK_SECRET_KEY:'sk_test_LOCAL_INTEGRATION_ONLY',STORE_ORIGIN:origin,
    NEXT_TELEMETRY_DISABLED:'1'},stdio:['ignore','pipe','pipe']});
 let output='';const ready=new Promise((resolve,reject)=>{
   const log=chunk=>{output+=chunk.toString();if(output.includes('Ready in'))resolve();};
   child.stdout.on('data',log);child.stderr.on('data',log);
   child.once('exit',code=>reject(new Error(`Next exited ${code}: ${output.slice(-800)}`)));
   setTimeout(()=>reject(new Error(`Next startup timeout: ${output.slice(-800)}`)),60000).unref();
 });await ready;
 const base=`http://127.0.0.1:${appPort}`;
 const headers={'Content-Type':'application/json',Origin:origin};
 const items=[{id,size:'One size',quantity:1,price_minor:1}];
 const quote=(options={})=>fetch(`${base}/api/quote`,{method:'POST',headers,body:JSON.stringify({items,
   fulfillment_method:'delivery',zone_id:zone,email:'buyer@example.com',discount_code:'SAVE10',...options})});
 const checkout=(options={})=>fetch(`${base}/api/checkout`,{method:'POST',headers,body:JSON.stringify({items,
   customer:{name:'Fixture Buyer',email:'buyer@example.com',phone:'+233200000000'},
   fulfillment_method:'delivery',zone_id:zone,delivery_address:'Fixture address Accra street',discount_code:'SAVE10',
   expected_amount_minor:6795,website:'',...options})});
 const catalog=await fetch(`${base}/api/catalog?page=2&category=Ties&q=Fixture&sort=low`);
 assert.equal(catalog.status,200);const result=await catalog.json();assert.equal(result.total_count,25);
 assert.equal(result.products[0].id,id);
 assert.equal((await fetch(`${base}/api/catalog?page=0`)).status,400);
 const cart=await fetch(`${base}/api/cart-products?id=${id}`);assert.equal(cart.status,200);
 assert.equal((await cart.json()).products[0].id,id);
 assert.equal((await fetch(`${base}/api/size-chart?id=${id}`)).status,200);
 assert.equal((await fetch(`${base}/api/quote`,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})).status,403);
 const valid=await quote();assert.equal(valid.status,200);assert.equal((await valid.json()).amount_minor,6795);
 assert.equal(lastQuote.p_code,'SAVE10');assert.equal(lastQuote.p_zone_id,zone);
 assert.equal((await quote({discount_code:'BADCODE'})).status,400);
 const separately=await quote({zone_id:null});assert.equal((await separately.json()).delivery_fee_minor,null);
 assert.equal((await checkout({expected_amount_minor:1})).status,400);
 assert.equal(paystackCalls,0); // stale quote rolls back before gateway init
 assert.equal((await fetch(`${base}/api/checkout`,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})).status,403);
 const approved=await checkout();assert.equal(approved.status,201);
 assert.equal((await approved.json()).authorization_url,'https://checkout.paystack.com/test-merch-only');
 assert.equal(paystackCalls,1);assert.equal(lastCheckout.p_expected_amount_minor,6795);
 assert.equal(lastCheckout.p_items[0].price_minor,undefined);
 assert.equal((await checkout({items:[{id:'blocked',size:'One size',quantity:1}]})).status,400);
 assert.equal(blockedCalls,1);
 console.log('PASS: bounded public catalog/cart/charts, origin guard, DB quotes, stale-quote rejection, exact gateway charge and stock-block incident');
}finally{
 if(child?.pid)try{process.kill(-child.pid,'SIGTERM');}catch{}
 backend.close();
}
