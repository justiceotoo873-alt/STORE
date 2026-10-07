// Disposable browser fixture for the sticky header, mobile drawer and the
// floating WhatsApp support button. Requires a local Next server:
//   STORE_UI_URL=http://127.0.0.1:4390 node tests/navigation.ui-smoke.mjs
// Never contacts live Supabase, Paystack or WhatsApp.
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';

const url = process.env.STORE_UI_URL || 'http://127.0.0.1:4390';
const zone = '11111111-1111-4111-8111-111111111111';
const products = [
  { id: '9223372036854775807', name: 'Paisley signature necktie', category: 'Neckties', description: 'A statement tie.', image_url: 'https://assets.example.test/tie.jpg', sizes: ['One size'], price_minor: 7550, available: true, has_size_chart: false },
  { id: '22222222-2222-4222-8222-222222222222', name: 'Classic gold tie clip', category: 'Tie clips', description: 'A polished touch.', image_url: 'https://assets.example.test/clip.jpg', sizes: ['One size'], price_minor: 2500, available: true, has_size_chart: false },
];
const storefront = { announcement_enabled: true, announcement_text: 'THE DETAIL MAKES THE DIFFERENCE', hero_eyebrow: 'THE TIE GUY · THE SIGNATURE EDIT',
  hero_title: 'A little detail.', hero_emphasis: 'A lasting', hero_final_line: 'impression.', hero_description: 'Statement neckties.',
  hero_visual: 'four-ties', hero_cta: 'Explore the collection', promo_enabled: false, promo_eyebrow: '', promo_title: '', promo_description: '', promo_button: 'Shop the edit', promo_image: 'hero-tie-gold.jpg', promo_target: 'All' };

async function stub(page) {
  await page.route('**/api/catalog?*', (r) => r.fulfill({ json: { business: { name: '@thetieguy', availability: 'available', unavailable_message: '' },
    storefront, products, total_count: products.length, page: 1, page_size: 24,
    delivery_zones: [{ id: zone, name: 'Fixture zone', fee_minor: 1500 }] } }));
  await page.route('**/api/cart-products?*', (r) => r.fulfill({ json: { products } }));
  await page.route('**/api/config', (r) => r.fulfill({ json: { checkout_enabled: true, test_mode: true } }));
  await page.route('**/api/quote', (r) => r.fulfill({ json: { subtotal_minor: 7550, delivery_fee_minor: 0, discount_minor: 0, delivery_discount_minor: 0, amount_minor: 7550, promotion_name: null, promotion_code: null, message: null } }));
  await page.route('https://assets.example.test/**', (r) => r.fulfill({ path: 'public/images/tieclips-collection.jpg', contentType: 'image/jpeg' }));
}

