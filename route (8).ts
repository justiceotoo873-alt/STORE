import { json, readSizeChart } from '@/lib/server';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) {
  const id = new URL(request.url).searchParams.get('id') || '';
  if (id.length < 1 || id.length > 128) return json({ error: 'Choose a product to view its chart.' }, 400);
  try { return json({ chart: await readSizeChart(id) }); }
  catch (err) {
    console.error('size_chart_error', err instanceof Error ? err.message : 'unknown');
    return json({ error: 'The size chart is temporarily unavailable.' }, 503);
  }
}
