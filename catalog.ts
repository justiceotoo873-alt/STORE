export type StoreProduct = {
  id: string;
  name: string;
  category: string;
  description: string;
  image_url: string;
  sizes: string[];
  price_minor: number;
  available: boolean;
  has_size_chart: boolean;
};
export type DeliveryZone = { id: string; name: string; fee_minor: number };
export type StorefrontOptions = {
  announcement_enabled: boolean; announcement_text: string;
  hero_eyebrow: string; hero_title: string; hero_emphasis: string; hero_final_line: string;
  hero_description: string; hero_visual: 'four-ties' | 'burgundy' | 'bronze' | 'gold' | 'purple'; hero_cta: string;
  promo_enabled: boolean; promo_eyebrow: string; promo_title: string; promo_description: string;
  promo_button: string; promo_image: string; promo_target: 'All' | 'Ties' | 'Clips' | 'Brooches';
};
export type StoreCatalog = {
  business: { name: string; availability: 'available' | 'unavailable'; unavailable_message: string };
  storefront: StorefrontOptions;
  products: StoreProduct[];
  delivery_zones: DeliveryZone[];
  total_count: number; page: number; page_size: number;
};
export type SizeChart = { title: string; units: 'cm' | 'in' | 'other'; columns: string[]; rows: string[][]; notes: string };
export type StoreQuote = {
  subtotal_minor: number; delivery_fee_minor: number | null; discount_minor: number;
  delivery_discount_minor: number; amount_minor: number;
  promotion_name: string | null; promotion_code: string | null; message: string | null;
};

export const defaultStorefront: StorefrontOptions = {
  announcement_enabled: true, announcement_text: 'THE DETAIL MAKES THE DIFFERENCE',
  hero_eyebrow: 'THE TIE GUY · THE SIGNATURE EDIT', hero_title: 'A little detail.', hero_emphasis: 'A lasting',
  hero_final_line: 'impression.',
  hero_description: 'Statement neckties, considered accessories, and the finishing touches that make every entrance your own.',
  hero_visual: 'four-ties', hero_cta: 'Explore the collection', promo_enabled: false,
  promo_eyebrow: '', promo_title: '', promo_description: '', promo_button: 'Shop the edit',
  promo_image: 'hero-tie-gold.jpg', promo_target: 'All'
};
export const blankCatalog: StoreCatalog = {
  business: { name: '@thetieguy', availability: 'unavailable', unavailable_message: 'Online orders are not yet available.' },
  storefront: defaultStorefront, products: [], delivery_zones: [], total_count: 0, page: 1, page_size: 24
};

