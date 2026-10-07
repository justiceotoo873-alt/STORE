import { json, readPublicCatalog } from '@/lib/server';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;
  const pageText = params.get('page') || '1';
  const category = params.get('category') || 'All';
  const query = params.get('q') || '';
  const sort = params.get('sort') || 'featured';
  if (!/^[1-9][0-9]{0,9}$/.test(pageText) || Number(pageText)>2_147_483_647
    || !['All','Ties','Clips','Brooches','Other'].includes(category)
    || query.length > 100 || !['featured','low','high','name'].includes(sort))
    return json({ error: 'Check your collection filters.' }, 400);
  try { return json(await readPublicCatalog(Number(pageText), category, query, sort)); }
  catch (err) {
    console.error('catalog_error', err instanceof Error ? err.message : 'unknown');
    return json({ error: 'The live collection is temporarily unavailable. Please check back soon.' }, 503);
  }
}
