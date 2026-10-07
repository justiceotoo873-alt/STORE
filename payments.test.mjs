// Unit/security checks. They NEVER contact Paystack or the user's Supabase.
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import { initializePaystack, matchesVerifiedPayment, validPaystackCheckoutUrl, validPaystackSignature, verifiedPaidAt, verifyPaystack } from '../lib/paystack.ts';
import { normalizeCatalog, normalizeQuote, normalizeSizeChart, defaultStorefront, categoryFor, safeImage, formatGhs } from '../lib/catalog.ts';
import { reconcileVerifiedOrder } from '../lib/payment-flow.ts';

const order = { id:'11111111-1111-4111-8111-111111111111',reference:'TG'+'a'.repeat(32),amount_minor:8950,currency:'GHS',customer_email:'buyer@example.com' };
const verified = {status:'success',reference:order.reference,amount:8950,currency:'GHS',domain:'test',customer:{email:'Buyer@Example.com'},metadata:{order_id:order.id}};
const secret='sk_test_dummy_local_not_a_credential';

test('webhook signature authenticates exact raw bytes; tampering and malformed signatures fail',()=>{
  const raw='{"event":"charge.success","buyer":"Àda"}';
  const signature=createHmac('sha512',secret).update(raw).digest('hex');
  assert.equal(validPaystackSignature(raw,signature,secret),true);
  assert.equal(validPaystackSignature(raw+' ',signature,secret),false);
  assert.equal(validPaystackSignature(Buffer.from(raw),signature.toUpperCase(),secret),true);
  assert.equal(validPaystackSignature(raw,null,secret),false);
  assert.equal(validPaystackSignature(raw,'0'.repeat(127),secret),false);
  assert.equal(validPaystackSignature(raw,signature,''),false);
});

test('verified Paystack data must match ALL immutable order fields and test/live mode',()=>{
  assert.equal(matchesVerifiedPayment(verified,order,secret),true);
  assert.equal(matchesVerifiedPayment({...verified, metadata:JSON.stringify(verified.metadata)},order,secret),true);
  for(const changed of [
    {status:'pending'}, {reference:'TG'+'b'.repeat(32)}, {amount:8951}, {currency:'USD'},
    {domain:'live'}, {customer:{email:'someoneelse@example.com'}},
    {metadata:{order_id:'22222222-2222-4222-8222-222222222222'}}, {metadata:null}, {customer:null}
  ]) {
    assert.equal(matchesVerifiedPayment({...verified,...changed},order,secret),false,JSON.stringify(changed));
  }
  assert.equal(matchesVerifiedPayment({...verified,domain:'live'},order,'sk_live_dummy'),true);
  assert.equal(matchesVerifiedPayment(verified,{...order,amount_minor:0},secret),false);
  assert.equal(matchesVerifiedPayment(verified,{...order,currency:'USD'},secret),false);
  assert.equal(matchesVerifiedPayment(verified,order,'invalid_key'),false);
});

test('Paystack URL allowlist rejects links to a third party or insecure checkout',()=>{
  assert.equal(validPaystackCheckoutUrl('https://checkout.paystack.com/aBc123'),true);
  for(const url of ['http://checkout.paystack.com/x','https://checkout.paystack.com.evil.test/x','https://evil.test/x',
    'https://checkout.paystack.com@evil.test/x','https://me:pass@checkout.paystack.com/x','javascript:alert(1)','not a URL'])
    assert.equal(validPaystackCheckoutUrl(url),false,url);
});

