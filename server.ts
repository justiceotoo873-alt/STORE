import 'server-only';
import { createClient } from '@supabase/supabase-js';
import { normalizeCatalog, normalizeSizeChart, validProduct } from './catalog';

export function serviceClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error('Checkout server credentials are not configured.');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function publicRpc(name: string, args: Record<string, unknown>) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) throw new Error('Catalog public connection is not configured.');
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 9000);
  try {
    const response = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/${name}`, {
      method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' },
      body: JSON.stringify(args), cache: 'no-store', signal: controller.signal
    });
    if (!response.ok) throw new Error(`${name} unavailable (HTTP ${response.status}). Apply both reviewed store SQL migrations.`);
    return await response.json() as unknown;
  } finally { clearTimeout(timeout); }
}

export async function readPublicCatalog(page: number, category: string, query: string, sort: string) {
  return normalizeCatalog(await publicRpc('thetieguy_store_catalog_v3', {
    p_page: page, p_limit: 24, p_category: category, p_query: query, p_sort: sort
  }));
}

export async function readCartProducts(ids: string[]) {
  const result = await publicRpc('store_cart_products_v1', { p_ids: ids });
  if (!Array.isArray(result) || !result.every(validProduct)) throw new Error('Cart products are invalid.');
  return result;
}

export async function readSizeChart(id: string) {
  return normalizeSizeChart(await publicRpc('store_size_chart_for_product_v1', { p_product_id: id }));
}

export function checkStoreOrigin(req: Request): boolean {
  const configured = process.env.STORE_ORIGIN?.trim().replace(/\/$/, '');
  if (!configured) return false;
  try {
    const parsed = new URL(configured);
    if (parsed.protocol !== 'https:' && !(process.env.NODE_ENV !== 'production' && parsed.hostname === 'localhost')) return false;
    const origin = req.headers.get('origin');
    const allowed = !!origin && origin === parsed.origin;
    if (!allowed) {
      // Names/addresses only — never keys. This is what you look for in Vercel logs.
      console.error('origin_mismatch', JSON.stringify({
        page_opened_at: origin || '(no Origin header — opened from a file or a sandboxed frame)',
        store_origin_setting: parsed.origin,
        path: new URL(req.url).pathname,
      }));
    }
    return allowed;
  } catch { return false; }
}

/**
 * Owner-facing explanation attached to 403 origin rejections so the store page
 * (and the Vercel log) says what to change instead of only refusing politely.
 * Contains no secrets: both values are public web addresses.
 */
export function storeOriginHint(req: Request) {
  const configured = process.env.STORE_ORIGIN?.trim().replace(/\/$/, '');
  const received = req.headers.get('origin') || '';
  if (!configured) return { code: 'origin_mismatch', hint: 'STORE_ORIGIN is not set for this deployment.' };
  let expected = configured;
  try { expected = new URL(configured).origin; } catch { /* keep raw value for the message */ }
  if (!received) return { code: 'origin_mismatch', hint: `This page sent no Origin header. Open the store in its own browser tab at ${expected}.` };
  if (received !== expected) return { code: 'origin_mismatch', hint: `This page is at ${received} but STORE_ORIGIN is ${expected}. Set STORE_ORIGIN in Vercel to the address customers use, then redeploy — or open the store at ${expected}.` };
  return { code: 'origin_mismatch', hint: `The store's STORE_ORIGIN matches this page but the request was refused. Check the Vercel logs for origin_mismatch.` };
}

export const json = (body: unknown, status = 200) => Response.json(body, {
  status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
});
