import { createHmac } from 'node:crypto';
import { initializePaystack } from '@/lib/paystack';
import { checkStoreOrigin, json, serviceClient } from '@/lib/server';

export const dynamic = 'force-dynamic';

type Input = { customer?: { name?: unknown; email?: unknown; phone?: unknown; notes?: unknown };
  items?: Array<{ id?: unknown; size?: unknown; quantity?: unknown }>;
  fulfillment_method?: unknown; zone_id?: unknown; delivery_address?: unknown; website?: unknown;
  discount_code?: unknown; expected_amount_minor?: unknown };

function validated(input: Input) {
  const name = typeof input.customer?.name === 'string' ? input.customer.name.trim() : '';
  const email = typeof input.customer?.email === 'string' ? input.customer.email.trim().toLowerCase() : '';
  const phone = typeof input.customer?.phone === 'string' ? input.customer.phone.trim() : '';
  const notes = typeof input.customer?.notes === 'string' ? input.customer.notes.trim() : '';
  const address = typeof input.delivery_address === 'string' ? input.delivery_address.trim() : '';
  const method = input.fulfillment_method;
  const discountCode = typeof input.discount_code === 'string' ? input.discount_code.trim().toUpperCase() : '';
  const expectedAmount = input.expected_amount_minor;
  const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
  if (name.length < 2 || name.length > 100 || email.length < 5 || email.length > 254
    || !/^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(email)
    || phone.length < 9 || phone.length > 24 || !/^[+0-9 ()-]+$/.test(phone)
    || notes.length > 500 || !Array.isArray(input.items) || input.items.length < 1 || input.items.length > 8
    || (method !== 'pickup' && method !== 'delivery')
    || (method === 'delivery' && (address.length < 8 || address.length > 350))
    || (method === 'pickup' && address !== '')
    || (input.zone_id != null && input.zone_id !== '' && (typeof input.zone_id !== 'string' || !uuid.test(input.zone_id)))
    || (input.discount_code != null && typeof input.discount_code !== 'string')
    || discountCode.length > 24 || (discountCode && !/^[A-Z0-9-]{4,24}$/.test(discountCode))
    || !Number.isSafeInteger(expectedAmount) || Number(expectedAmount) < 1 || Number(expectedAmount) > 2_000_000_000)
    throw new Error('Please check your details, delivery choice, discount, and live quote.');
  const seen = new Set<string>();
  const items = input.items.map((item) => {
    if (typeof item.id !== 'string' || item.id.length < 1 || item.id.length > 128
      || typeof item.size !== 'string' || item.size.length < 1 || item.size.length > 80
      || !Number.isInteger(item.quantity) || Number(item.quantity) < 1 || Number(item.quantity) > 10)
      throw new Error('Please check your bag and product options.');
    const key = `${item.id}\0${item.size}`;
    if (seen.has(key)) throw new Error('Combine duplicate products and sizes in your bag.');
    seen.add(key);
    return { id: item.id, size: item.size, quantity: item.quantity };
  });
  return { customer: { name, email, phone, notes }, items,
    fulfillment_method: method, zone_id: method === 'delivery' && typeof input.zone_id === 'string' && input.zone_id ? input.zone_id : null,
    delivery_address: method === 'delivery' ? address : '', discount_code: discountCode,
    expected_amount_minor: expectedAmount as number };
}

const safeErrors = ['Online orders are paused', 'Not enough stock', 'An item is no longer available',
  'A size is no longer available', 'The selected delivery zone is no longer available',
  'Too many checkout attempts', 'Invalid product', 'Duplicate product', 'Cart total exceeds checkout limits',
  'Discount code is unavailable', 'Check the discount code', 'Price or promotion changed'];

export async function POST(request: Request) {
  if (!process.env.PAYSTACK_SECRET_KEY || !process.env.SUPABASE_SERVICE_ROLE_KEY || !process.env.STORE_ORIGIN)
    return json({ error: 'Online checkout is not ready. Please come back soon.' }, 503);
  if (!checkStoreOrigin(request)) return json({ error: 'Please use the official store to place an order.' }, 403);
  if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json')) return json({ error: 'Expected JSON.' }, 415);
  if (Number(request.headers.get('content-length') || 0) > 12_000) return json({ error: 'Checkout request is too large.' }, 413);
  try {
    const raw = await request.text();
    if (raw.length > 12_000) return json({ error: 'Checkout request is too large.' }, 413);
    const input = JSON.parse(raw) as Input;
    // A hidden honeypot deters simple automated submissions, but is not a CAPTCHA.
    if (input.website) return json({ error: 'Please try again.' }, 400);
    const details = validated(input);
    const secret = process.env.PAYSTACK_SECRET_KEY;
    if (!secret) return json({ error: 'Checkout not ready.' }, 503);
    const forwarded = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
      || request.headers.get('x-real-ip') || 'unknown';
    const clientHash = createHmac('sha256',secret).update(forwarded).digest('hex');
    const client = serviceClient();
    const { data, error } = await client.rpc('store_create_checkout_order_v2', {
      p_customer: details.customer, p_items: details.items, p_method: details.fulfillment_method,
      p_zone_id: details.zone_id, p_address: details.delivery_address, p_client_hash: clientHash,
      p_code: details.discount_code, p_expected_amount_minor: details.expected_amount_minor
    });
    if (error) {
      console.error('store_order_create', error.message, error.code);
      if (error.message.startsWith('Not enough stock')) {
        // The DB independently checks stock + active reservations. No customer
        // identifiers are sent to this dashboard-only, hourly-deduped alert.
        for (const id of new Set(details.items.map((line) => line.id))) {
          const note = await client.rpc('store_note_checkout_stock_issue', { p_product_id: id });
          if (note.error) console.error('store_stock_alert', note.error.message);
        }
      }
      const message = safeErrors.find((word) => error.message.startsWith(word));
      return json({ error: message ? error.message : 'The order could not be placed. Please review your bag and try again.' }, 400);
    }
    const order = data as { id?: unknown; reference?: unknown; token?: unknown; amount_minor?: unknown; order_number?: unknown } | null;
    if (!order || typeof order.id !== 'string' || typeof order.reference !== 'string'
      || typeof order.token !== 'string' || !Number.isSafeInteger(order.amount_minor))
      throw new Error('Store server returned an incomplete order.');
    // Never infer callback_url from an untrusted Host header or customer input.
    const callback = `${process.env.STORE_ORIGIN?.replace(/\/$/,'')}/order/return`;
    const destination = await initializePaystack(secret, { email: details.customer.email,
      amount_minor: order.amount_minor as number, reference: order.reference, order_id: order.id, callback_url: callback });
    return json({ authorization_url: destination, reference: order.reference, token: order.token, order_number: order.order_number }, 201);
  } catch (err) {
    console.error('checkout_error', err instanceof Error ? err.message : 'unknown');
    if (err instanceof SyntaxError) return json({ error: 'Checkout form is invalid.' }, 400);
    if (err instanceof Error && (err.message.startsWith('Please check') || err.message.startsWith('Combine duplicate')))
      return json({ error: err.message }, 400);
    return json({ error: 'Payment could not be started. Please wait a moment and try again; contact us if you were charged.' }, 503);
  }
}
