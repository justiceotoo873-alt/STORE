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
  const expected = process.env.STORE_ORIGIN?.replace(/\/$/, '');
  if (!expected) return false;
  try {
    const parsed = new URL(expected);
    if (parsed.protocol !== 'https:' && !(process.env.NODE_ENV !== 'production' && parsed.hostname === 'localhost')) return false;
    const origin = req.headers.get('origin');
    return !!origin && origin === parsed.origin;
  } catch { return false; }
}

export const json = (body: unknown, status = 200) => Response.json(body, {
  status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
});