test('Paystack initialize sends server-calculated smallest-unit GHS amount and rejects untrusted responses',async()=>{
  const originalFetch=globalThis.fetch;
  let calls=0;
  try {
    globalThis.fetch=async(url,options)=>{
      calls++;
      assert.equal(url,'https://api.paystack.co/transaction/initialize');
      assert.equal(options.headers.Authorization,`Bearer ${secret}`);
      const body=JSON.parse(options.body);
      assert.equal(body.amount,'8950');
      assert.equal(body.currency,'GHS');
      assert.equal(body.channels,undefined); // Paystack decides which channels the merchant supports.
      assert.equal(JSON.parse(body.metadata).order_id,order.id);
      assert.equal(body.callback_url,'https://store.example.test/order/return');
      return Response.json({status:true,data:{reference:order.reference,authorization_url:'https://checkout.paystack.com/secure-test'}});
    };
    assert.equal(await initializePaystack(secret,{email:order.customer_email,amount_minor:8950,reference:order.reference,callback_url:'https://store.example.test/order/return',order_id:order.id}),'https://checkout.paystack.com/secure-test');
    assert.equal(calls,1);
    globalThis.fetch=async()=>Response.json({status:true,data:{reference:order.reference,authorization_url:'https://fake-paystack.test/'}});
    await assert.rejects(initializePaystack(secret,{email:order.customer_email,amount_minor:8950,reference:order.reference,callback_url:'https://store.example.test/order/return',order_id:order.id}),/untrusted/);
    globalThis.fetch=async()=>Response.json({status:true,data:{reference:'different',authorization_url:'https://checkout.paystack.com/test'}});
    await assert.rejects(initializePaystack(secret,{email:order.customer_email,amount_minor:8950,reference:order.reference,callback_url:'https://store.example.test/order/return',order_id:order.id}),/untrusted/);
    globalThis.fetch=async()=>Response.json({status:false,data:null}, {status:401});
    await assert.rejects(verifyPaystack(secret,order.reference),/did not accept/);
    await assert.rejects(verifyPaystack(secret,'../../admin'),/Invalid Paystack reference/);
  } finally { globalThis.fetch=originalFetch; }
});

test('catalog accepts text bigint IDs without precision loss and rejects forged prices',()=>{
 const catalog=normalizeCatalog({business:{name:'@thetieguy',availability:'available',unavailable_message:''},
  storefront:defaultStorefront, page:1,page_size:24,total_count:1050,
  products:[{id:'9223372036854775807',name:'Gold necktie',category:'Ties',description:'Test',image_url:'',sizes:['One size'],price_minor:11999,available:true,has_size_chart:true}],
  delivery_zones:[{id:'11111111-1111-4111-8111-111111111111',name:'Test only',fee_minor:1400}]});
 assert.equal(catalog.products[0].id,'9223372036854775807');
 assert.equal(formatGhs(catalog.products[0].price_minor),'GH₵119.99');
 assert.equal(categoryFor({name:'Medical brooch',category:'Accessories'}),'Brooches');
 assert.equal(safeImage('javascript:alert(1)'), '');
 assert.equal(catalog.total_count,1050); // not limited to 1,000 products
 assert.throws(()=>normalizeCatalog({...catalog,products:[{...catalog.products[0],price_minor:'1'}]}),/invalid product/);
 assert.throws(()=>normalizeCatalog({...catalog,page_size:0}),/paging/);
 assert.deepEqual(normalizeSizeChart({title:'Fixture',units:'cm',columns:['Style','Length'],rows:[['A','TEST ONLY']],notes:''}).rows,[['A','TEST ONLY']]);
 assert.throws(()=>normalizeSizeChart({title:'Bad',units:'cm',columns:['A','B'],rows:[['Only one']],notes:''}),/Invalid size chart/);
 const quote=normalizeQuote({subtotal_minor:7550,delivery_fee_minor:null,discount_minor:755,delivery_discount_minor:0,amount_minor:6795,promotion_name:'Fixture',promotion_code:'SAVE10',message:null});
 assert.equal(quote.amount_minor,6795);
 assert.throws(()=>normalizeQuote({...quote,delivery_discount_minor:1400}),/Invalid price quote/);
});

