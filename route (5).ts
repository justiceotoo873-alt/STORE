import { validPaystackSignature } from '@/lib/paystack';
import { reconcileStorePayment } from '@/lib/reconcile';
import { json, serviceClient } from '@/lib/server';

export const dynamic = 'force-dynamic';

async function limitedRawBody(request: Request, maxBytes: number): Promise<Buffer | null> {
  if (!request.body) return Buffer.alloc(0);
  const reader=request.body.getReader();
  const chunks:Buffer[]=[];
  let length=0;
  try {
    for (;;) {
      const {done,value}=await reader.read();
      if (done) return Buffer.concat(chunks,length);
      length+=value.byteLength;
      if (length>maxBytes) {await reader.cancel();return null;}
      chunks.push(Buffer.from(value));
    }
  } finally {reader.releaseLock();}
}

export async function POST(request: Request) {
  const secret = process.env.PAYSTACK_SECRET_KEY;
  if (!secret || !process.env.SUPABASE_SERVICE_ROLE_KEY) return json({ error: 'Webhook is not configured.' }, 503);
  if (Number(request.headers.get('content-length') || 0)>250_000) return json({ error: 'Payload too large.' }, 413);
  const body = await limitedRawBody(request,250_000);
  if (!body) return json({ error: 'Payload too large.' }, 413);
  // Authenticating the ORIGINAL bytes is necessary but not sufficient: every
  // charge is also fetched independently from Paystack's verify endpoint.
  if (!validPaystackSignature(body,request.headers.get('x-paystack-signature'),secret))
    return json({ error: 'Invalid signature.' }, 401);
  let event: { event?: string; data?: { reference?: string } };
  try { event = JSON.parse(body.toString('utf8')); }
  catch { return json({ error: 'Invalid webhook.' }, 400); }
  if (event.event !== 'charge.success') return json({ received: true });
  const reference = event.data?.reference;
  if (typeof reference !== 'string' || !/^TG[a-f0-9]{32}$/.test(reference))
    return json({ received: true }); // Not an order created by this store.
  try {
    const client = serviceClient();
    const { data: order, error } = await client.from('store_orders')
      .select('id,reference,customer_email,amount_minor,currency,payment_status')
      .eq('reference',reference).single();
    if (error && error.code !== 'PGRST116') throw error;
    if (!order) {console.error('paystack_unknown_ref',reference);return json({ received: true });}
    await reconcileStorePayment(client,secret,order);
    return json({ received: true });
  } catch (problem) {
    // A non-200 makes Paystack retry. Atomic DB settlement is idempotent.
    console.error('paystack_webhook_retry',problem instanceof Error ? problem.message : 'unknown');
    return json({ error: 'Temporary verification failure.' }, 503);
  }
}
