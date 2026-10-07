(This same numbered set is included in the store ZIP under supabase/APPLY-IN-SUPABASE/.)

HOW TO FIX "The live collection is temporarily unavailable"  (HTTP 503)
========================================================================
That message comes from the store's server: it asked your Supabase project for
the product catalog and the call failed. The usual cause is simply that the
store's database side has never been created — it is created by running the
files in this folder, in this order, ONCE, in the Supabase SQL Editor.

WHICH PROJECT:  jatxzdmrasozbipsfmqy   (the same project your dashboard uses)
WHERE:          Supabase dashboard -> your project -> "SQL Editor" -> New query
HOW:            Open a file below, copy ALL of it, paste into the editor, click
                "Run". Then go to the next file. Take them in order.
BEFORE YOU START: Supabase -> Database -> Backups: confirm a recent backup
                exists (or click "Create backup"). These scripts add new tables
                and functions only; they do not delete products, customers or
                orders. Running them twice is blocked by built-in guards.

========================================================================
1-CHECK-FIRST-read-only.sql        (writes nothing — run this one first)
------------------------------------------------------------------------
Ends with one row: "verdict".
  * "MIGRATIONS NOT APPLIED ..."        -> continue with files 2, 3, 4.
  * "RPC EXISTS BUT anon CANNOT ..."    -> do NOT rerun the migrations;
                                           the store project's Supabase keys
                                           are wrong (see note at the bottom).
  * "NO ACTIVE PRODUCTS ..."            -> migrations are fine; open the
                                           dashboard and switch products on.
  * "STORE-SIDE DATA LOOKS FINE ..."    -> migrations are fine; the store site
                                           is an old deployment or the keys
                                           differ; hard-refresh, then redeploy.

2-only-if-settings-is-missing.sql   (skip unless file 1 said settings missing)
3-store-baseline.sql                (creates the store's tables + functions)
4-merchandising.sql                 (offers, size charts, stock alerts)
5-verify-read-only.sql              (writes nothing — final check)
------------------------------------------------------------------------
Success looks like this in file 5:  "PASS: one settings row, one design row,
expected RPCs, private-table RLS and role grants", plus a "product_alert_trigger
store_stock_notifications" row.

THEN: open  https://<your-store-domain>/api/catalog  in a browser.
  * It should return JSON starting {"business": ... }
  * Hard-refresh the store page — your dashboard products now appear.

========================================================================
IF SOMETHING STOPS WITH A MESSAGE INSTEAD
------------------------------------------------------------------------
The scripts are deliberately cautious. Copy the red error line and send it
back to me; each guard message says exactly what it protects:
  * "public.settings already exists; stopped to protect it"  -> normal, skip file 2.
  * "Merchandising already exists; inspect deployed schema"  -> files 3-4 were
    already applied; just run file 5.
  * "Expected existing settings/products/staff_users ..."    -> wrong project,
    or file 2 was needed first.

TWO IMPORTANT RULES
------------------------------------------------------------------------
1. NEVER run supabase/schema.sql, or anything under tests/sql/, against this
   live project. Those are disposable local-test fixtures only.
2. The store reads the catalog with the public key and the URL set in Vercel:
        NEXT_PUBLIC_SUPABASE_URL
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
   Both must belong to project jatxzdmrasozbipsfmqy (Supabase -> Project
   Settings -> API). If they name a different project, the store will show
   503 or an empty catalog even after these scripts succeed.
