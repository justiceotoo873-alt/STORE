// Import this module from server routes only; never bundle a secret into client code.
import { createHmac, timingSafeEqual } from 'node:crypto';

export type PaymentOrder = { id: string; reference: string; amount_minor: number; currency: string; customer_email: string };
export type PaystackData = {
  status?: unknown; reference?: unknown; amount?: unknown; currency?: unknown; domain?: unknown;
  metadata?: unknown; customer?: { email?: unknown }; paid_at?: unknown
};

export function validPaystackCheckoutUrl(value: unknown): value is string {
  if (typeof value !== 'string') return false;
  try { const u = new URL(value); return u.protocol === 'https:' && u.hostname === 'checkout.paystack.com' && u.username === '' && u.password === ''; }
  catch { return false; }
}

export function validPaystackSignature(raw: Buffer | string, header: string | null, secret: string): boolean {
  if (!header || !/^[a-f0-9]{128}$/i.test(header) || !secret) return false;
  const expected = createHmac('sha512', secret).update(raw).digest();
  const received = Buffer.from(header, 'hex');
  return received.length === expected.length && timingSafeEqual(received, expected);
}

function metadataId(value: unknown): string | undefined {
  let data = value;
  if (typeof data === 'string') {
    try { data = JSON.parse(data); } catch { return undefined; }
  }
  return data && typeof data === 'object' && 'order_id' in data && typeof data.order_id === 'string' ? data.order_id : undefined;
}

export function matchesVerifiedPayment(data: PaystackData, order: PaymentOrder, secret: string): boolean {
  const domain = secret.startsWith('sk_test_') ? 'test' : secret.startsWith('sk_live_') ? 'live' : '';
  return domain !== '' && data.domain === domain && data.status === 'success'
    && data.reference === order.reference && data.amount === order.amount_minor
    && data.currency === 'GHS' && order.currency === 'GHS'
    && typeof data.customer?.email === 'string'
    && data.customer.email.toLowerCase() === order.customer_email.toLowerCase()
    && metadataId(data.metadata) === order.id;
}

// A browser return or webhook arrival time is NOT the payment time. Only the
// timestamp in Paystack's independently verified transaction may be used for
// deciding whether a payment beat the 30-minute stock hold.
export function verifiedPaidAt(data: PaystackData): string | null {
  if (typeof data.paid_at !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/i.test(data.paid_at)) return null;
  const epoch = Date.parse(data.paid_at);
  return Number.isFinite(epoch) ? new Date(epoch).toISOString() : null;
}

async function requestPaystack(path: string, secret: string, init?: RequestInit) {
  if (!secret.startsWith('sk_test_') && !secret.startsWith('sk_live_')) throw new Error('Paystack secret has an invalid format.');
  const response = await fetch(`https://api.paystack.co${path}`, {
    ...init, headers: { Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json', ...init?.headers },
    signal: AbortSignal.timeout(11000), cache: 'no-store'
  });
  const payload = await response.json() as Record<string, unknown>;
  if (!response.ok || payload.status !== true || !payload.data) throw new Error('Paystack did not accept the payment request.');
  return payload.data as Record<string, unknown>;
}

export async function initializePaystack(secret: string, options: {
  email: string; amount_minor: number; reference: string; callback_url: string; order_id: string;
}) {
  const data = await requestPaystack('/transaction/initialize', secret, { method: 'POST', body: JSON.stringify({
    email: options.email, amount: String(options.amount_minor), currency: 'GHS',
    // Let Paystack show only payment channels enabled on this merchant account.
    reference: options.reference,
    callback_url: options.callback_url,
    metadata: JSON.stringify({ order_id: options.order_id })
  }) });
  if (!validPaystackCheckoutUrl(data.authorization_url) || data.reference !== options.reference)
    throw new Error('Paystack returned an untrusted checkout link.');
  return data.authorization_url;
}

export async function verifyPaystack(secret: string, reference: string): Promise<PaystackData> {
  if (!/^[a-zA-Z0-9.=-]{8,80}$/.test(reference)) throw new Error('Invalid Paystack reference.');
  return await requestPaystack(`/transaction/verify/${encodeURIComponent(reference)}`, secret) as PaystackData;
}
