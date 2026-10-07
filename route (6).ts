import { normalizeQuote } from '@/lib/catalog';
import { checkStoreOrigin, json, serviceClient } from '@/lib/server';
export const dynamic = 'force-dynamic';

type Input = {
  items?: Array<{ id?: unknown; size?: unknown; quantity?: unknown }>;
  fulfillment_method?: unknown; zone_id?: unknown; discount_code?: unknown; email?: unknown;
};
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
const safeErrors = ['Not enough stock', 'An item or size is no longer available', 'The selected delivery zone is no longer available',
  'Discount code is unavailable', 'Check the discount code', 'Online orders are paused', 'Invalid product',
  'Choose between', 'Duplicate product', 'Product price requires review', 'Cart total exceeds'];

export async function POST(request: Request) {
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY || !process.env.PAYSTACK_SECRET_KEY || !process.env.STORE_ORIGIN)
    return json({ error: 'Secure checkout is not available yet.' }, 503);
  if (!checkStoreOrigin(request)) return json({ error: 'Please use the official store to request a quote.' }, 403);
  if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json')) return json({ error: 'Expected JSON.' }, 415);
  if (Number(request.headers.get('content-length') || 0) > 6000) return json({ error: 'Quote request is too large.' }, 413);
  try {
    const raw = await request.text();
    if (raw.length > 6000) return json({ error: 'Quote request is too large.' }, 413);
    const input = JSON.parse(raw) as Input;
    const method = input.fulfillment_method;
    const email = typeof input.email === 'string' ? input.email.trim().toLowerCase() : '';
    const code = typeof input.discount_code === 'string' ? input.discount_code.trim().toUpperCase() : '';
    const zone = typeof input.zone_id === 'string' && input.zone_id ? input.zone_id : null;
    if (!Array.isArray(input.items) || input.items.length < 1 || input.items.length > 8
      || (method !== 'pickup' && method !== 'delivery') || (method === 'pickup' && zone !== null)
      || (zone !== null && !uuid.test(zone))
      || email.length < 5 || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(email)
      || code.length > 24 || (code && !/^[A-Z0-9-]{4,24}$/.test(code)))
      return json({ error: 'Add a valid email and check the bag, delivery choice and discount code.' }, 400);
    const seen = new Set<string>();
    const items = input.items.map((item) => {
      if (!item || typeof item.id !== 'string' || item.id.length < 1 || item.id.length > 128
        || typeof item.size !== 'string' || item.size.length < 1 || item.size.length > 80
        || !Number.isInteger(item.quantity) || Number(item.quantity) < 1 || Number(item.quantity) > 10)
        throw new Error('Check product choices and quantities.');
      const key = `${item.id}\0${item.size}`;
      if (seen.has(key)) throw new Error('Combine duplicate products and sizes in your bag.');
      seen.add(key);
      return { id: item.id, size: item.size, quantity: item.quantity };
    });
    const { data, error } = await serviceClient().rpc('store_quote_v1', {
      p_items: items, p_method: method, p_zone_id: method === 'delivery' ? zone : null,
      p_code: code, p_email: email
    });
    if (error) {
      console.error('store_quote', error.message, error.code);
      return json({ error: safeErrors.some((start) => error.message.startsWith(start)) ? error.message : 'The live quote could not be prepared. Please try again.' }, 400);
    }
    return json(normalizeQuote(data));
  } catch (err) {
    console.error('quote_error', err instanceof Error ? err.message : 'unknown');
    if (err instanceof SyntaxError) return json({ error: 'Quote request is invalid.' }, 400);
    if (err instanceof Error && (err.message.startsWith('Check product') || err.message.startsWith('Combine duplicate')))
      return json({ error: err.message }, 400);
    return json({ error: 'The live quote is temporarily unavailable.' }, 503);
  }
}
