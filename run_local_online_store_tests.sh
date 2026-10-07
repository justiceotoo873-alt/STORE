#!/usr/bin/env bash
# Disposable LOCAL PostgreSQL only. NEVER point this runner at Supabase.
# Recreates athena_online_store_test; no connection URL or user input is accepted.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB=athena_online_store_test
reset_db() {
  sudo -u postgres dropdb --if-exists "$DB"
  sudo -u postgres createdb "$DB"
}
run_sql() {
  cat "$@" | sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 -d "$DB" >/dev/null
}
BASE=(tests/sql/bootstrap_mock_supabase.sql supabase/schema.sql supabase/migrations/20260930_online_store_paystack.sql)
MERCH=supabase/migrations/20261001_store_merchandising.sql
reset_db
run_sql "${BASE[@]}" tests/sql/assert_online_store.sql tests/sql/assert_online_store_failures.sql
bash tests/sql/assert_auto_concurrency.sh
printf 'PASS: original store, exceptional payments and concurrent settlement\n'
reset_db
run_sql "${BASE[@]}" "$MERCH" tests/sql/assert_store_merchandising.sql
printf 'PASS: merchandising catalog, offers, charts, stock alerts and discounts\n'
reset_db
run_sql tests/sql/bootstrap_mock_supabase.sql tests/sql/store_bigint_fixture.sql \
  supabase/migrations/20260930_online_store_paystack.sql "$MERCH" tests/sql/assert_store_merch_bigint.sql
printf 'PASS: bigint product IDs and UUID settings, discounted settlement\n'
