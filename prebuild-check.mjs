#!/usr/bin/env node
/**
 * Runs automatically before `npm run build` (npm "prebuild") on your machine
 * and on Vercel. It exists to turn the cryptic
 *
 *   Error: Couldn't find any 'pages' or 'app' directory.
 *
 * into an exact explanation of what is missing and how to fix it.
 *
 * It never contacts the network and never prints secret values.
 */
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = process.cwd();
const REQUIRED = [
  ['app/layout.tsx', 'root layout'],
  ['app/page.tsx', 'storefront page'],
  ['app/api/catalog/route.ts', 'catalog API'],
  ['app/api/checkout/route.ts', 'checkout API'],
  ['package.json', 'project manifest'],
  ['next.config.mjs', 'Next.js configuration'],
];

const missing = REQUIRED.filter(([file]) => !existsSync(join(root, file)));

if (missing.length === 0) {
  const routes = existsSync(join(root, 'app', 'api'))
    ? readdirSync(join(root, 'app', 'api')).length
    : 0;
  console.log(`prebuild-check: store source OK at ${root} (${REQUIRED.length - 1} key files, ${routes} API routes)`);
  process.exit(0);
}

const listing = readdirSync(root, { withFileTypes: true })
  .slice(0, 30)
  .map((entry) => {
    const marker = entry.isDirectory() ? '/' : '';
    try {
      const size = entry.isDirectory() ? '' : ` (${statSync(join(root, entry.name)).size} bytes)`;
      return `  ${entry.name}${marker}${size}`;
    } catch {
      return `  ${entry.name}${marker}`;
    }
  })
  .join('\n');

console.error(`
==========================================================================
STORE SOURCE IS INCOMPLETE — build stopped before Next.js ran.
==========================================================================
Vercel is building this folder: ${root}
Missing (checked relative to that folder):
${missing.map(([file, why]) => `  ✗ ${file.padEnd(28)} (${why})`).join('\n')}

What is actually in the deployed folder:
${listing || '  (empty)'}

This means the project you deployed does not contain the full store folder —
usually because only part of it was uploaded/committed, or the files ended up
one level deeper than the Root Directory setting points at.

Correct layouts (pick one):

  1) Standalone store repo — Vercel Root Directory left EMPTY, Framework Next.js
       <repo root>/package.json
       <repo root>/app/layout.tsx
       <repo root>/app/page.tsx

  2) Mono-repo — Vercel Root Directory = online-store, Framework Next.js
       <repo root>/online-store/package.json
       <repo root>/online-store/app/layout.tsx

Fix: re-upload the complete folder (all 13 files under app/ plus lib/,
components/, public/, scripts/, tests/, supabase/, and every dotfile such as
.env.example and .gitignore), then redeploy. Verify the push is complete with:

    git ls-files | grep -c '^app/'        # must print 13 (standalone repo)
    git ls-files | grep -c '^online-store/app/'   # mono-repo: must print 13

Full instructions: DEPLOY-STORE.md §2 and the troubleshooting table in §6.
==========================================================================
`);

const wanted = resolve(root);
console.error(`(Nothing was modified; this check only reads files. Root checked: ${wanted})`);
process.exit(1);
