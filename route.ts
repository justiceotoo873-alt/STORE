import { json, readCartProducts } from '@/lib/server';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) {
  const ids = new URL(request.url).searchParams.getAll('id');
  if (ids.length < 1 || ids.length > 8 || new Set(ids).size !== ids.length || ids.some((id) => id.length < 1 || id.length > 128))
    return json({ error: 'Your bag has too many different items or invalid products.' }, 400);
  try { return json({ products: await readCartProducts(ids) }); }
  catch (err) {
    console.error('cart_products_error', err instanceof Error ? err.message : 'unknown');
    return json({ error: 'Your bag could not be refreshed. Please try again.' }, 503);
  }
}