test('only Paystack verify paid_at may decide if an order beat its stock hold',()=>{
  assert.equal(verifiedPaidAt({...verified,paid_at:'2026-09-30T12:31:06.000Z'}),'2026-09-30T12:31:06.000Z');
  assert.equal(verifiedPaidAt({...verified,paid_at:'2026-09-30T13:31:06+01:00'}),'2026-09-30T12:31:06.000Z');
  assert.equal(verifiedPaidAt({...verified,paid_at:null}),null);
  assert.equal(verifiedPaidAt({...verified,paid_at:'yesterday'}),null);
  assert.equal(verifiedPaidAt({...verified,paid_at:'2026-09-30'}),null); // no timezone
  assert.equal(verifiedPaidAt({...verified,paid_at:0}),null);
});

test('the single webhook/return/cron decision path auto-confirms only exact Paystack success',async()=>{
  const calls=[];
  const rpc=async(name,args)=>{calls.push({name,args});return {data:'confirmed',error:null};};
  const paystack={...verified,paid_at:'2026-09-30T12:31:06.000Z'};
  const state=await reconcileVerifiedOrder({...order,payment_status:'pending'},secret,async(ref)=>{
    assert.equal(ref,order.reference);return paystack;
  },rpc);
  assert.equal(state,'confirmed');
  assert.equal(calls.length,1);
  assert.equal(calls[0].name,'store_settle_verified_payment_v2');
  assert.deepEqual(calls[0].args,{
    p_reference:order.reference,p_order_id:order.id,p_amount_minor:8950,p_currency:'GHS',
    p_email:'Buyer@Example.com',p_paid_at:'2026-09-30T12:31:06.000Z',p_domain:'test'
  });
});

test('a successful but UNDERPAID/mismatched charge enters review, never the settlement RPC',async()=>{
  for(const changed of [{amount:8951},{currency:'USD'},{domain:'live'},{metadata:{order_id:'wrong'}},{customer:{email:'attacker@example.test'}}]){
    const calls=[];
    const state=await reconcileVerifiedOrder({...order,payment_status:'pending'},secret,
      async()=>({...verified,...changed}),async(name,args)=>{calls.push({name,args});return {data:'payment_review',error:null};});
    assert.equal(state,'payment_review',JSON.stringify(changed));
    assert.deepEqual(calls.map(c=>c.name),['store_flag_payment_review']);
    assert.deepEqual(calls[0].args,{p_reference:order.reference,p_order_id:order.id});
  }
});

test('pending, verified-exception and confirmed states do not invent a payment or repeat stock deductions',async()=>{
  let verifies=0;let settles=0;
  const verify=async()=>{verifies++;return {...verified,status:'pending'};};
  const rpc=async()=>{settles++;return {data:'confirmed',error:null};};
  assert.equal(await reconcileVerifiedOrder({...order,payment_status:'pending'},secret,verify,rpc),'pending');
  assert.equal(await reconcileVerifiedOrder({...order,payment_status:'confirmed'},secret,verify,rpc),'confirmed');
  assert.equal(await reconcileVerifiedOrder({...order,payment_status:'refund_needed'},secret,verify,rpc),'refund_needed');
  assert.equal(await reconcileVerifiedOrder({...order,payment_status:'payment_review'},secret,verify,rpc),'payment_review');
  assert.equal(verifies,1);
  assert.equal(settles,0);
  const late=await reconcileVerifiedOrder({...order,payment_status:'provider_verified'},secret,
    async()=>({...verified,paid_at:null}),async(name,args)=>{
      assert.equal(name,'store_settle_verified_payment_v2');
      assert.equal(args.p_paid_at,null); // DB must hold this for human review
      return {data:'provider_verified',error:null};
    });
  assert.equal(late,'provider_verified');
});

test('database errors and unexpected RPC states fail closed instead of showing paid',async()=>{
  await assert.rejects(reconcileVerifiedOrder({...order,payment_status:'pending'},secret,
    async()=>({...verified,paid_at:'2026-09-30T12:31:06Z'}),
    async()=>({data:null,error:{message:'Database unavailable'}})),/Database unavailable/);
  await assert.rejects(reconcileVerifiedOrder({...order,payment_status:'pending'},secret,
    async()=>verified,async()=>({data:'paid_by_ai',error:null})),/unexpected state/);
});
