#!/usr/bin/env node
/**
 * Deploy-readiness check for the @thetieguy online store.
 *
 *   npm run verify:deploy            # report only
 *   npm run verify:deploy -- --strict  # exit 1 if checkout-critical values are missing
 *
 * Reads names/presence only. It never prints secret values, never contacts
 * Supabase, Vercel or Paystack, and never writes to your database.
 */
import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const strict = process.argv.includes('--strict');
const problems = [];
const notes = [];

const REQUIRED_FILES = [
  'package.json', 'package-lock.json', 'next.config.mjs', 'vercel.json',
  'app/layout.tsx', 'app/page.tsx', 'app/api/catalog/route.ts',
  'app/api/checkout/route.ts', 'app/api/paystack-webhook/route.ts',
  'lib/server.ts', 'lib/paystack.ts', 'lib/payment-flow.ts',
];

const VARS = [
  { name: 'NEXT_PUBLIC_SUPABASE_URL', scope: 'public', needed: 'Browser + server reads catalog/config', example: 'https://YOUR-PROJECT-ref.supabase.co', checkout: true },
  { name: 'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY', scope: 'public', needed: 'Browser-safe read key', example: 'sb_publishable_... or anon JWT', checkout: true },
  { name: 'SUPABASE_SERVICE_ROLE_KEY', scope: 'server secret', needed: 'Order creation, stock deduction, settlement', example: 'sb_secret_... or service_role JWT', checkout: true },
  { name: 'PAYSTACK_SECRET_KEY', scope: 'server secret', needed: 'Initialize + independently verify payments', example: 'sk_test_... (start here)', checkout: true },
  { name: 'STORE_ORIGIN', scope: 'server', needed: 'Exact HTTPS origin used for the Paystack callback', example: 'https://your-store-domain', checkout: true },
  { name: 'CRON_SECRET', scope: 'server secret', needed: 'Protects the daily missed-webhook reconciliation route', example: '32+ random characters', checkout: false },
  { name: 'NEXT_PUBLIC_WHATSAPP_GROUP_URL', scope: 'public', needed: 'Invite shown on the post-payment thank-you page (optional; without it the page says the invite is being set up)', example: 'https://chat.whatsapp.com/XXXXXXXX', optional: true },
  { name: 'NEXT_PUBLIC_SUPPORT_WHATSAPP', scope: 'public', needed: 'Support chat for the floating button, footer and failed-payment page (optional; defaults to 233592060208)', example: '233592060208', optional: true },
];