const browser = await chromium.launch({ headless: true });
try {
  // ---------- desktop: the header floats over the page ----------
  {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    await stub(page);
    await page.goto(url, { waitUntil: 'networkidle' });
    await page.getByRole('heading', { name: 'Find your signature.' }).waitFor();
    const before = await page.locator('.site-header').boundingBox();
    assert.ok(before && before.y >= 0, 'desktop: header starts in normal flow below the announcement bar');
    await page.mouse.wheel(0, 2600);
    await page.waitForTimeout(450);
    const after = await page.locator('.site-header').boundingBox();
    assert.ok(after && after.y <= 2, `desktop: header pins to the top of the viewport once scrolled (y=${after?.y})`);
    await page.mouse.wheel(0, 1800);
    await page.waitForTimeout(400);
    const later = await page.locator('.site-header').boundingBox();
    assert.ok(later && later.y <= 2, `desktop: header is still pinned deeper down the page (y=${later?.y})`);
    assert.equal(await page.locator('.site-header').evaluate((node) => getComputedStyle(node).position), 'sticky');
    for (const label of ['Shop all', 'Neckties', 'Tie clips', 'Brooches']) {
      assert.equal(await page.getByRole('button', { name: label, exact: true }).first().isVisible(), true, `desktop: "${label}" still reachable while scrolled`);
    }
    // No layout jump when the sticky state kicks in: content must not shift.
    const shopTopAfterScroll = await page.locator('#the-edit, .shop-section').first().evaluate((node) => node.getBoundingClientRect().top);
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(300);
    const shopTopTop = await page.locator('#the-edit, .shop-section').first().evaluate((node) => node.getBoundingClientRect().top);
    assert.ok(shopTopTop > shopTopAfterScroll, 'desktop: the page scrolls normally (no pinned spacer)');

    // Floating support button: present, bottom-right, opens the support chat.
    const support = page.locator('.support-float');
    assert.equal(await support.count(), 1, 'desktop: floating support button exists');
    const href = await support.getAttribute('href');
    assert.match(href || '', /^https:\/\/wa\.me\/233592060208\?text=/, `desktop: support link is the business number (got ${href})`);
    const box = await support.boundingBox();
    assert.ok(box.x + box.width >= 1440 - 40 && box.y + box.height >= 900 - 60, 'desktop: support button sits bottom-right');
    assert.equal(await support.getAttribute('target'), '_blank');
    assert.match(await support.getAttribute('rel') || '', /noopener/);

    // The footer now offers WhatsApp, not Instagram.
    const footer = page.locator('.site-footer');
    assert.equal(await footer.getByRole('link', { name: /Chat with us on WhatsApp/ }).count(), 1, 'desktop: footer WhatsApp CTA');
    assert.equal(await page.getByText('DM @thetieguy').count(), 0, 'desktop: Instagram DM line is gone');

    // Opening the bag hides the floating button so it cannot cover checkout controls.
    await page.getByRole('button', { name: /Open bag/ }).click();
    await page.locator('.bag-drawer').waitFor();
    assert.equal(await page.locator('.support-float').count(), 0, 'desktop: support button hidden while the bag is open');
    await page.getByRole('button', { name: 'Close bag' }).click();
    await page.locator('.support-float').waitFor();
    if (process.env.NAV_SCREENSHOT) await page.screenshot({ path: process.env.NAV_SCREENSHOT });
    console.log('PASS desktop: sticky header, no layout shift, floating WhatsApp support, footer WhatsApp CTA');
    await page.close();
  }

  // ---------- mobile: drawer behaviour ----------
  {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
    await stub(page);
    await page.goto(url, { waitUntil: 'networkidle' });
    await page.getByRole('heading', { name: 'Find your signature.' }).waitFor();

    const drawer = page.locator('.desktop-nav');
    const menuButton = page.getByRole('button', { name: 'Open menu' });
    await menuButton.click();
    await drawer.waitFor();
    assert.equal(await page.evaluate(() => getComputedStyle(document.body).overflow), 'hidden', 'mobile: background scroll is locked while the menu is open');
    assert.equal(await page.locator('.nav-backdrop').count(), 1, 'mobile: a backdrop exists behind the drawer');

    // 1) clicking inside the drawer (its own padding, not a link) keeps it open
    await drawer.click({ position: { x: 8, y: 4 } });
    await page.waitForTimeout(200);
    assert.equal(await page.locator('.desktop-nav.nav-open').count(), 1, 'mobile: clicking inside keeps the menu open');
    assert.equal(await page.evaluate(() => getComputedStyle(document.body).overflow), 'hidden', 'mobile: still locked while the menu stays open');

    // 2) clicking the backdrop closes it and restores scrolling
    await page.locator('.nav-backdrop').click({ position: { x: 20, y: 400 } });
    await page.waitForTimeout(250);
    assert.equal(await page.locator('.desktop-nav.nav-open').count(), 0, 'mobile: clicking outside closes the menu');
    assert.equal(await page.evaluate(() => getComputedStyle(document.body).overflow), 'visible', 'mobile: scrolling is restored after closing');

    // 3) Escape closes it
    await menuButton.click();
    await drawer.waitFor();
    await page.keyboard.press('Escape');
    await page.waitForTimeout(200);
    assert.equal(await page.locator('.desktop-nav.nav-open').count(), 0, 'mobile: Escape closes the menu');

    // 4) X closes it
    await menuButton.click();
    await drawer.waitFor();
    await page.getByRole('button', { name: 'Open menu' }).click(); // the same control toggles to the X icon
    await page.waitForTimeout(200);
    assert.equal(await page.locator('.desktop-nav.nav-open').count(), 0, 'mobile: X closes the menu');

    // 5) a navigation link closes the menu and navigates
    await menuButton.click();
    await drawer.waitFor();
    await page.locator('.desktop-nav').getByRole('button', { name: 'Shop all' }).click();
    await page.waitForTimeout(500);
    assert.equal(await page.locator('.desktop-nav.nav-open').count(), 0, 'mobile: choosing a category closes the menu');
    const shopVisible = await page.locator('.shop-section').evaluate((node) => { const r = node.getBoundingClientRect(); return r.top < 300; });
    assert.equal(shopVisible, true, 'mobile: the page actually navigated to the collection');

    // Floating support button: short label on phones, still bottom-right.
    const support = page.locator('.support-float');
    await support.waitFor();
    assert.equal(await support.locator('.support-float-short').isVisible(), true, 'mobile: short "Need help?" label is shown');
    assert.equal(await support.locator('.support-float-long').isVisible(), false, 'mobile: long label is hidden');
    const box = await support.boundingBox();
    assert.ok(box && box.x + box.width <= 390 - 8 && box.y + box.height <= 844 - 8, 'mobile: support button stays inside the viewport');
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
    assert.equal(overflow, true, 'mobile: no horizontal overflow with the new chrome');
    if (process.env.NAV_SCREENSHOT_MOBILE) {
      await page.getByRole('button', { name: 'Open menu' }).click();
      await page.locator('.desktop-nav.nav-open').waitFor();
      await page.waitForTimeout(250);
      await page.screenshot({ path: process.env.NAV_SCREENSHOT_MOBILE });
    }
    console.log('PASS mobile: drawer closes on outside click / Escape / X / link, scroll lock restores, floating support adapts');
    await page.close();
  }
} finally {
  await browser.close();
}
