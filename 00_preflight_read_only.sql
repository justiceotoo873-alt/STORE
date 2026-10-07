-- @thetieguy / Athena — READ-ONLY preflight for the intended Supabase project.
-- Run in Supabase SQL Editor *before* any migration; no business/customer rows
-- or secrets are read. Review every result before changing the live database.
-- Do not run the old supabase/schema.sql on an existing project.
BEGIN TRANSACTION READ ONLY;

-- The settings recreation script is ONLY for an ABSENT settings table.
-- An existing table, even with a non-UUID ID, must not be recreated.
SELECT name, pg_catalog.to_regclass('public.' || name) IS NOT NULL AS exists_now
FROM (VALUES ('settings'),('staff_users'),('products'),('store_orders'),
 ('storefront_options'),('store_promotions'),('store_size_charts'),
 ('store_product_options'),('store_stock_alerts')) AS objects(name)
ORDER BY name;

-- The baseline migration needs one settings row, products with these columns,
-- staff_users and is_staff(uuid). Inspect any missing/wrongly typed column.
SELECT required.table_name, required.column_name, c.data_type, c.udt_name,
       c.column_default, c.is_nullable,
       CASE WHEN c.column_name IS NULL THEN 'MISSING — STOP' ELSE 'REVIEW TYPE' END AS check_status
FROM (VALUES
 ('settings','id'),('settings','business_name'),('settings','availability'),
 ('settings','unavailable_message'),('products','id'),('products','name'),
 ('products','category'),('products','price'),('products','stock'),
 ('products','sizes'),('products','description'),('products','image_url'),
 ('products','active'),('staff_users','user_id')) AS required(table_name,column_name)
LEFT JOIN information_schema.columns c ON c.table_schema='public'
 AND c.table_name=required.table_name AND c.column_name=required.column_name
ORDER BY required.table_name,required.column_name;

SELECT pg_catalog.to_regprocedure('public.is_staff(uuid)') IS NOT NULL AS is_staff_function_present,
       pg_catalog.to_regprocedure('public.athena_can_reply(uuid)') IS NOT NULL AS athena_can_reply_present,
       pg_catalog.to_regprocedure('public.store_create_checkout_order(jsonb,jsonb,text,uuid,text,text)') IS NOT NULL AS baseline_store_already_exists,
       pg_catalog.to_regprocedure('public.store_create_checkout_order_v2(jsonb,jsonb,text,uuid,text,text,text,integer)') IS NOT NULL AS merchandising_already_exists;

-- Check existing access, triggers and publication membership; do not assume
-- a similarly named column implies an intact policy or stock trigger.
SELECT c.relname AS table_name,c.relrowsecurity AS rls_enabled,
       c.relforcerowsecurity AS force_rls
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind IN ('r','p') AND c.relname IN
 ('settings','staff_users','products','orders','customers','conversations',
  'store_orders','store_promotions','store_size_charts','storefront_options')
ORDER BY c.relname;
SELECT tablename,policyname,cmd,roles,qual,with_check
FROM pg_catalog.pg_policies WHERE schemaname='public'
 AND tablename IN ('staff_users','products','orders','settings','customers')
ORDER BY tablename,policyname;
SELECT c.relname AS table_name,t.tgname AS trigger_name,
       pg_catalog.pg_get_triggerdef(t.oid,true) AS definition
FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid
 JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND NOT t.tgisinternal
 AND c.relname IN ('settings','products','orders') ORDER BY c.relname,t.tgname;
SELECT schemaname,tablename FROM pg_catalog.pg_publication_tables
 WHERE pubname='supabase_realtime' AND schemaname='public'
 AND tablename IN ('products','settings','store_orders','storefront_options',
  'store_promotions','store_size_charts','store_product_options','store_stock_alerts')
 ORDER BY tablename;

-- These function NAMES (not bodies/data) can reveal legacy settings.id='main'
-- dependencies that must be audited separately before enabling the AI.
SELECT p.proname AS function_name,pg_catalog.pg_get_function_identity_arguments(p.oid) AS signature
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.prokind='f'
  AND pg_catalog.pg_get_functiondef(p.oid) LIKE '%''main''%'
ORDER BY p.proname;
COMMIT;

-- If settings EXISTS, obtain its row count and current availability with
-- SELECT count(*), min(availability) FROM public.settings; do NOT run that
-- query if settings is absent. If store objects already exist, STOP: the
-- migrations are fresh-create/guarded and are not safe reruns.
