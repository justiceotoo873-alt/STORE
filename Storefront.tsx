'use client';

import { useEffect, useMemo, useState } from 'react';
import type { FormEvent } from 'react';
import { ArrowRight, ArrowUpRight, Check, ChevronDown, Instagram, Mail, Menu, Minus, Plus, Search, ShieldCheck, ShoppingBag, SlidersHorizontal, Truck, X } from 'lucide-react';
import { blankCatalog, categoryFor, formatGhs, safeImage } from '@/lib/catalog';
import type { SizeChart, StoreCatalog, StoreProduct, StoreQuote } from '@/lib/catalog';

type CartLine = { id: string; size: string; quantity: number };
type Filter = 'All' | 'Ties' | 'Clips' | 'Brooches' | 'Other';
type CheckoutState = { name: string; email: string; phone: string; method: 'pickup' | 'delivery'; zone_id: string; address: string; notes: string; website: string };
const emptyCheckout: CheckoutState = { name: '', email: '', phone: '', method: 'delivery', zone_id: '', address: '', notes: '', website: '' };
const CATEGORIES: Filter[] = ['All', 'Ties', 'Clips', 'Brooches', 'Other'];

function scrollToShop() { document.getElementById('shop')?.scrollIntoView({ behavior: 'smooth' }); }
function IconMark({ size = 22 }: { size?: number }) { return <img src="/brand/tie-icon.png" width={size} height={size} alt="" className="mark-icon" />; }
function ProductImage({ product, className = '' }: { product: StoreProduct; className?: string }) {
  const img = safeImage(product.image_url);
  return img ? <img src={img} loading="lazy" alt={product.name} className={className} /> :
    <div className={`product-fallback ${className}`} role="img" aria-label={`Image not yet uploaded for ${product.name}`}><IconMark size={82} /><span>IMAGE COMING SOON</span></div>;
}

