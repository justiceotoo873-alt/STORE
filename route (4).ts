import { reconcileStorePayment } from '@/lib/reconcile';
import { checkStoreOrigin, json, serviceClient, storeOriginHint } from '@/lib/server';

export const dynamic = 'force-dynamic';
export async function POST(request: Request) {
  // This action may settle a payment, so require a same-origin POST. Never put
  // the private checkout token in a GET URL, referrer or server access log.
  if (!checkStoreOrigin(request)) return json({ error: 'Use the official store to check your order.', ...storeOriginHint(request) }, 403);
  if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json'))
    return json({ error: 'Expected JSON.' }, 415);
  if (Number(request.headers.get('content-length') || 0)>1024) return json({ error: 'Invalid request.' }, 413);
  let reference='';let token='';
  try {
    const raw=await request.text();
    if (raw.length>1024) return json({ error: 'Invalid request.' }, 413);
    const input=JSON.parse(raw) as {reference?:unknown;token?:unknown};
    reference=typeof input.reference==='string'?input.reference:'';
    token=typeof input.token==='string'?input.token:'';
  } catch { return json({ error: 'Invalid request.' }, 400); }
  if (!/^TG[a-f0-9]{32}$/.test(reference) || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(token))
    return json({ error: 'Check your order reference.' }, 400);
  const secret = process.env.PAYSTACK_SECRET_KEY;
  if (!secret || !process.env.SUPABASE_SERVICE_ROLE_KEY)
    return json({ error: 'Payment verification is unavailable. Please try again later.' }, 503);
  try {
    const client = serviceClient();
    const { data: order, error } = await client.from('store_orders')
      .select('id,reference,checkout_token,order_number,customer_email,amount_minor,currency,payment_status,order_status,reservation_expires_at')
      .eq('reference',reference).eq('checkout_token',token).single();
    if (error && error.code !== 'PGRST116') throw error;
    if (!order) return json({ error: 'Order not found. Check your reference and retry.' }, 404);

    let verifyDelayed = false;
    if (order.payment_status === 'pending' || order.payment_status === 'provider_verified') {
      try { await reconcileStorePayment(client,secret,order); }
      catch (problem) {
        verifyDelayed = true;
        console.error('paystack_verify_pending',problem instanceof Error ? problem.message : 'unknown');
      }
    }
    // Re-read after settlement (or a concurrent webhook): status, order status,
    // and confirmation source must be from one committed DB row, not stale data.
    const { data: current, error: refreshed } = await client.from('store_orders')
      .select('order_number,payment_status,order_status,reservation_expires_at,confirmation_source,amount_minor,currency')
      .eq('id',order.id).single();
    if (refreshed || !current) throw refreshed || new Error('Order status unavailable');
    const state = String(current.payment_status);
    const paid = ['provider_verified','confirmed','refund_needed','refunded'].includes(state);
    const expired = new Date(current.reservation_expires_at).getTime() < Date.now() && state !== 'confirmed';
    return json({ order_number: current.order_number, reference,
      amount_minor: current.amount_minor, currency: current.currency,
      payment_status: state, order_status: current.order_status,
      confirmation_source: current.confirmation_source,
      paid_with_paystack: paid, reservation_expired: expired,
      message: state === 'confirmed'
        ? current.confirmation_source === 'paystack'
          ? 'Paystack securely verified your payment and your order was automatically confirmed. Our team will arrange fulfilment.'
          : 'Our team has confirmed your payment and will arrange fulfilment.'
        : state === 'provider_verified'
          ? 'Paystack verified your payment. Your order needs a manual exception review before fulfilment.'
        : state === 'payment_review'
          ? 'This charge needs a manual payment review. Keep your reference, do not pay again, and contact @thetieguy.'
        : state === 'refund_needed'
          ? 'Your Paystack payment needs urgent fulfilment or refund review. Do not pay again; contact @thetieguy.'
        : state === 'refunded'
          ? 'This payment has been marked refunded by our team.'
        : verifyDelayed
          ? 'We could not reach Paystack just now. If you were charged, do not pay again; check back or contact @thetieguy.'
          : 'We are waiting for Paystack to finish processing your payment. You can check again shortly.'
    });
  } catch (problem) {
    console.error('payment_status_error',problem instanceof Error ? problem.message : 'unknown');
    return json({ error: 'Payment status is temporarily unavailable. Please try again later.' }, 503);
  }
}
