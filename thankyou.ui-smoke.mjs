// Disposable browser fixture for the post-payment thank-you landing.
// Requires a local Next server. Never contacts live Supabase or Paystack:
// the payment-status response is intercepted, and no real order exists.
//
//   NEXT_PUBLIC_WHATSAPP_GROUP_URL=https://chat.whatsapp.com/TestInviteCode \
//   STORE_UI_URL=http://127.0.0.1:4390 node tests/thankyou.ui-smoke.mjs
//
// Add --no-invite to assert the "invite being set up" fallback state instead —
// that variant must be pointed at a server started WITHOUT the variable, e.g.
//   PORT=4391 npm start      then   STORE_UI_URL=http://127.0.0.1:4391 npm run test:thankyou -- --no-invite
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';

const url = process.env.STORE_UI_URL || 'http://127.0.0.1:4390';
const expectInvite = !process.argv.includes('--no-invite');
const invite = 'https://chat.whatsapp.com/TestInviteCode';
const reference = 'TG' + 'b'.repeat(32);
const token = '22222222-2222-4222-8222-222222222222';

const confirmedStatus = {
  order_number: 'TG-1042', reference, amount_minor: 4500, currency: 'GHS',
  payment_status: 'confirmed', order_status: 'processing',
  confirmation_source: 'paystack', paid_with_paystack: true, reservation_expired: false,
  message: 'Payment confirmed and matched to your order.',
};
const failedStatus = {
  order_number: 'TG-1043', reference, amount_minor: 4500, currency: 'GHS',
  payment_status: 'pending', order_status: 'new',
  confirmation_source: 'none', paid_with_paystack: false, reservation_expired: false,
  message: 'We are waiting for Paystack to finish processing your payment. You can check again shortly.',
};
let status = confirmedStatus;

const browser = await chromium.launch({ headless: true });
try {
  for (const [label, width, height] of [['mobile', 390, 844], ['small-android', 360, 740], ['desktop', 1440, 900]]) {
    const page = await browser.newPage({ viewport: { width, height } });
    status = confirmedStatus;
    await page.route('**/api/payment-status', (route) => route.fulfill({ status: 200, json: status }));
    await page.addInitScript(([key, value]) => sessionStorage.setItem(key, value), [`thetieguy-order-${reference}`, token]);
    await page.goto(`${url}/order/return?reference=${reference}`, { waitUntil: 'networkidle' });

    await page.getByRole('heading', { name: 'Thank you for your order!' }).waitFor();
    assert.equal(await page.getByRole('heading', { name: 'Payment not completed.' }).count(), 0, `${label}: success page only for confirmed payments`);
    assert.equal(await page.getByText('PAYMENT SUCCESSFUL').count(), 1, `${label}: payment-successful label`);
    assert.equal(await page.getByText('#TG-1042').count(), 1, `${label}: order number shown to the customer`);
    assert.equal(await page.getByText('GH₵45.00').count() >= 1, true, `${label}: order total shown`);
    assert.equal(await page.getByText('Confirmed').count() >= 1, true, `${label}: payment status shown`);
    assert.equal(await page.getByRole('heading', { name: 'Join The Tie Guy Community' }).count(), 1, `${label}: group invitation headline`);
    for (const benefit of ['Exclusive discount codes', 'Early access to new drops', 'Campus promotions']) {
      assert.equal(await page.getByText(benefit).count(), 1, `${label}: community benefit "${benefit}"`);
    }
    const continueShopping = page.getByRole('link', { name: /Continue shopping/ });
    assert.equal(await continueShopping.count(), 1, `${label}: continue-shopping button`);
    assert.equal(await continueShopping.getAttribute('href'), '/', `${label}: continue-shopping returns to the store`);

    if (expectInvite) {
      const cta = page.getByRole('link', { name: /Join our WhatsApp group/ });
      assert.equal(await cta.getAttribute('href'), invite, `${label}: invite points at the configured group`);
      assert.equal(await cta.getAttribute('target'), '_blank');
      assert.match(await cta.getAttribute('rel') || '', /noopener/, `${label}: opens without window.opener`);
    } else {
      assert.equal(await page.getByRole('link', { name: /Join our WhatsApp group/ }).count(), 0, `${label}: no invite button without a configured link`);
      assert.equal(await page.getByText(/invite is being set up/).count(), 1, `${label}: honest fallback copy`);
    }

    // Hierarchy: primary = join group, secondary = continue shopping.
    const primary = page.locator('.thanks-primary');
    const secondary = page.locator('.thanks-secondary');
    if (expectInvite) {
      const primaryBox = await primary.boundingBox();
      const secondaryBox = await secondary.boundingBox();
      assert.ok(primaryBox && secondaryBox && primaryBox.y < secondaryBox.y, `${label}: join-group button sits above continue-shopping`);
      assert.ok(primaryBox.width >= 200, `${label}: join-group button is prominent`);
    }
    // A paid customer is never sent to the support chat for the community group.
    const groupHref = await page.locator('.thanks-primary').count() ? await page.locator('.thanks-primary').getAttribute('href') : null;
    if (groupHref) assert.equal(/wa\.me\/233592060208/.test(groupHref), false, `${label}: community button never points at the support number`);

    const overflow = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, width: window.innerWidth }));
    assert.ok(overflow.scroll <= overflow.width, `${label}: no horizontal scroll ${JSON.stringify(overflow)}`);

    if (process.env.THANKYOU_SCREENSHOT && label === (process.env.THANKYOU_SCREENSHOT_LABEL || 'mobile')) {
      await page.screenshot({ path: process.env.THANKYOU_SCREENSHOT, fullPage: true });
    }
    if (expectInvite) {
      await page.getByRole('button', { name: /Skip this invitation/ }).click();
      await page.getByRole('heading', { name: 'Join The Tie Guy Community' }).waitFor({ state: 'detached' });
      assert.equal(await page.getByRole('link', { name: /Continue shopping/ }).count(), 1, `${label}: continue-shopping survives skip`);
    }

    // Unsuccessful payments must never show the thank-you page.
    status = failedStatus;
    await page.unroute('**/api/payment-status');
    await page.route('**/api/payment-status', (route) => route.fulfill({ status: 200, json: failedStatus }));
    await page.goto(`${url}/order/return?reference=${reference}`, { waitUntil: 'networkidle' });
    await page.getByRole('heading', { name: 'Payment not completed.' }).waitFor();
    assert.equal(await page.getByText('PAYMENT SUCCESSFUL').count(), 0, `${label}: no success label when payment failed`);
    assert.equal(await page.getByRole('heading', { name: 'Join The Tie Guy Community' }).count(), 0, `${label}: no community invite when payment failed`);
    const retry = page.getByRole('link', { name: /Try payment again/ });
    assert.equal(await retry.count(), 1, `${label}: retry button present`);
    assert.equal(await retry.getAttribute('href'), '/', `${label}: retry returns the customer to the store`);
    assert.equal(await page.getByRole('link', { name: /Chat with us on WhatsApp/ }).count(), 1, `${label}: support chat offered on failure`);
    console.log(`PASS ${label}: failed payment shows an honest status page with retry + support`);
    console.log(`PASS ${label}: thank-you landing, ${expectInvite ? 'community invite + join button' : 'invite fallback'}, continue shopping, no overflow`);
    await page.close();
  }
} finally {
  await browser.close();
}
