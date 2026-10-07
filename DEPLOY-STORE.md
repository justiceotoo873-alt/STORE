# Deploy the @thetieguy online store

This folder **is** the customer-facing store (Next.js 15 App Router on Vercel). It is completely separate from the Athena staff dashboard: deploy it as its own Vercel project with its own database keys. Nothing here has been deployed, and **none of the SQL below has been applied to your live Supabase project yet**.

- Bundle layout (standalone ZIP): folder root = this store, SQL in `supabase/migrations/`, checks in `tests/sql/`.
- Monorepo layout (the full workspace): this store is the `online-store/` subfolder; SQL stays at `supabase/migrations/` in the repository root.

---

## 1. What must exist before the store works

The store's API routes call database functions that only exist after these migrations run. Without them, the catalog route returns **HTTP 503** and checkout stays disabled — the site still deploys, but it cannot sell.

Run in **Supabase → SQL Editor**, in this exact order, on project `jatxzdmrasozbipsfmqy` (never `supabase/schema.sql` on live data, and never the files under `tests/sql/`):

| Order | File | Purpose |
| --- | --- | --- |
| 0 | `supabase/migrations/00_preflight_read_only.sql` | Read-only inspection: tables, columns, RLS, triggers, publications, whether store objects already exist. Safe to run any time. |
| 1 | `supabase/migrations/20260929_recreate_deleted_settings_uuid.sql` | **Only if the preflight reports `public.settings` missing.** Recreates it with fresh UUID defaults. |
| 2 | `supabase/migrations/20260930_online_store_paystack.sql` | Baseline store objects: `store_orders`, catalog/cart/checkout RPCs, settlement function, stock guard. Rejects pre-existing store objects, so run it once. |
| 3 | `supabase/migrations/20261001_store_merchandising.sql` | Promotions, size charts, product options, stock alerts, paginated catalog. Requires step 2. |
| 4 | `supabase/migrations/90_verify_read_only.sql` | Read-only structural verification. Expect one settings row, one storefront design row, the expected RPCs, RLS and grants. |

Checksums to confirm you have the reviewed files: see `supabase/migrations/SHA256SUMS.txt`.

**Staff sign-in (dashboard project, optional here):** invite/confirm the owner's address in Supabase Auth and make sure it has an authorized `public.staff_users` row. Store customers never need a Supabase account.

---

## 2. Create the Vercel project

**Option A — GitHub (recommended)**

1. Push this folder to a repository (its own repo, or a subfolder of one).
2. Vercel → **Add New → Project** → import the repository.
3. **Root Directory**: the folder that contains this `package.json`. For the standalone bundle that is the repository root; in the full workspace set it to `online-store`.
4. **Framework Preset**: `Next.js`. Leave Build Command, Output Directory and Install Command empty (defaults are correct). `vercel.json` already pins `"framework": "nextjs"` and declares the daily cron.
5. Add the environment variables in §3 **before** the first deploy (or add them and redeploy).
6. Deploy.
7. Before the build, npm runs the bundled `prebuild-check`. If Vercel is ever pointed at an incomplete copy of this folder, the log will say exactly which files are missing and what was actually uploaded, instead of only `Couldn't find any 'pages' or 'app' directory`.

**Option B — Vercel CLI (no Git)**

```bash
cd <this folder>          # the folder containing package.json
npm i -g vercel
vercel login
vercel link               # create/link the store project
vercel env add NEXT_PUBLIC_SUPABASE_URL production
# …repeat for every variable in §3 (add them to preview/development too)
vercel --prod
```

Do **not** hand Vercel a `.zip` file: deploy from a Git repository or the CLI in the extracted folder. Never set the Output Directory to `.next` manually and never change the Build Command to `vite build` — that is the sibling dashboard, not this store.

---

## 3. Environment variables (store project only)

Names are exact. Values are secret and are **not** included in this package.