export default function Storefront() {
  const [catalog, setCatalog] = useState<StoreCatalog>(blankCatalog);
  const [catalogError, setCatalogError] = useState('');
  const [loading, setLoading] = useState(true);
  const [checkoutReady, setCheckoutReady] = useState(false);
  const [testMode, setTestMode] = useState(false);
  const [cart, setCart] = useState<CartLine[]>([]);
  const [cartLoaded, setCartLoaded] = useState(false);
  const [cartOpen, setCartOpen] = useState(false);
  const [checkoutOpen, setCheckoutOpen] = useState(false);
  const [selected, setSelected] = useState<StoreProduct | null>(null);
  const [size, setSize] = useState('One size');
  const [quantity, setQuantity] = useState(1);
  const [filter, setFilter] = useState<Filter>('All');
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<'featured'|'low'|'high'|'name'>('featured');
  const [page, setPage] = useState(1);
  const [searchTerm, setSearchTerm] = useState('');
  const [catalogRevision, setCatalogRevision] = useState(0);
  const [cartProducts, setCartProducts] = useState<StoreProduct[]>([]);
  const [cartError, setCartError] = useState('');
  const [cartLoading, setCartLoading] = useState(false);
  const [cartRevision, setCartRevision] = useState(0);
  const [sizeChart, setSizeChart] = useState<SizeChart | null>(null);
  const [chartLoading, setChartLoading] = useState(false);
  const [chartError, setChartError] = useState('');
  const [showChart, setShowChart] = useState(false);
  const [discountCode, setDiscountCode] = useState('');
  const [quote, setQuote] = useState<StoreQuote | null>(null);
  const [quoteKey, setQuoteKey] = useState('');
  const [quoteBusy, setQuoteBusy] = useState(false);
  const [quoteError, setQuoteError] = useState('');
  const [quoteRevision, setQuoteRevision] = useState(0);
  const [mobileMenu, setMobileMenu] = useState(false);
  const [form, setForm] = useState<CheckoutState>(emptyCheckout);
  const [orderBusy, setOrderBusy] = useState(false);
  const [checkoutError, setCheckoutError] = useState('');
  const [notice, setNotice] = useState('');

  useEffect(() => {
    const timer = setTimeout(() => { setSearchTerm(search.trim()); setPage(1); }, 320);
    return () => clearTimeout(timer);
  }, [search]);
  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    setCatalogError(''); setLoading(true);
    const params = new URLSearchParams({ page: String(page), category: filter, q: searchTerm, sort });
    void fetch(`/api/catalog?${params}`, { cache: 'no-store', signal: controller.signal })
      .then(async (r) => {
        const data: StoreCatalog | { error: string } = await r.json();
        if (!r.ok || 'error' in data) throw new Error('error' in data ? data.error : 'The collection could not be loaded.');
        if (current) setCatalog(data);
      }).catch((e: unknown) => { if (current) setCatalogError(e instanceof Error ? e.message : 'The collection could not be loaded.'); })
      .finally(() => { if (current) setLoading(false); });
    return () => { current = false; controller.abort(); };
  }, [page, filter, searchTerm, sort, catalogRevision]);
  useEffect(() => {
    void fetch('/api/config').then((r) => r.json()).then((data) => {
      setCheckoutReady(data.checkout_enabled === true); setTestMode(data.test_mode === true);
    }).catch(() => setCheckoutReady(false));
    try {
      const previous: unknown = JSON.parse(localStorage.getItem('thetieguy-store-cart-v1') || '[]');
      if (Array.isArray(previous)) setCart(previous.filter((line: unknown) => {
        if (!line || typeof line !== 'object') return false;
        const v = line as Record<string, unknown>;
        return typeof v.id === 'string' && typeof v.size === 'string' && Number.isInteger(v.quantity) && Number(v.quantity) > 0 && Number(v.quantity) <= 10;
      }).slice(0, 30));
    } catch { /* A bad browser cart cannot block the collection. */ }
    setCartLoaded(true);
  }, []);
  useEffect(() => { if (cartLoaded) try { localStorage.setItem('thetieguy-store-cart-v1', JSON.stringify(cart)); } catch { /* Private mode may block storage. */ } }, [cart, cartLoaded]);
  const cartIds = useMemo(() => JSON.stringify([...new Set(cart.map((line) => line.id))].sort()), [cart]);
  useEffect(() => {
    if (!cartLoaded) return;
    const ids = JSON.parse(cartIds) as string[];
    if (!ids.length) { setCartProducts([]); setCartError(''); setCartLoading(false); return; }
    if (ids.length > 8 || cart.length > 8) {
      setCartError('The bag supports up to eight different product options. Remove extras to continue.');
      setCartProducts([]); setCartLoading(false); return;
    }
    let current = true;
    const controller = new AbortController();
    setCartLoading(true); setCartError('');
    const params = new URLSearchParams();
    ids.forEach((id) => params.append('id', id));
    void fetch(`/api/cart-products?${params}`, { cache: 'no-store', signal: controller.signal })
      .then(async (r) => {
        const data = await r.json() as { products?: StoreProduct[]; error?: string };
        if (!r.ok || !Array.isArray(data.products)) throw new Error(data.error || 'Could not refresh your bag.');
        if (current) setCartProducts(data.products);
      }).catch((e: unknown) => {
        if (current) { setCartProducts([]); setCartError(e instanceof Error ? e.message : 'Could not refresh your bag.'); }
      }).finally(() => { if (current) setCartLoading(false); });
    return () => { current = false; controller.abort(); };
  }, [cartIds, cartLoaded, cartOpen, checkoutOpen, cart.length, cartRevision]);
  useEffect(() => {
    if (!selected || !selected.has_size_chart) { setSizeChart(null); setChartError(''); setShowChart(false); return; }
    let current = true;
    const controller = new AbortController();
    setChartLoading(true); setSizeChart(null); setChartError(''); setShowChart(false);
    void fetch(`/api/size-chart?id=${encodeURIComponent(selected.id)}`, { cache: 'no-store', signal: controller.signal })
      .then(async (r) => {
        const data = await r.json() as { chart?: SizeChart | null; error?: string };
        if (!r.ok) throw new Error(data.error || 'The size guide could not be loaded.');
        if (current) setSizeChart(data.chart || null);
      }).catch((e: unknown) => { if (current) setChartError(e instanceof Error ? e.message : 'The size guide could not be loaded.'); })
      .finally(() => { if (current) setChartLoading(false); });
    return () => { current = false; controller.abort(); };
  }, [selected]);
  useEffect(() => {
    const onEscape = (e: KeyboardEvent) => { if (e.key === 'Escape') { setSelected(null); setCartOpen(false); setCheckoutOpen(false); setMobileMenu(false); } };
    document.addEventListener('keydown', onEscape);
    document.body.style.overflow = cartOpen || checkoutOpen || selected ? 'hidden' : '';
    return () => { document.removeEventListener('keydown', onEscape); document.body.style.overflow = ''; };
  }, [cartOpen, checkoutOpen, selected]);
  useEffect(() => {
    if (!notice) return;
    const timer = setTimeout(() => setNotice(''), 3400);
    return () => clearTimeout(timer);
  }, [notice]);

  // The database filters/sorts ALL published listings before returning a page.
  const filtered = catalog.products;
  const inCart = useMemo(() => cart.flatMap((line) => {
    const p = cartProducts.find((product) => product.id === line.id && product.available && product.sizes.includes(line.size));
    return p ? [{ ...line, product: p }] : [];
  }), [cart, cartProducts]);
  const unavailableLines = cart.filter((line) => !inCart.some((valid) => valid.id === line.id && valid.size === line.size));
  const count = inCart.reduce((total, line) => total + line.quantity, 0);
  const subtotal = inCart.reduce((total, line) => total + line.product.price_minor * line.quantity, 0);
  const zone = catalog.delivery_zones.find((z) => z.id === form.zone_id);
  const deliveryFee = form.method === 'pickup' ? 0 : zone ? zone.fee_minor : null;
  const orderingPaused = catalog.business.availability !== 'available';
  const emailValid = /^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(form.email.trim());
  const quotePayload = JSON.stringify({ items: cart.map((line) => ({ id: line.id, size: line.size, quantity: line.quantity })),
    fulfillment_method: form.method, zone_id: form.method === 'delivery' ? form.zone_id || null : null,
    email: form.email.trim().toLowerCase(), discount_code: discountCode.trim().toUpperCase() });
  const quoteEligible = cartLoaded && !cartLoading && !cartError && !unavailableLines.length
    && cart.length > 0 && cart.length <= 8 && emailValid && checkoutReady && !orderingPaused;
  useEffect(() => {
    if (!quoteEligible) { setQuote(null); setQuoteKey(''); setQuoteBusy(false); setQuoteError(''); return; }
    let current = true;
    const controller = new AbortController();
    setQuote(null); setQuoteKey(''); setQuoteError(''); setQuoteBusy(true);
    const timer = setTimeout(() => {
      void fetch('/api/quote', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: quotePayload, signal: controller.signal }).then(async (r) => {
          const data = await r.json() as StoreQuote & { error?: string };
          if (!r.ok) throw new Error(data.error || 'Your live quote is unavailable.');
          if (current) { setQuote(data); setQuoteKey(quotePayload); }
        }).catch((e: unknown) => { if (current) setQuoteError(e instanceof Error ? e.message : 'Your live quote is unavailable.'); })
        .finally(() => { if (current) setQuoteBusy(false); });
    }, 360);
    return () => { current = false; clearTimeout(timer); controller.abort(); };
  }, [quotePayload, quoteEligible, quoteRevision]);
  const quoteCurrent = quote !== null && quoteKey === quotePayload;
  const total = quoteCurrent ? quote.amount_minor : subtotal + (deliveryFee || 0);
  const readyForCheckout = !loading && !catalogError && cartLoaded && !cartLoading && !cartError
    && !unavailableLines.length && count > 0 && !orderingPaused && checkoutReady && quoteCurrent && !quoteBusy;

  const selectCategory = (next: Filter) => { setFilter(next); setPage(1); setMobileMenu(false); scrollToShop(); };
  const openProduct = (product: StoreProduct) => { if (!product.available) return; setSelected(product); setSize(product.sizes[0] || 'One size'); setQuantity(1); };
  const add = (id: string, chosen: string, qty: number) => {
    if (cart.length >= 8 && !cart.some((line) => line.id === id && line.size === chosen)) {
      setNotice('A checkout supports up to eight different product options.'); return;
    }
    setCart((previous) => {
      const exists = previous.find((line) => line.id === id && line.size === chosen);
      return exists ? previous.map((line) => line === exists ? { ...line, quantity: Math.min(10, line.quantity + qty) } : line) :
        [...previous, { id, size: chosen, quantity: qty }];
    });
    setSelected(null); setNotice('Added to your bag'); setCartOpen(true);
  };
  const changeQuantity = (id: string, chosen: string, difference: number) => setCart((previous) => previous.flatMap((line) => {
    if (line.id !== id || line.size !== chosen) return [line];
    const next = line.quantity + difference;
    return next < 1 ? [] : [{ ...line, quantity: Math.min(next, 10) }];
  }));
  const remove = (id: string, chosen: string) => setCart((previous) => previous.filter((line) => line.id !== id || line.size !== chosen));

  async function submitOrder(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); setCheckoutError('');
    if (!readyForCheckout || !quote) { setCheckoutError('Wait for a valid live price quote before paying. Check your email, bag and offer code.'); return; }
    if (form.method === 'delivery' && !form.address.trim()) { setCheckoutError('Please add a delivery address.'); return; }
    setOrderBusy(true);
    try {
      const response = await fetch('/api/checkout', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ customer: { name: form.name, email: form.email, phone: form.phone, notes: form.notes },
          fulfillment_method: form.method, zone_id: form.zone_id || null, delivery_address: form.method === 'delivery' ? form.address : '',
          items: inCart.map((line) => ({ id: line.id, size: line.size, quantity: line.quantity })),
          discount_code: discountCode.trim().toUpperCase(), expected_amount_minor: quote.amount_minor,
          website: form.website }) });
      const result = await response.json();
      if (!response.ok) throw new Error(typeof result.error === 'string' ? result.error : 'Checkout could not be started.');
      const destination = new URL(result.authorization_url);
      if (destination.protocol !== 'https:' || destination.hostname !== 'checkout.paystack.com') throw new Error('Payment link did not pass the safety check.');
      if (typeof result.reference !== 'string' || typeof result.token !== 'string') throw new Error('Checkout confirmation is incomplete.');
      sessionStorage.setItem(`thetieguy-order-${result.reference}`, result.token);
      window.location.assign(destination.href);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Checkout could not be started.';
      setCheckoutError(message);
      if (/price or promotion changed|discount code|not enough stock/i.test(message)) setQuoteRevision((value) => value + 1);
      setOrderBusy(false);
    }
  }

  const heroLooks = ['bronze','burgundy','gold','purple'] as const;
  const heroVisual = catalog.storefront.hero_visual;
  const arrangedTies = heroVisual === 'four-ties' ? heroLooks :
    [heroVisual, ...heroLooks.filter((look) => look !== heroVisual)];
  return <div className="site-shell">
    {catalog.storefront.announcement_enabled && <div className="announcement"><span>{catalog.storefront.announcement_text}</span><span className="announcement-star">✦</span><span>EXPLORE THE COLLECTION</span></div>}
    <header className="site-header">
      <a className="logo" href="#top" aria-label="The Tie Guy — back to top"><img src="/brand/logo-header.png" alt="THE TIE GUY — Ties. Clips. Brooches" /></a>
      <nav className={`desktop-nav ${mobileMenu ? 'nav-open' : ''}`} aria-label="Main navigation">
        <button onClick={() => selectCategory('All')}>Shop all</button><button onClick={() => selectCategory('Ties')}>Neckties</button>
        <button onClick={() => selectCategory('Clips')}>Tie clips</button><button onClick={() => selectCategory('Brooches')}>Brooches</button>
        <a href="#the-edit" onClick={() => setMobileMenu(false)}>The edit</a>
      </nav>
      <div className="header-actions"><button className="header-search" onClick={() => { scrollToShop(); setTimeout(() => document.querySelector<HTMLInputElement>('#shop-search')?.focus(), 400); }} aria-label="Search the collection"><Search size={21} strokeWidth={1.7} /></button>
        <button className="bag-trigger" onClick={() => setCartOpen(true)} aria-label={`Open bag with ${count} items`}><ShoppingBag size={22} strokeWidth={1.7} /><span>{count}</span></button>
        <button className="menu-trigger" onClick={() => setMobileMenu((v) => !v)} aria-label="Open menu" aria-expanded={mobileMenu}>{mobileMenu ? <X size={24} /> : <Menu size={24} />}</button></div>
    </header>

    <main id="top">
      <section className="hero" aria-labelledby="hero-heading"><div className="hero-copy"><div className="eyebrow"><span className="small-line" /> {catalog.storefront.hero_eyebrow}</div>
        <h1 id="hero-heading">{catalog.storefront.hero_title}<br /><em>{catalog.storefront.hero_emphasis}</em><br />{catalog.storefront.hero_final_line}</h1>
        <p>{catalog.storefront.hero_description}</p>
        <div className="hero-buttons"><button className="button button-dark" onClick={() => selectCategory('All')}>{catalog.storefront.hero_cta} <ArrowUpRight size={20} /></button><a className="text-link" href="#the-edit">Discover the edit <ArrowRight size={17} /></a></div>
        <div className="hero-number"><span>01 / 03</span><span>THE ART OF SHOWING UP</span></div></div>
        <div className="hero-visual" aria-label="Four paisley and floral tie looks"><div className="hero-photo-row">
          {arrangedTies.map((look) => <img key={look} src={`/images/hero-tie-${look}.jpg`} alt={`${look} paisley and floral tie look`} />)}
        </div><div className="hero-visual-shade" /><div className="hero-visual-stamp">THE<br />TIE<br />EDIT <span>01</span></div>
          <div className="hero-bottom-label"><span>PAISLEY / FLORAL / PRESENCE</span><span>↗</span></div></div>
      </section>
      <div className="brand-ticker" aria-label="Our collection"><span>TIES</span><i>✦</i><span>CLIPS</span><i>✦</i><span>BROOCHES</span><i>✦</i><span>ALL IN THE DETAILS</span></div>
      {catalog.storefront.promo_enabled && catalog.storefront.promo_title.trim() && <section className="store-promo" aria-label="Featured collection"><img src={`/images/${catalog.storefront.promo_image}`} alt="Curated Tie Guy lookbook"/><div className="store-promo-copy"><span className="eyebrow gold-text">{catalog.storefront.promo_eyebrow || 'THE TIE GUY EDIT'}</span><h2>{catalog.storefront.promo_title}</h2><p>{catalog.storefront.promo_description}</p><button className="button button-dark" onClick={() => selectCategory(catalog.storefront.promo_target)}>{catalog.storefront.promo_button} <ArrowUpRight size={18}/></button></div></section>}

      <section id="shop" className="shop-section section-container" aria-labelledby="shop-heading">
        <div className="section-topline"><span>01 / THE COLLECTION</span><span>THE TIE GUY</span></div>
        <div className="shop-head"><div><p className="eyebrow gold-text">GOOD STYLE BEGINS HERE</p><h2 id="shop-heading">Find your <em>signature.</em></h2><p>Explore the collection, choose your favourites and make them yours.</p></div><span className="shop-count">{loading ? 'CONNECTING' : `${catalog.total_count} PIECES`}</span></div>
        <div className="shop-controls"><div className="category-tabs" aria-label="Product category">{CATEGORIES.map((c) => <button key={c} className={filter===c?'active':''} onClick={() => { setFilter(c); setPage(1); }}>{c === 'Ties' ? 'Neckties' : c === 'Clips' ? 'Tie clips' : c}</button>)}</div>
          <div className="shop-tools"><label className="shop-search"><Search size={17}/><input id="shop-search" value={search} onChange={(e)=>setSearch(e.target.value)} placeholder="Search styles" aria-label="Search products" /></label><label className="sort-select"><SlidersHorizontal size={16}/><select value={sort} onChange={(e)=>{setSort(e.target.value as typeof sort);setPage(1);}} aria-label="Sort products"><option value="featured">Featured</option><option value="low">Price: low to high</option><option value="high">Price: high to low</option><option value="name">Name: A–Z</option></select><ChevronDown size={14}/></label></div></div>
        {loading && <div className="product-grid" aria-live="polite">{[0,1,2,3].map((item)=><div className="skeleton-product" key={item}><div /><span/><span/></div>)}</div>}
        {!loading && catalogError && <div className="collection-empty"><span className="empty-mark"><IconMark size={65}/></span><p className="eyebrow gold-text">THE COLLECTION</p><h3>Good things take a moment.</h3><p>Our live collection is temporarily unavailable. No prices or products are shown until it reconnects.</p><button className="button button-outline" onClick={()=>setCatalogRevision((value)=>value+1)}>Try again <ArrowRight size={16}/></button></div>}
        {!loading && !catalogError && filtered.length === 0 && <div className="collection-empty"><span className="empty-mark"><IconMark size={65}/></span><p className="eyebrow gold-text">THE COLLECTION</p><h3>{catalog.total_count || searchTerm || filter !== 'All' ? 'No pieces match that search.' : 'A new edit is on its way.'}</h3><p>{catalog.total_count || searchTerm || filter !== 'All' ? 'Try a different search or view the full collection.' : 'New pieces will appear here when they are published in our live catalog.'}</p>{(catalog.total_count>0 || searchTerm || filter !== 'All') && <button className="button button-outline" onClick={()=>{setFilter('All');setSearch('');setPage(1);}}>View all <ArrowRight size={16}/></button>}</div>}
        {!loading && !catalogError && filtered.length > 0 && <div className="product-grid">{filtered.map((product, index) => <article className="product-card" key={product.id}>
          <button className="product-image-button" disabled={!product.available} onClick={()=>openProduct(product)} aria-label={`View ${product.name}`}><ProductImage product={product} className="product-image" /><span className="product-card-label">{categoryFor(product)==='Ties'?'THE TIE EDIT':product.category.toUpperCase()}</span>{!product.available && <span className="sold-out">CURRENTLY UNAVAILABLE</span>}</button>
          <div className="product-info"><div className="product-title"><div><span className="product-index">NO. {String((catalog.page-1)*catalog.page_size+index+1).padStart(2,'0')} / {product.category}</span><h3>{product.name}</h3></div><strong>{formatGhs(product.price_minor)}</strong></div><button className="product-action" disabled={!product.available || orderingPaused} onClick={()=>openProduct(product)}>{product.available ? orderingPaused ? 'Orders paused' : 'Choose options' : 'Unavailable'} <ArrowUpRight size={17}/></button></div>
        </article>)}</div>}
        {!loading && !catalogError && catalog.total_count > catalog.page_size && <nav className="store-pages" aria-label="Collection pages"><button className="button button-outline" disabled={page<=1} onClick={()=>{setPage(page-1);scrollToShop();}}>← Previous</button><span>Page {page} of {Math.ceil(catalog.total_count/catalog.page_size)}</span><button className="button button-outline" disabled={page*catalog.page_size>=catalog.total_count} onClick={()=>{setPage(page+1);scrollToShop();}}>Next →</button></nav>}
      </section>

      <section id="the-edit" className="editorial" aria-labelledby="editorial-heading"><div className="editorial-inner"><div className="editorial-art"><div className="editorial-tie"><img src="/images/hero-tie-gold.jpg" alt="Gold patterned necktie look" /></div><div className="editorial-caption">THE FINISHING TOUCH / 01</div></div><div className="editorial-copy"><div className="eyebrow"><span className="small-line" /> 02 / THE TIE EDIT</div><h2 id="editorial-heading">For the moments<br />that <em>matter.</em></h2><p>From a sharp first impression to your next celebration, a thoughtfully chosen detail makes the look feel entirely yours.</p><button className="button button-gold" onClick={()=>selectCategory('Ties')}>Explore neckties <ArrowUpRight size={18}/></button><span className="editorial-script">Make an entrance.</span></div></div></section>

      <section className="category-section section-container" aria-labelledby="categories-heading"><div className="section-topline"><span>03 / THE DETAILS</span><span>FINISH THE LOOK</span></div><div className="category-intro"><p className="eyebrow gold-text">SMALL THINGS, STRONG IMPRESSIONS</p><h2 id="categories-heading">The finishing <em>touches.</em></h2></div><div className="category-grid">
        <button className="feature-card feature-clips" onClick={()=>selectCategory('Clips')}><img src="/images/tieclips-collection.jpg" alt="Collection of tie clips" /><span className="feature-overlay"/><span className="feature-content"><small>01 / THE ACCENT</small><strong>Tie clips</strong><em>Shop the edit <ArrowUpRight size={16}/></em></span></button>
        <button className="feature-card feature-brooches" onClick={()=>selectCategory('Brooches')}><span className="brooch-pair"><img src="/images/brooch-medical-hearts.jpg" alt="Medical brooch" /><img src="/images/brooch-pharmacy-bowl.jpg" alt="Pharmacy brooch" /></span><span className="feature-overlay"/><span className="feature-content"><small>02 / THE SIGNATURE</small><strong>Brooches</strong><em>Shop the edit <ArrowUpRight size={16}/></em></span></button>
      </div><p className="lookbook-note">Lookbook imagery inspires the edit. Shop prices and availability are always loaded from the live product catalog above.</p></section>

      <section className="promise"><div><IconMark size={52}/><h2>Dress for the<br /><em>moment.</em></h2><p>The difference is in the details. Explore ties, clips and brooches made to finish your look with intention.</p><button className="button button-cream" onClick={()=>selectCategory('All')}>Shop all pieces <ArrowUpRight size={18}/></button></div><div className="promise-orbit">TIES <span>✦</span> CLIPS <span>✦</span> BROOCHES</div></section>
    </main>
    <footer className="site-footer"><div className="footer-top"><div><img src="/brand/logo-header.png" alt="THE TIE GUY — Ties. Clips. Brooches" /><p>Ties. Clips. Brooches.<br />The details make the difference.</p></div><div><h3>Explore</h3><button onClick={()=>selectCategory('All')}>Shop all</button><button onClick={()=>selectCategory('Ties')}>Neckties</button><button onClick={()=>selectCategory('Clips')}>Tie clips</button><button onClick={()=>selectCategory('Brooches')}>Brooches</button></div><div><h3>Get in touch</h3><p><Instagram size={17}/> DM @thetieguy</p><p><Mail size={17}/> Orders via secure checkout</p><small>Delivery prices are shown before payment when a zone is configured. Otherwise, delivery is quoted separately.</small></div></div><div className="footer-bottom"><span>© {new Date().getFullYear()} THE TIE GUY</span><span>WEAR THE MOMENT WELL.</span><span>Made for the details.</span></div></footer>

    {notice && <div className="store-notice" role="status"><Check size={18}/>{notice}</div>}
    {selected && <div className="modal-backdrop" onMouseDown={(e)=>{if(e.target===e.currentTarget)setSelected(null);}}><div className="product-modal" role="dialog" aria-modal="true" aria-label={`Choose ${selected.name}`}><button className="close-button" aria-label="Close product" onClick={()=>setSelected(null)}><X size={21}/></button><div className="modal-art"><ProductImage product={selected} className="modal-image" /></div><div className="modal-copy"><p className="eyebrow gold-text">{selected.category.toUpperCase()}</p><h2>{selected.name}</h2><strong className="modal-price">{formatGhs(selected.price_minor)}</strong><p>{selected.description || 'The finishing touch for the moments that matter.'}</p>
          {selected.has_size_chart && <div className="size-guide"><button type="button" className="size-guide-toggle" onClick={()=>setShowChart((value)=>!value)} aria-expanded={showChart}>Size guide <ChevronDown size={17}/></button>
            {chartLoading && <small>Loading your size guide…</small>}{chartError && <small role="alert">{chartError}</small>}
            {showChart && sizeChart && <div className="size-guide-content"><strong>{sizeChart.title}</strong><small>Units: {sizeChart.units === 'other' ? 'as stated in chart' : sizeChart.units}</small><div className="size-table-wrap"><table><thead><tr>{sizeChart.columns.map((column,index)=><th key={index}>{column}</th>)}</tr></thead><tbody>{sizeChart.rows.map((row,index)=><tr key={index}>{row.map((cell,column)=><td key={column}>{cell}</td>)}</tr>)}</tbody></table></div>{sizeChart.notes && <p>{sizeChart.notes}</p>}{!sizeChart.rows.length && <p>Measurements will appear when the size chart is completed.</p>}</div>}
          </div>}
          <div className="modal-divider"/><div className="variant-label">SELECT AN OPTION</div><div className="size-choices">{selected.sizes.map((v)=><button key={v} className={size===v?'chosen':''} onClick={()=>setSize(v)}>{v}</button>)}</div><div className="variant-label">QUANTITY</div><div className="qty-control"><button aria-label="Decrease quantity" onClick={()=>setQuantity(Math.max(1,quantity-1))}><Minus size={16}/></button><strong>{quantity}</strong><button aria-label="Increase quantity" onClick={()=>setQuantity(Math.min(10,quantity+1))}><Plus size={16}/></button></div><button className="button button-dark full-button" onClick={()=>add(selected.id,size,quantity)} disabled={orderingPaused}>Add to bag — {formatGhs(selected.price_minor*quantity)} <ShoppingBag size={19}/></button>{orderingPaused && <p className="checkout-hint">Orders are paused at the moment.</p>}<div className="detail-foot"><ShieldCheck size={17}/> Secure Paystack checkout · Automatic verification</div></div></div></div>}
    {cartOpen && <div className="drawer-backdrop" onMouseDown={(e)=>{if(e.target===e.currentTarget)setCartOpen(false);}}><aside className="bag-drawer" role="dialog" aria-modal="true" aria-label="Your shopping bag"><div className="drawer-header"><div><span className="eyebrow gold-text">THE TIE GUY</span><h2>Your bag <small>({count})</small></h2></div><button className="close-button" onClick={()=>setCartOpen(false)} aria-label="Close bag"><X size={22}/></button></div>
      {cartLoading && <p className="bag-warning">Checking your bag against live stock…</p>}
      {cartError && <p className="bag-warning" role="alert">{cartError} <button onClick={()=>setCartRevision((value)=>value+1)}>Retry</button></p>}
      {!cartLoading && !cartError && unavailableLines.length>0 && <div className="bag-warning" role="alert"><strong>Some saved items changed.</strong><p>These options are unavailable or were removed; take them out before paying.</p>{unavailableLines.map((line)=><button key={`${line.id}:${line.size}`} onClick={()=>remove(line.id,line.size)}>Remove unavailable option ({line.size})</button>)}</div>}
      {inCart.length ? <div className="drawer-items">{inCart.map((line)=><div className="bag-item" key={`${line.id}:${line.size}`}><ProductImage product={line.product}/><div><small>{line.product.category}</small><h3>{line.product.name}</h3><span>{line.size}</span><strong>{formatGhs(line.product.price_minor*line.quantity)}</strong><div className="bag-item-actions"><div className="qty-control small"><button aria-label="Decrease quantity" onClick={()=>changeQuantity(line.id,line.size,-1)}><Minus size={14}/></button><b>{line.quantity}</b><button aria-label="Increase quantity" onClick={()=>changeQuantity(line.id,line.size,1)}><Plus size={14}/></button></div><button className="remove-link" onClick={()=>remove(line.id,line.size)}>Remove</button></div></div></div>)}</div> : <div className="empty-bag"><ShoppingBag size={46} strokeWidth={1}/><h3>Your bag is waiting.</h3><p>Find a detail that feels like you.</p><button className="button button-dark" onClick={()=>{setCartOpen(false);scrollToShop();}}>Explore the collection <ArrowRight size={17}/></button></div>}
      {inCart.length>0 && <div className="drawer-footer"><div className="summary-line"><span>Subtotal</span><strong>{formatGhs(subtotal)}</strong></div><small>Delivery, if applicable, is shown at checkout when a rate is configured.</small><button className="button button-dark full-button" disabled={cartLoading || !!cartError || !!unavailableLines.length || !checkoutReady || orderingPaused || cart.length>8 || !!catalogError} onClick={()=>{setCartOpen(false);setCheckoutOpen(true);}}>{orderingPaused ? 'Orders are paused' : !checkoutReady ? 'Checkout opening soon' : 'Continue to checkout'} <ArrowRight size={18}/></button><span className="secure-note"><ShieldCheck size={16}/> Secure checkout · Automatic Paystack verification</span></div>}
    </aside></div>}
    {checkoutOpen && <div className="modal-backdrop checkout-backdrop" onMouseDown={(e)=>{if(e.target===e.currentTarget)setCheckoutOpen(false);}}><div className="checkout-modal" role="dialog" aria-modal="true" aria-label="Secure checkout"><button className="close-button" aria-label="Close checkout" onClick={()=>setCheckoutOpen(false)}><X size={22}/></button><div className="checkout-header"><p className="eyebrow gold-text">SECURE CHECKOUT</p><h2>Almost yours.</h2><p>Leave your details, choose pickup or delivery, then pay securely with Paystack.</p></div><div className="checkout-grid"><form id="checkout-form" onSubmit={(e)=>void submitOrder(e)} className="checkout-form"><div className="form-section-label">01 / YOUR DETAILS</div><label>Full name<input type="text" autoComplete="name" minLength={2} maxLength={100} required value={form.name} onChange={(e)=>setForm({...form,name:e.target.value})} placeholder="Your full name" /></label><div className="form-row"><label>Email address<input type="email" autoComplete="email" maxLength={254} required value={form.email} onChange={(e)=>setForm({...form,email:e.target.value})} placeholder="you@example.com" /></label><label>Phone number<input type="tel" autoComplete="tel" minLength={9} maxLength={24} required value={form.phone} onChange={(e)=>setForm({...form,phone:e.target.value})} placeholder="+233 ..." /></label></div><div className="form-section-label">02 / HOW YOU'LL RECEIVE IT</div><div className="method-options"><button type="button" className={form.method==='delivery'?'active':''} onClick={()=>setForm({...form,method:'delivery'})}><Truck size={19}/> Delivery</button><button type="button" className={form.method==='pickup'?'active':''} onClick={()=>setForm({...form,method:'pickup',zone_id:'',address:''})}><ShoppingBag size={19}/> Pickup</button></div>
          {form.method==='delivery' && <><label>Delivery zone <span className="field-optional">optional</span><select value={form.zone_id} onChange={(e)=>setForm({...form,zone_id:e.target.value})}><option value="">Other area — delivery quoted separately</option>{catalog.delivery_zones.map((z)=><option key={z.id} value={z.id}>{z.name} · {formatGhs(z.fee_minor)}</option>)}</select></label><label>Delivery address<textarea rows={2} minLength={8} maxLength={350} required value={form.address} onChange={(e)=>setForm({...form,address:e.target.value})} placeholder="Street, area and a landmark" /></label></>}
          <label>Discount code <span className="field-optional">optional · automatic offers appear without a code</span><input type="text" value={discountCode} maxLength={24} autoComplete="off" onChange={(e)=>setDiscountCode(e.target.value.toUpperCase().replace(/[^A-Z0-9-]/g,''))} placeholder="Enter a code" /></label>
          <label>Order note <span className="field-optional">optional</span><textarea rows={2} maxLength={500} value={form.notes} onChange={(e)=>setForm({...form,notes:e.target.value})} placeholder="Anything we should know?" /></label><label className="honey-field" aria-hidden="true">Website<input type="text" tabIndex={-1} autoComplete="off" value={form.website} onChange={(e)=>setForm({...form,website:e.target.value})}/></label>
        </form><div className="checkout-summary"><h3>Your order</h3>{inCart.map((line)=><div className="checkout-product" key={`${line.id}:${line.size}`}><span>{line.quantity} × {line.product.name}<small>{line.size}</small></span><strong>{formatGhs(line.quantity*line.product.price_minor)}</strong></div>)}<div className="checkout-totals"><div><span>{quoteCurrent ? 'Live subtotal' : 'Estimated subtotal'}</span><strong>{formatGhs(quoteCurrent ? quote.subtotal_minor : subtotal)}</strong></div><div><span>Delivery</span><strong>{(quoteCurrent ? quote.delivery_fee_minor : deliveryFee)===null?'Quoted separately':formatGhs((quoteCurrent ? quote.delivery_fee_minor : deliveryFee) || 0)}</strong></div>
          {quoteCurrent && quote.promotion_name && <div className="offer-name"><span>Offer · {quote.promotion_name}</span><strong>{quote.discount_minor>0?`−${formatGhs(quote.discount_minor)}`:'Included'}</strong></div>}
          {quoteCurrent && quote.delivery_discount_minor>0 && <div className="offer-name"><span>Delivery savings</span><strong>−{formatGhs(quote.delivery_discount_minor)}</strong></div>}
          <div className="grand-total"><span>{quoteCurrent ? 'Pay now' : 'Awaiting live quote'}</span><strong>{quoteCurrent ? formatGhs(total) : '—'}</strong></div></div>
          {quoteCurrent && quote.message && <div className="offer-feedback">{quote.message}</div>}
          {quoteCurrent && quote.subtotal_minor !== subtotal && <div className="offer-feedback">An item price changed. This live quote is authoritative; review your order before paying.</div>}
          {!emailValid && <div className="offer-feedback">Add your email to see the verified total and any automatic offer.</div>}
          {quoteBusy && <div className="offer-feedback">Checking prices, stock and offers…</div>}
          {quoteError && <div className="checkout-error" role="alert">{quoteError}</div>}
          {cartError && <div className="checkout-error" role="alert">{cartError}</div>}
          {(quoteCurrent ? quote.delivery_fee_minor : deliveryFee)===null && form.method==='delivery' && <div className="delivery-notice">Delivery outside listed zones is quoted and paid separately. Your Paystack charge covers products only; a free-delivery offer cannot waive an unquoted charge.</div>}{testMode && <div className="test-mode-note">Paystack TEST MODE — no real payment will be taken.</div>}<div className="secure-box"><ShieldCheck size={21}/><span>Your card or Mobile Money details go straight to Paystack; we never collect them here. Paystack-verified payments are confirmed automatically. Our team handles delivery and any exceptions.</span></div><button className="button button-dark full-button" form="checkout-form" disabled={orderBusy || !readyForCheckout}>{orderBusy?'Connecting to Paystack…':readyForCheckout?`Pay ${formatGhs(total)}`:'Waiting for live quote'} <ArrowUpRight size={19}/></button>{checkoutError && <p className="checkout-error" role="alert">{checkoutError}</p>}<span className="checkout-hint">A valid email is required for your Paystack receipt. We never create a WhatsApp customer identifier from this form.</span></div></div></div></div>}
  </div>;
}
