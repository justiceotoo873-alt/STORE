#!/usr/bin/env bash
# LOCAL DISPOSABLE DB ONLY. Run after assert_online_store.sql AND
# assert_online_store_failures.sql on athena_online_store_test.
set -euo pipefail
DB=athena_online_store_test
psql() { sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
psql -c "UPDATE public.settings SET availability='normal';" >/dev/null
psql <<'SQL' >/dev/null
SET ROLE service_role;
SET test.role='service_role';
SELECT public.store_create_checkout_order(
 '{"name":"Concurrent Test","email":"concurrent@example.com","phone":"+233200000000"}'::jsonb,
 '[{"id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","size":"One size","quantity":1}]'::jsonb,
 'pickup',NULL,'','9090909090909090909090909090909090909090909090909090909090909090');
SQL
order_ref=$(psql -t -A -c "SELECT reference FROM public.store_orders WHERE customer_email='concurrent@example.com'")
order_id=$(psql -t -A -c "SELECT id FROM public.store_orders WHERE customer_email='concurrent@example.com'")
if [[ ! "$order_ref" =~ ^TG[a-f0-9]{32}$ || ! "$order_id" =~ ^[a-f0-9-]{36}$ ]]; then echo 'Fixture creation failed'; exit 1; fi
LOG_DIR="${TMPDIR:-/tmp}"
mkdir -p "$LOG_DIR"
for i in 1 2; do
  psql -t -A -c "SET ROLE service_role; SET test.role='service_role'; SELECT public.store_settle_verified_payment('$order_ref','$order_id'::uuid,2500,'GHS','concurrent@example.com',(SELECT created_at+interval '1 minute' FROM public.store_orders WHERE id='$order_id'::uuid),'test');" >"$LOG_DIR/store-concurrent-$i.log" 2>&1 &
done
wait
for i in 1 2; do grep -q '^confirmed$' "$LOG_DIR/store-concurrent-$i.log" || { cat "$LOG_DIR/store-concurrent-$i.log"; exit 1; }; done
psql -c "DO \$\$ BEGIN
 IF (SELECT stock FROM public.products WHERE id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')<>0
    OR (SELECT payment_status FROM public.store_orders WHERE id='$order_id'::uuid)<>'confirmed'
    OR (SELECT pg_catalog.count(*) FROM public.store_payment_audit WHERE order_id='$order_id'::uuid AND event_type='auto_confirmed')<>1
 THEN RAISE EXCEPTION 'Concurrent callbacks double-decremented stock or audit'; END IF;
 END \$\$;" >/dev/null
echo 'PASS: two simultaneous Paystack callbacks confirmed once, deducted one unit, wrote one audit event'
