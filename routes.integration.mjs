// SELF-CONTAINED HTTP INTEGRATION TEST. Fake Paystack and fake PostgREST run on
// loopback. NO external gateway, credential or Supabase project is contacted.
// Stop any other Next process in this directory first (.next is shared).
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { spawn } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const checkoutSecret='sk_test_LOCAL_INTEGRATION_ONLY';
const cronSecret='local-integration-cron-secret-over-32-chars';
const orderId='22222222-2222-4222-8222-222222222222';
const token='33333333-3333-4333-8333-333333333333';
const reference='TG'+'a'.repeat(32);
const port=31571;
let verifiedStatus='success';
let verifiedAmount=8950;
let paymentCalls=0;
let rpcCalls=[];
let state;
function reset() {
  verifiedStatus='success';verifiedAmount=8950;paymentCalls=0;rpcCalls=[];
  state={id:orderId,reference,checkout_token:token,order_number:'TG-TEST',customer_email:'buyer@example.com',amount_minor:8950,
    currency:'GHS',payment_status:'pending',order_status:'new',confirmation_source:'none',reservation_expires_at:new Date(Date.now()+1_800_000).toISOString()};
}
reset();
const backend=http.createServer(async(req,res)=>{
  const url=new URL(req.url||'/',`http://127.0.0.1:${port}`);
  const send=(value,status=200)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(value));};
  if(url.pathname.startsWith('/paystack/transaction/verify/')){
    paymentCalls++;
    assert.equal(req.headers.authorization,`Bearer ${checkoutSecret}`);
    assert.equal(url.pathname.split('/').at(-1),reference);
    return send({status:true,data:{id:12345,status:verifiedStatus,reference,amount:verifiedAmount,currency:'GHS',domain:'test',
      customer:{email:state.customer_email},metadata:{order_id:orderId},paid_at:new Date().toISOString()}});
  }
  if(url.pathname==='/supabase/rest/v1/store_orders'){
    const isSingle=(req.headers.accept||'').includes('application/vnd.pgrst.object+json');
    const byRef=url.searchParams.get('reference');
    const byToken=url.searchParams.get('checkout_token');
    const byId=url.searchParams.get('id');
    const byStatus=url.searchParams.get('payment_status');
    const found=(!byRef||byRef===`eq.${reference}`) && (!byToken||byToken===`eq.${token}`)
      && (!byId||byId===`eq.${orderId}`) && (!byStatus||byStatus===`eq.${state.payment_status}`);
    if(isSingle && !found)return send({code:'PGRST116',message:'The result contains 0 rows',details:'',hint:null},406);
    return send(isSingle?state:found?[state]:[]);
  }
  if(url.pathname.startsWith('/supabase/rest/v1/rpc/')){
    let raw='';for await (const part of req)raw+=part;
    const args=JSON.parse(raw||'{}');
    const fn=url.pathname.split('/').at(-1);
    rpcCalls.push({fn,args});
    if(args.p_reference!==reference||args.p_order_id!==orderId)return send({message:'Unknown store payment reference',code:'P0001'},400);
    if(fn==='store_settle_verified_payment_v2'){
      assert.equal(args.p_amount_minor,8950);
      assert.equal(args.p_currency,'GHS');
      assert.equal(args.p_email,state.customer_email);
      assert.equal(args.p_domain,'test');
      assert.ok(Date.parse(args.p_paid_at)>Date.now()-60_000);
      if(state.payment_status==='pending'){
        state.payment_status='confirmed';state.order_status='processing';state.confirmation_source='paystack';
      }
      return send('confirmed');
    }
    if(fn==='store_flag_payment_review'){
      if(state.payment_status==='pending')state.payment_status='payment_review';
      return send('payment_review');
    }
    return send({message:'Unrecognized RPC'},404);
  }
  return send({message:'Unrecognized mock request',url:url.pathname},404);
});
backend.listen(port,'127.0.0.1');await once(backend,'listening');
let child;
try{
  child=spawn(path.join(root,'node_modules/.bin/next'),['dev','-H','0.0.0.0','-p','3001'],{
    cwd:root,detached:true,env:{...process.env,MOCK_FETCH_STUB_PORT:String(port),
      NODE_OPTIONS:`--require ${path.join(root,'tests/redirect-paystack-fetch.cjs')}`,
      NEXT_PUBLIC_SUPABASE_URL:'https://test-supabase.internal',
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:'sb_publishable_LOCAL_FIXTURE',
      SUPABASE_SERVICE_ROLE_KEY:'service_role_LOCAL_FIXTURE',
      PAYSTACK_SECRET_KEY:checkoutSecret,STORE_ORIGIN:'https://store.example.test',
      CRON_SECRET:cronSecret,NEXT_TELEMETRY_DISABLED:'1'},stdio:['ignore','pipe','pipe']});
  let output='';
  const ready=new Promise((resolve,reject)=>{
    const onData=chunk=>{output+=chunk.toString();if(output.includes('Ready in'))resolve();};
    child.stdout.on('data',onData);child.stderr.on('data',onData);
    child.once('exit',code=>reject(new Error(`Next test server exited ${code}: ${output.slice(-900)}`)));
    setTimeout(()=>reject(new Error(`Next test server did not start: ${output.slice(-900)}`)),60_000).unref();
  });
  await ready;
  const base='http://127.0.0.1:3001';
  const status=()=>fetch(`${base}/api/payment-status`,{method:'POST',headers:{Origin:'https://store.example.test','Content-Type':'application/json'},
    body:JSON.stringify({reference,token})});
  const event=Buffer.from(JSON.stringify({event:'charge.success',data:{reference,amount:1,paid_at:'1970-01-01T00:00:00Z'}}));
  const signature=createHmac('sha512',checkoutSecret).update(event).digest('hex');
  const webhook=sig=>fetch(`${base}/api/paystack-webhook`,{method:'POST',headers:{'x-paystack-signature':sig,'Content-Type':'application/json'},body:event});

  assert.equal((await fetch(`${base}/api/payment-status`)).status,405);
  assert.equal((await fetch(`${base}/api/payment-status`,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})).status,403);
  assert.equal((await webhook('0'.repeat(128))).status,401);
  assert.equal((await fetch(`${base}/api/paystack-webhook`,{method:'POST',body:'x'.repeat(250_001)})).status,413);
  const wrongToken=await fetch(`${base}/api/payment-status`,{method:'POST',headers:{Origin:'https://store.example.test','Content-Type':'application/json'},
    body:JSON.stringify({reference,token:'44444444-4444-4444-8444-444444444444'})});
  assert.equal(wrongToken.status,404);
  assert.equal(paymentCalls,0);
  verifiedStatus='pending';
  assert.equal((await webhook(signature)).status,200);
  assert.equal(state.payment_status,'pending');assert.equal(rpcCalls.length,0);

  verifiedStatus='success';verifiedAmount=8951;
  assert.equal((await webhook(signature)).status,200);
  assert.equal(state.payment_status,'payment_review');
  assert.deepEqual(rpcCalls.map(c=>c.fn),['store_flag_payment_review']);
  console.log('PASS: bad signature ignored; Paystack pending leaves order pending; underpayment never auto-confirms');

  reset();
  const result=await status();
  assert.equal(result.status,200);
  const details=await result.json();
  assert.equal(details.payment_status,'confirmed');
  assert.equal(details.order_status,'processing');
  assert.equal(details.confirmation_source,'paystack');
  assert.equal(rpcCalls.length,1);assert.equal(rpcCalls[0].fn,'store_settle_verified_payment_v2');
  assert.equal(paymentCalls,1);
  // Signed body had amount=1 and a 1970 date; the server used the independent
  // Paystack GET verify result instead. Duplicate webhook cannot settle twice.
  assert.equal((await webhook(signature)).status,200);
  assert.equal(rpcCalls.length,1);
  console.log('PASS: private customer return auto-confirms via verified Paystack GET; duplicate signed webhook is idempotent');

  reset();
  assert.equal((await fetch(`${base}/api/reconcile-pending`)).status,401);
  assert.equal(paymentCalls,0);
  const cron=await fetch(`${base}/api/reconcile-pending`,{headers:{Authorization:`Bearer ${cronSecret}`}});
  assert.equal(cron.status,200);
  assert.equal((await cron.json()).confirmed,1);
  assert.equal(state.payment_status,'confirmed');assert.equal(rpcCalls.length,1);
  console.log('PASS: only the secret-protected cron may reconcile missed webhooks');
} finally {
  if(child?.pid){try{process.kill(-child.pid,'SIGTERM');}catch{}}
  backend.close();
}
