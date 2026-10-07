import { timingSafeEqual } from 'node:crypto';
import { reconcileStorePayment } from '@/lib/reconcile';
import { json, serviceClient } from '@/lib/server';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

// A BACKSTOP for a missed Paystack webhook/closed customer tab, NOT the primary
// payment path. Vercel invokes it only with CRON_SECRET; never permit a browser
// to list pending orders or trigger expensive Paystack API calls unauthenticated.
export async function GET(request: Request) {
  const secret = process.env.CRON_SECRET;
  const expected = Buffer.from(`Bearer ${secret || ''}`);
  const received = Buffer.from(request.headers.get('authorization') || '');
  if (!secret || secret.length < 16 || received.length !== expected.length || !timingSafeEqual(received,expected))
    return json({ error: 'Unauthorized.' }, 401);
  const paystackSecret = process.env.PAYSTACK_SECRET_KEY;
  if (!paystackSecret || !process.env.SUPABASE_SERVICE_ROLE_KEY)
    return json({ error: 'Server is not configured.' }, 503);
  try {
    const client = serviceClient();
    const since = new Date(Date.now()-72*60*60*1000).toISOString();
    const {data: orders,error} = await client.from('store_orders')
      .select('id,reference,customer_email,amount_minor,currency,payment_status')
      .eq('payment_status','pending').gte('created_at',since)
      .order('created_at',{ascending:false}).limit(12);
    if (error) throw error;
    let confirmed=0, needsReview=0, pending=0, failures=0;
    // Limit concurrency/API pressure and fit within typical Vercel function
    // durations. Future runs can retry transient Paystack failures safely.
    for (let i=0;i<(orders?.length || 0);i+=4) {
      const batch = orders!.slice(i,i+4);
      const results=await Promise.allSettled(batch.map((order)=>reconcileStorePayment(client,paystackSecret,order)));
      for (const result of results) {
        if (result.status === 'rejected') { failures++;console.error('paystack_cron_reconcile',result.reason instanceof Error?result.reason.message:'unknown'); }
        else if (result.value === 'confirmed') confirmed++;
        else if (result.value === 'pending') pending++;
        else needsReview++;
      }
    }
    return json({ checked:orders?.length || 0,confirmed,needs_review:needsReview,still_pending:pending,failed:failures },failures?503:200);
  } catch (problem) {
    console.error('paystack_cron_error',problem instanceof Error?problem.message:'unknown');
    return json({ error: 'Reconciliation temporarily unavailable.' }, 503);
  }
}
