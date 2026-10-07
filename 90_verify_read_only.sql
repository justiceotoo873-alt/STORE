-- @thetieguy / Athena — READ-ONLY verification AFTER the approved migrations.
-- Run in the SAME intended Supabase project's SQL Editor. Does not create an
-- order, promotion, delivery fee, product, payment or size measurement.
BEGIN TRANSACTION READ ONLY;
DO $verify$
DECLARE v_settings_count bigint; v_options_count bigint;
BEGIN
 IF pg_catalog.to_regclass('public.settings') IS NULL
    OR pg_catalog.to_regclass('public.staff_users') IS NULL
    OR pg_catalog.to_regclass('public.products') IS NULL
    OR pg_catalog.to_regclass('public.store_orders') IS NULL
    OR pg_catalog.to_regclass('public.store_order_items') IS NULL
    OR pg_catalog.to_regclass('public.store_payment_audit') IS NULL
    OR pg_catalog.to_regclass('public.store_delivery_zones') IS NULL
    OR pg_catalog.to_regclass('public.storefront_options') IS NULL
    OR pg_catalog.to_regclass('public.store_promotions') IS NULL
    OR pg_catalog.to_regclass('public.store_size_charts') IS NULL
    OR pg_catalog.to_regclass('public.store_product_options') IS NULL
    OR pg_catalog.to_regclass('public.store_stock_alerts') IS NULL THEN
   RAISE EXCEPTION 'STOP: a required store, merchandising or prerequisite table is missing';
 END IF;
 SELECT pg_catalog.count(*) INTO v_settings_count FROM public.settings;
 SELECT pg_catalog.count(*) INTO v_options_count FROM public.storefront_options;
 IF v_settings_count<>1 OR v_options_count<>1 THEN
   RAISE EXCEPTION 'STOP: expected ONE settings and ONE storefront options row; found %, %',v_settings_count,v_options_count;
 END IF;
 IF pg_catalog.to_regprocedure('public.thetieguy_store_catalog_v3(integer,integer,text,text,text)') IS NULL
    OR pg_catalog.to_regprocedure('public.store_cart_products_v1(text[])') IS NULL
    OR pg_catalog.to_regprocedure('public.store_size_chart_for_product_v1(text)') IS NULL
    OR pg_catalog.to_regprocedure('public.store_quote_v1(jsonb,text,uuid,text,text)') IS NULL
    OR pg_catalog.to_regprocedure('public.store_create_checkout_order_v2(jsonb,jsonb,text,uuid,text,text,text,integer)') IS NULL
    OR pg_catalog.to_regprocedure('public.store_settle_verified_payment_v2(text,uuid,integer,text,text,timestamptz,text)') IS NULL
    OR pg_catalog.to_regprocedure('public.store_note_checkout_stock_issue(text)') IS NULL THEN
   RAISE EXCEPTION 'STOP: store RPCs are incomplete; do not deploy checkout';
 END IF;
 IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c
    WHERE c.oid=ANY(ARRAY['public.store_orders'::regclass,'public.store_order_items'::regclass,
     'public.store_payment_audit'::regclass,'public.store_delivery_zones'::regclass,
     'public.storefront_options'::regclass,'public.store_promotions'::regclass,
     'public.store_size_charts'::regclass,'public.store_product_options'::regclass,
     'public.store_stock_alerts'::regclass]) AND NOT c.relrowsecurity) THEN
   RAISE EXCEPTION 'STOP: a private store table has RLS disabled';
 END IF;
 IF pg_catalog.has_table_privilege('anon','public.store_orders','SELECT')
    OR pg_catalog.has_table_privilege('anon','public.store_payment_audit','SELECT')
    OR pg_catalog.has_table_privilege('anon','public.store_promotions','SELECT')
    OR pg_catalog.has_table_privilege('anon','public.store_size_charts','SELECT')
    OR pg_catalog.has_table_privilege('anon','public.storefront_options','SELECT')
    OR pg_catalog.has_table_privilege('anon','public.store_stock_alerts','SELECT') THEN
   RAISE EXCEPTION 'STOP: a private store table is exposed to anon';
 END IF;
 IF NOT pg_catalog.has_function_privilege('anon',
    'public.thetieguy_store_catalog_v3(integer,integer,text,text,text)','EXECUTE')
    OR NOT pg_catalog.has_function_privilege('anon','public.store_cart_products_v1(text[])','EXECUTE')
    OR NOT pg_catalog.has_function_privilege('anon','public.store_size_chart_for_product_v1(text)','EXECUTE')
    OR pg_catalog.has_function_privilege('anon',
       'public.store_create_checkout_order_v2(jsonb,jsonb,text,uuid,text,text,text,integer)','EXECUTE')
    OR pg_catalog.has_function_privilege('authenticated',
       'public.store_settle_verified_payment_v2(text,uuid,integer,text,text,timestamptz,text)','EXECUTE')
    OR pg_catalog.has_function_privilege('anon','public.store_quote_v1(jsonb,text,uuid,text,text)','EXECUTE')
    OR NOT pg_catalog.has_function_privilege('service_role',
       'public.store_settle_verified_payment_v2(text,uuid,integer,text,text,timestamptz,text)','EXECUTE') THEN
   RAISE EXCEPTION 'STOP: store RPC execution privileges need review';
 END IF;
 RAISE NOTICE 'PASS: one settings row, one design row, expected RPCs, private-table RLS and role grants';
END;
$verify$;

-- Output is aggregate/non-personal: no business text, contact data or orders.
SELECT (SELECT pg_catalog.count(*) FROM public.products WHERE active=true) AS active_product_count,
 (SELECT pg_catalog.count(*) FROM public.store_delivery_zones WHERE active=true) AS configured_delivery_zones,
 (SELECT pg_catalog.count(*) FROM public.store_size_charts WHERE active=true) AS published_size_charts,
 (SELECT pg_catalog.count(*) FROM public.store_promotions WHERE active=true) AS active_offer_rules,
 (SELECT availability IN ('normal','available') FROM public.settings LIMIT 1) AS accepting_online_orders;
SELECT t.tgname AS product_alert_trigger
 FROM pg_catalog.pg_trigger t WHERE t.tgrelid='public.products'::regclass
  AND NOT t.tgisinternal AND t.tgname='store_stock_notifications';
COMMIT;