| Name | Scope | Where to get it | Example shape |
| --- | --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | public | Supabase → Project Settings → API | `https://jatxzdmrasozbipsfmqy.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | public | Supabase → API keys → publishable/anon | `sb_publishable_…` or anon JWT |
| `SUPABASE_SERVICE_ROLE_KEY` | **server secret** | Supabase → API keys → secret/service_role | `sb_secret_…` or service_role JWT |
| `PAYSTACK_SECRET_KEY` | **server secret** | Paystack → Settings → API Keys & Webhooks | `sk_test_…` first, then `sk_live_…` |
| `STORE_ORIGIN` | server | The final HTTPS origin of this store | `https://your-store-domain` (no trailing slash) |
| `CRON_SECRET` | **server secret** | Generate a random 32+ character string | `openssl rand -hex 32` |
| `NEXT_PUBLIC_WHATSAPP_GROUP_URL` | public (optional) | The group invite link customers see after payment | `https://chat.whatsapp.com/XXXXXXXX` |
| `NEXT_PUBLIC_SUPPORT_WHATSAPP` | public (optional) | Customer-care chat for the floating button, footer and failed-payment page | `233592060208` (default) |
| `NEXT_PUBLIC_WHATSAPP_GROUP_LINK` | public (optional) | Accepted alias for the group invite if that is the name already in Vercel | `https://chat.whatsapp.com/XXXXXXXX` |

Rules

- Never put `SUPABASE_SERVICE_ROLE_KEY`, `PAYSTACK_SECRET_KEY` or `CRON_SECRET` behind a `NEXT_PUBLIC_` name — anything `NEXT_PUBLIC_` is shipped to the browser.
- Set the variables for **Production and Preview**; changing them requires a new deployment to take effect.
- `STORE_ORIGIN` must match the domain customers actually use; the checkout callback is built from it. A wrong value breaks return-to-store confirmation (orders can still settle through the verified webhook and the daily reconciliation backstop).
- The build succeeds without any variables. Until they are set, `/api/config` reports `checkout_enabled: false` and the site shows its setup state — that is not a deploy failure.

Check your local set-up (without printing secrets):

```bash
npm run verify:deploy            # structure, Node version, variable presence, secret-leak scan
npm run verify:deploy -- --strict
```

---

## 4. Paystack

1. Start with **test mode** keys (`sk_test_…`) as above.
2. Paystack Dashboard → Settings → API Keys & Webhooks → **Webhook URL**: `https://<your-store-domain>/api/paystack-webhook`. Also add the same URL in test mode.
3. Subscribe to `charge.success` (and `refund.processed` if you intend to handle refunds). Paystack retries non-200 responses for up to 72 hours in live mode / 10 hours in test mode.
4. The webhook signature (`x-paystack-signature`, HMAC-SHA512 over the raw body) is verified before anything is trusted, and every settlement also re-verifies the transaction with Paystack (`data.status`, amount, currency, reference, `paid_at`) — an unsigned or underpaid callback never confirms an order.
5. `vercel.json` schedules `/api/reconcile-pending` daily at 07:00 UTC as a missed-webhook backstop. Vercel sends `Authorization: Bearer $CRON_SECRET`, so keep `CRON_SECRET` set and identical in Vercel. Hobby plans allow once-daily crons only; failed cron runs are not retried automatically.

---

## 4b. "The store doesn't show the products I added to the dashboard"

Two fast checks tell you which half is broken:

1. `https://<your-store-domain>/api/catalog` — the HTTP status is the diagnosis.
   - **503** "The live collection is temporarily unavailable": the store's server cannot read the catalog. Cause is server-side: SQL migrations unapplied, the `anon` grant missing, or this Vercel project is pointed at a different Supabase project/keys than the dashboard.
   - **200 with `"products": []`**: the store works, nothing qualifies to display — products switched off, or all sold out.
   - **200 with products listed**: the store is fine; the site you're looking at is an old deployment or a cached page (hard-refresh).
2. Run `supabase/migrations/30_why_store_products_missing_read_only.sql` in the SQL Editor. It is read-only and prints, per product, the reason it would be hidden (`active` is false, no price, sold out), plus a one-line verdict.