function readEnvFile(path) {
  if (!existsSync(path)) return {};
  const out = {};
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (match) out[match[1]] = match[2].replace(/^["']|["']$/g, '');
  }
  return out;
}

const localEnv = { ...readEnvFile(join(root, '.env.local')), ...readEnvFile(join(root, '.env')) };
const valueOf = (name) => (process.env[name] ?? localEnv[name] ?? '').trim();
const sourceOf = (name) => (process.env[name] ? 'process env' : localEnv[name] ? '.env.local' : '');

console.log('\n@thetieguy online store — deploy readiness\n' + '='.repeat(48));

const nodeMajor = Number(process.versions.node.split('.')[0]);
console.log(`Node.js            ${process.versions.node}${nodeMajor >= 20 ? '' : '   (Next.js 15 needs Node 20+)'}`);
if (nodeMajor < 20) problems.push('Node.js 20 or newer is required (Vercel defaults to 22; your local build needs 20+).');

let missingFiles = 0;
for (const file of REQUIRED_FILES) {
  if (!existsSync(join(root, file))) {
    missingFiles += 1;
    console.log(`MISSING            ${file}`);
  }
}
if (missingFiles) problems.push(`${missingFiles} required file(s) missing — re-extract the store folder/ZIP before deploying.`);
else console.log('File structure     OK (Next.js App Router + API routes present)');

for (const file of ['package.json', 'vercel.json', 'tsconfig.json']) {
  try {
    JSON.parse(readFileSync(join(root, file), 'utf8'));
  } catch (error) {
    problems.push(`${file} is not valid JSON (${error.message.split('\n')[0]})`);
  }
}

console.log('\nEnvironment variables (names only — values are never printed)');
for (const variable of VARS) {
  const present = Boolean(valueOf(variable.name));
  const label = present ? 'SET    ' : variable.optional ? 'optional' : 'MISSING';
  console.log(`  ${label}  ${variable.name.padEnd(38)} ${variable.scope}`);
  if (!present && variable.optional) notes.push(`${variable.name} is not set — optional. Add it in Vercel to show a WhatsApp group invitation on the thank-you page. Example: ${variable.example}`);
  else if (!present) notes.push(`${variable.name} is not set here — add it in Vercel (Project → Settings → Environment Variables) for Production and Preview, then redeploy. Needed for: ${variable.needed}. Example: ${variable.example}`);
}

const publishable = valueOf('NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY');
const serviceRole = valueOf('SUPABASE_SERVICE_ROLE_KEY');
const paystack = valueOf('PAYSTACK_SECRET_KEY');
const storeOrigin = valueOf('STORE_ORIGIN');
const cronSecret = valueOf('CRON_SECRET');

if (serviceRole && !/^(sb_secret_|eyJ)/.test(serviceRole)) problems.push('SUPABASE_SERVICE_ROLE_KEY does not look like a server key (expected sb_secret_… or a service_role JWT).');
if (publishable && /^(sb_secret_|eyJ[A-Za-z0-9_-]*\.)/.test(publishable) && publishable.split('.').length > 2) notes.push('Check NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: a JWT there must be the anon/publishable key, never service_role — anything NEXT_PUBLIC_ ends up in the browser.');
if (publishable && publishable.startsWith('sb_secret_')) problems.push('NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY starts with sb_secret_ — a server key must never be published to the browser.');
if (paystack && paystack.startsWith('sk_live_')) notes.push('PAYSTACK_SECRET_KEY is a LIVE key. Do a full test-key order (sk_test_…) before switching to live.');
if (paystack && !/^sk_(test|live)_/.test(paystack)) problems.push('PAYSTACK_SECRET_KEY should start with sk_test_ or sk_live_.');
const support = valueOf('NEXT_PUBLIC_SUPPORT_WHATSAPP');
if (support && !/^\+?[0-9][0-9\s-]{7,}$/.test(support))
  problems.push('NEXT_PUBLIC_SUPPORT_WHATSAPP should be a phone number in international form (e.g. 233592060208).');
const invite = valueOf('NEXT_PUBLIC_WHATSAPP_GROUP_URL');
if (invite && !/^https:\/\/(chat\.whatsapp\.com\/[^\s]+|wa\.me\/[^\s]+|(www\.)?whatsapp\.com\/[^\s]+)$/i.test(invite))
  problems.push('NEXT_PUBLIC_WHATSAPP_GROUP_URL should be an https WhatsApp invite link (chat.whatsapp.com/…, wa.me/… or whatsapp.com/…). An invalid value is ignored by the thank-you page.');
if (storeOrigin && !/^https:\/\/[^\s/]+$/.test(storeOrigin)) problems.push(`STORE_ORIGIN must be a bare HTTPS origin with no trailing slash, e.g. https://your-store-domain (currently ${storeOrigin.replace(/[^/]/g, '*')} shape).`);
if (cronSecret && cronSecret.length < 32) problems.push('CRON_SECRET should be at least 32 random characters; Vercel sends it to /api/reconcile-pending as Authorization: Bearer …');

const SECRET_PATTERNS = [/sb_secret_[A-Za-z0-9_-]{8,}/, /sk_live_[A-Za-z0-9]{8,}/, /service_role["'\s:]+[A-Za-z0-9._-]{20,}/];
const SKIP_DIRS = new Set(['node_modules', '.next', '.git', '.vercel', 'test-results', 'playwright-report']);
const leaked = [];
(function scan(directory) {
  for (const entry of readdirSync(directory)) {
    if (SKIP_DIRS.has(entry)) continue;
    const full = join(directory, entry);
    const stats = statSync(full);
    if (stats.isDirectory()) { scan(full); continue; }
    if (stats.size > 400_000 || !/\.(ts|tsx|mjs|cjs|js|json|md|css|html|example|env|local)$/.test(entry)) continue;
    const text = readFileSync(full, 'utf8');
    if (SECRET_PATTERNS.some((pattern) => pattern.test(text))) leaked.push(relative(root, full));
  }
})(root);
if (leaked.length) problems.push(`Possible server secret committed in source: ${leaked.join(', ')} — rotate it and keep server keys in Vercel environment variables only.`);

console.log('\nNext steps');
const checkoutReady = ['NEXT_PUBLIC_SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'PAYSTACK_SECRET_KEY', 'STORE_ORIGIN'].every((name) => Boolean(valueOf(name)));
console.log(checkoutReady
  ? '  Environment values are present. Apply the SQL in order, deploy, then open /api/config and confirm {"checkout_enabled":true}.'
  : '  Expected locally — Vercel holds the real values. Add every name above in the store project, then redeploy. Until then the site deploys but keeps checkout disabled.');
console.log('  Read DEPLOY-STORE.md for the SQL order, Vercel settings, Paystack webhook and test-to-live checklist.');

if (notes.length) {
  console.log('\nNotes');
  for (const note of notes) console.log(`  - ${note}`);
}
if (problems.length) {
  console.log('\nProblems to fix');
  for (const problem of problems) console.log(`  ✗ ${problem}`);
}
console.log(`\n${problems.length ? `FAIL: ${problems.length} problem(s).` : 'PASS: structure looks deployable.'}${strict && !checkoutReady ? ' (--strict: checkout values are not set here yet.)' : ''}\n`);

process.exitCode = problems.length || (strict && !checkoutReady) ? 1 : 0;