export function formatGhs(minor: number): string {
  if (!Number.isFinite(minor)) return 'GH₵—';
  return `GH₵${(minor / 100).toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function validProduct(raw: unknown): raw is StoreProduct {
  if (!raw || typeof raw !== 'object') return false;
  const p = raw as Record<string, unknown>;
  return typeof p.id === 'string' && p.id.length > 0 && typeof p.name === 'string'
    && typeof p.category === 'string' && typeof p.description === 'string'
    && typeof p.image_url === 'string' && Array.isArray(p.sizes)
    && p.sizes.every((s: unknown) => typeof s === 'string')
    && Number.isSafeInteger(p.price_minor) && (p.price_minor as number) >= 0
    && typeof p.available === 'boolean' && typeof p.has_size_chart === 'boolean';
}

function validOptions(raw: unknown): raw is StorefrontOptions {
  if (!raw || typeof raw !== 'object') return false;
  const o = raw as Record<string, unknown>;
  const stringKeys = ['announcement_text','hero_eyebrow','hero_title','hero_emphasis','hero_final_line','hero_description',
    'hero_cta','promo_eyebrow','promo_title','promo_description','promo_button'];
  return stringKeys.every((key) => typeof o[key] === 'string')
    && typeof o.announcement_enabled === 'boolean' && typeof o.promo_enabled === 'boolean'
    && ['four-ties','burgundy','bronze','gold','purple'].includes(String(o.hero_visual))
    && ['hero-tie-gold.jpg','hero-tie-burgundy.jpg','hero-tie-bronze.jpg','hero-tie-purple.jpg','tieclips-collection.jpg'].includes(String(o.promo_image))
    && ['All','Ties','Clips','Brooches'].includes(String(o.promo_target));
}

export function normalizeCatalog(input: unknown): StoreCatalog {
  if (!input || typeof input !== 'object') throw new Error('Live catalog has an unexpected format.');
  const raw = input as Record<string, unknown>;
  const business = raw.business as Record<string, unknown> | null;
  if (!business || !Array.isArray(raw.products) || !Array.isArray(raw.delivery_zones) || !validOptions(raw.storefront)
    || !Number.isSafeInteger(raw.total_count) || Number(raw.total_count) < 0
    || !Number.isSafeInteger(raw.page) || Number(raw.page) < 1 || !Number.isSafeInteger(raw.page_size)
    || Number(raw.page_size) < 1 || Number(raw.page_size) > 48 || raw.products.length > Number(raw.page_size))
    throw new Error('Live catalog is missing valid business, products, store options or paging information.');
  if (!raw.products.every(validProduct)) throw new Error('Live catalog contains an invalid product record.');
  const zones: DeliveryZone[] = raw.delivery_zones.map((z: unknown) => {
    if (!z || typeof z !== 'object') throw new Error('Live catalog contains an invalid delivery zone.');
    const v = z as Record<string, unknown>;
    if (typeof v.id !== 'string' || typeof v.name !== 'string'
      || !Number.isSafeInteger(v.fee_minor) || (v.fee_minor as number) < 0)
      throw new Error('Live catalog contains an invalid delivery zone.');
    return { id: v.id, name: v.name, fee_minor: v.fee_minor as number };
  });
  return {
    business: {
      name: typeof business.name === 'string' ? business.name : '@thetieguy',
      availability: business.availability === 'available' ? 'available' : 'unavailable',
      unavailable_message: typeof business.unavailable_message === 'string' ? business.unavailable_message : ''
    },
    storefront: raw.storefront,
    products: raw.products,
    delivery_zones: zones,
    total_count: raw.total_count as number, page: raw.page as number, page_size: raw.page_size as number
  };
}

export function normalizeSizeChart(input: unknown): SizeChart | null {
  if (input === null) return null;
  if (!input || typeof input !== 'object') throw new Error('Invalid size chart.');
  const chart = input as Record<string, unknown>;
  const columns = chart.columns;
  if (typeof chart.title !== 'string' || !['cm','in','other'].includes(String(chart.units))
    || !Array.isArray(columns) || columns.length < 2 || columns.length > 6
    || !columns.every((cell: unknown) => typeof cell === 'string')
    || !Array.isArray(chart.rows) || chart.rows.length > 35 || !chart.rows.every((row: unknown) =>
      Array.isArray(row) && row.length === columns.length && row.every((cell: unknown) => typeof cell === 'string'))
    || typeof chart.notes !== 'string') throw new Error('Invalid size chart.');
  return chart as SizeChart;
}

export function normalizeQuote(input: unknown): StoreQuote {
  if (!input || typeof input !== 'object') throw new Error('Invalid price quote.');
  const q = input as Record<string, unknown>;
  if (!['subtotal_minor','discount_minor','delivery_discount_minor','amount_minor'].every((key) => Number.isSafeInteger(q[key]) && Number(q[key]) >= 0)
    || (q.delivery_fee_minor !== null && (!Number.isSafeInteger(q.delivery_fee_minor) || Number(q.delivery_fee_minor) < 0))
    || !['promotion_name','promotion_code','message'].every((key) => q[key] === null || typeof q[key] === 'string')
    || Number(q.amount_minor) !== Number(q.subtotal_minor) - Number(q.discount_minor)
       + Number(q.delivery_fee_minor || 0) - Number(q.delivery_discount_minor) || Number(q.amount_minor) < 1)
    throw new Error('Invalid price quote.');
  return q as StoreQuote;
}

export function categoryFor(product: Pick<StoreProduct, 'name' | 'category'>): 'Ties' | 'Clips' | 'Brooches' | 'Other' {
  const text = `${product.category} ${product.name}`.toLowerCase();
  if (/brooch|pin|lapel|pharmacy|medical|laboratory|research|law/.test(text)) return 'Brooches';
  if (/clip|bar/.test(text)) return 'Clips';
  if (/tie|necktie|paisley|floral/.test(text)) return 'Ties';
  return 'Other';
}

export function safeImage(value: string): string {
  if (!value) return '';
  try { const url = new URL(value); return url.protocol === 'https:' ? url.href : ''; }
  catch { return ''; }
}