Remember the two rules the catalog enforces: a product shows only when **`active` is true** (the dashboard's product switch), and it renders as sold out — not hidden — when **stock is 0**. A product you "add" in the dashboard is saved to that dashboard's Supabase project, so if the store project's `NEXT_PUBLIC_SUPABASE_URL` names a different project, the store will never see it.

## 4c. "Awaiting live quote" and no Pay button

The Pay button only appears after a successful live quote. If the panel shows a
pink *"Please use the official store to request a quote."* and the button stays
**WAITING FOR LIVE QUOTE**, the browser's address does not match `STORE_ORIGIN`
(common while testing on a Vercel preview URL). The page now prints the exact
pair, and Vercel logs an `origin_mismatch` line. Set `STORE_ORIGIN` to the
origin customers actually open (scheme + host, no trailing slash), redeploy, and
the button appears. Step-by-step: [`../deploy/FIX-quote-403-origin.md`](../deploy/FIX-quote-403-origin.md).

## 4c-bis. Navigation, support chat and the mobile menu (update of October 2026)

**Sticky navigation.** The header is now `position: sticky` with a translucent
blur and a soft shadow that appears once it detaches from the announcement bar.
No layout jump: sticky keeps the header's space in the document. `html` gained
`scroll-padding-top` so anchored sections are not hidden behind it.

**Mobile drawer.** Opens with the existing hamburger and now closes on any of:
outside tap (a real backdrop sits behind it), Escape, the X, or choosing a
navigation item. Background scrolling is locked while it is open, released
immediately on close, and a resize past 901 px closes it so the page can never
stay locked. The drawer is anchored with `top:100%`, so it follows the sticky
header.

**Floating WhatsApp support.** Bottom-right, always visible while browsing,
"Need help? Chat with us" on desktop and "Need help?" on phones. It links to the
**support** chat only (`NEXT_PUBLIC_SUPPORT_WHATSAPP`, default `233592060208`,
with the pre-filled message "Hi The Tie Guy, I need some help."). It hides while
the bag, product dialog, checkout or mobile drawer is open, so it can never cover
Add to bag, Pay or other controls.

**Footer.** The Instagram DM line is replaced with a WhatsApp link to the same
support chat; the rest of the section is unchanged.

**Two destinations, deliberately separate:** support chat = `wa.me` link;
community group = `chat.whatsapp.com/…` invite (thank-you page only). The
validators refuse to swap them — a `wa.me` chat link can never be rendered as the
group button, and the group invite is never used for support.

## 4d. The post-payment thank-you page

After a confirmed payment, `/order/return` shows a **Thank you** panel with the
order number, reference and confirmation source, plus an invitation to join the
**WhatsApp group for discount codes and new arrivals**. Two deliberately tiny
controls sit in the bottom-right corner: **Skip** (hides the invitation) and
**Return to store**.

- Set `NEXT_PUBLIC_WHATSAPP_GROUP_URL` to your real group invite
  (`https://chat.whatsapp.com/…`). Only genuine HTTPS WhatsApp links are
  rendered — any other value (including typos) is ignored and the page shows
  its "invite is being set up" line instead, so a paying customer is never sent
  to an unverified address.
- Leaving it empty is fine; the thank-you message still appears.
- Only a payment status of `confirmed` gets this panel. Pending or
  review-needed payments keep the status screen with **Back to store** /
  **Check again**.
- Verification: `npm run test:thankyou` (browser check of both states, the tiny
  corner controls and phone widths) and the unit checks in `npm test`.

## 5. Verify after deploying

1. `https://<your-store-domain>/api/config` → `{"checkout_enabled":true,"test_mode":true}` while on test keys.
2. Load the store: products, categories, size charts and any active offers render. If `/api/catalog` returns 503, the SQL in §1 is still unapplied.
3. Place one full test order with a Paystack test card. Confirm: redirect to Paystack, return to `/order/return`, order shows confirmed, stock decreased by exactly one, and one Paystack audit row written.
4. Resend the webhook from the Paystack dashboard (or refresh the return page) — the order must **not** confirm twice or deduct stock twice.
5. Check Vercel logs for `/api/paystack-webhook` returning 200, then switch to live keys, update the live webhook URL, set the live `STORE_ORIGIN`, redeploy, and repeat one small live order with a refund.

---

## 6. If the previous deploy failed

| Symptom in Vercel | Cause | Fix |
| --- | --- | --- |
| `No Output Directory named "public" found after the Build completed` | Framework Preset was **Other** (static site) | Project → Settings → Build & Deployment → Framework Preset = **Next.js**, clear any Build/Output Directory overrides, redeploy |
| `No Output Directory named "dist" found` | Framework Preset was **Vite** (from the dashboard project) | Same as above: preset **Next.js**, no custom output directory |
| `next: not found` / `sh: next: command not found` / `Cannot find module 'next'` | Built from the wrong folder, so `next` was never installed | Set Root Directory to the folder containing this `package.json` (`online-store` in the full workspace, or the repo root of the standalone bundle) |
| Build succeeds but the site is the staff dashboard | Root Directory pointed at the dashboard (or the whole monorepo) | This project must root at the store folder only |
| `Couldn't find any 'pages' or 'app' directory. Please create one under the project root` | The deployed copy is missing the store's `app/` folder. Vercel found `package.json` (so the Root Directory is *roughly* right) but the source it received is incomplete — partial upload/commit, or the files sit one level deeper than the Root Directory points at | Re-upload the **complete** folder (all 13 files under `app/`, plus `lib/`, `components/`, `public/`, `scripts/`, `tests/`, `supabase/`, and dotfiles like `.env.example`/`.gitignore`), or fix Root Directory to the level that really contains `app/`. Verify before pushing: `git ls-files \| grep -c '^app/'` must print **13** (standalone repo) or `git ls-files \| grep -c '^online-store/app/'` → **13** (mono-repo). The bundled `prebuild-check` now prints the same diagnosis, with a listing of what was actually uploaded, into the Vercel log before the build aborts |
| `Could not detect a supported framework` | Repo unzipped without `package.json` at the chosen root | Re-extract the ZIP, keep the folder structure, or set Root Directory correctly |
| `Invalid vercel.json` | Hand-edited config | Use the bundled `vercel.json` unchanged |
| `npm ci … lock file does not satisfy` | `package-lock.json` out of sync after local edits | Run `npm install` locally, commit the refreshed lock file |
| `Error: Cannot find module '/vercel/path0/scripts/prebuild-check.mjs'` | `package.json` was updated (it runs the prebuild source check) but `scripts/` was not copied into the repo | Two options: copy the whole `scripts/` folder into the repo, or use the current `package.json` from this kit — the check now skips itself with a log line when the file is absent, so a partial copy can no longer break the build |
| Deploys fine, but the page says checkout is not configured | Env vars missing (expected on a first deploy) | Add all six variables, redeploy (§3) |
| Home page loads but the collection is empty, or `/api/catalog` returns 503 | Either the SQL in §1 is unapplied (503), the products are switched off/sold out, or the store project points at different Supabase keys | Run the read-only diagnostic `supabase/migrations/30_why_store_products_missing_read_only.sql` in the SQL Editor — it names the exact cause per product and prints a one-line verdict naming the fix |
| Cron warning about schedule frequency | A schedule more frequent than once daily on the Hobby plan | Keep `0 7 * * *`, or upgrade/remove `crons` |

When a deploy fails, copy the first red error block from the Vercel build log — it names the failing step (install, build, or output) and the fix is almost always Root Directory, Framework Preset, or a lock-file mismatch.

---

## 7. Local checks before you push

```bash
npm ci
npm run verify:deploy
npm run typecheck
npm test              # payment verification, discounts, fail-closed states
npm run test:routes   # fake backend; integration of catalog/checkout/webhook/cron
npm run build
npm run dev           # http://localhost:3000
```

Disposable PostgreSQL regression (local machine only, never Supabase) — needs `psql` and a local cluster you own:

```bash
bash tests/sql/run_local_online_store_tests.sh
```

---

## 8. Not included or not done for you

- No production domain, Supabase secret key, Paystack secret key or random `CRON_SECRET` is included — add your own in Vercel.
- **No SQL has been applied** to `jatxzdmrasozbipsfmqy`; the store migrations and the settings recreation are all pending.
- Delivery rates and size measurements are deliberately blank: quote delivery per order until you configure zones, and enter real measurements in the dashboard size charts.
- Legacy files such as `supabase/schema.sql` exist only for the disposable local test bootstrap — never run them against production.
