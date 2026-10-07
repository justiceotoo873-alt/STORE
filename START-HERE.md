# @thetieguy online store — deploy bundle

This archive **is** the customer store. Its root folder contains `package.json`,
so in Vercel you root the project here and pick the **Next.js** framework preset.
Full instructions: [`DEPLOY-STORE.md`](DEPLOY-STORE.md).

## Deploy in five steps

1. **Apply the SQL first** (Supabase → SQL Editor, project `jatxzdmrasozbipsfmqy`), in order:
   `supabase/migrations/00_preflight_read_only.sql` (read-only) →
   `supabase/migrations/20260929_recreate_deleted_settings_uuid.sql` **only if the preflight says `public.settings` is missing** →
   `supabase/migrations/20260930_online_store_paystack.sql` →
   `supabase/migrations/20261001_store_merchandising.sql` →
   `supabase/migrations/90_verify_read_only.sql` (read-only).
   None of these have been applied for you. Compare `supabase/migrations/SHA256SUMS.txt` to be sure you have the reviewed files.
2. **Push this folder to Git** (its own repo is easiest), or skip Git and use the CLI: `npm i -g vercel && vercel login && vercel link && vercel --prod` from this folder.
3. **Vercel project**: Root Directory = this folder; Framework Preset = **Next.js**; leave Build/Output/Install commands empty; keep the bundled `vercel.json` (it pins the framework and one daily cron).
4. **Add these environment variables** (Production *and* Preview), then redeploy:
   `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`,
   `SUPABASE_SERVICE_ROLE_KEY` (server secret), `PAYSTACK_SECRET_KEY` (start with `sk_test_…`),
   `STORE_ORIGIN` (exact `https://…` origin, no trailing slash), `CRON_SECRET` (32+ random characters),
   and optionally `NEXT_PUBLIC_WHATSAPP_GROUP_URL` (the group invite shown on the thank-you page).
   Real keys are deliberately **not** in this archive. The site still deploys without them and shows checkout disabled.
5. **Paystack**: set the webhook URL to `https://<your-domain>/api/paystack-webhook`, take one test-key order end to end, then switch to live keys and redeploy. Now open `/api/config` — it must report `checkout_enabled: true`.

## Updating an existing deployment (no new project)

Copy these over your repo and push — Vercel rebuilds the same project:

```
components/Storefront.tsx        components/PaymentReturn.tsx     components/WhatsAppIcon.tsx (new)
app/order/return/page.tsx        app/api/payment-status/route.ts  app/globals.css
lib/catalog.ts                   package.json                     .env.example
scripts/                         (the WHOLE folder: prebuild-check.mjs + verify-deploy.mjs)
tests/                           (optional: the browser + unit checks, not used at runtime)
```

`package.json` now runs `scripts/prebuild-check.mjs` before every build. If you copy
`package.json` without `scripts/`, older copies fail with
`Cannot find module '.../scripts/prebuild-check.mjs'`; this kit's version only warns and
continues, but copying the folder keeps the useful "what did I actually upload?" diagnosis.

## If the build says "Couldn't find any 'pages' or 'app' directory"

Next.js ran in a folder that has a `package.json` but no `app/` at that level — the
source and the Vercel Root Directory setting disagree. In your repo run:

```bash
bash diagnose-repo.sh        # read-only; prints where app/ really is and what to set
```

It prints the folder that holds `app/`, whether git is tracking those files, and the
Root Directory value to use. (The same diagnosis now prints in the Vercel build log
whenever `package.json` and `scripts/` are both present.)

## Before you push

```bash
npm ci
npm run verify:deploy      # structure, Node version, variable names, secret-leak scan
npm run typecheck
npm test
npm run test:routes
npm run build
```

## Warnings

- **No SQL has been applied** to your live project, and nothing has been deployed for you.
- Delivery rates and size measurements are intentionally blank: quote delivery per order until zones are configured, and enter real measurements in the dashboard size charts.
- `supabase/schema.sql` and everything under `tests/sql/` exist only for a **disposable local PostgreSQL** regression (`bash tests/sql/run_local_online_store_tests.sh`). **Never run them against Supabase.**
- Never put `SUPABASE_SERVICE_ROLE_KEY`, `PAYSTACK_SECRET_KEY` or `CRON_SECRET` in a `NEXT_PUBLIC_` variable, in HTML, or in Git.
