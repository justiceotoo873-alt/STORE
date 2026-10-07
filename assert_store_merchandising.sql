-- Disposable local PostgreSQL fixture ONLY. Never run against live Supabase.
-- The real Supabase service_role bypasses RLS; reproduce that locally.
ALTER ROLE service_role BYPASSRLS;
INSERT INTO public.store_product_options(product_id,low_stock_threshold,featured) VALUES('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,true);
INSERT INTO public.products(id,name,category,price,stock,sizes,description,image_url,active)
 VALUES('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Fixture limited tie','Neckties',10.00,2,ARRAY['One size'],'Test','',true);
INSERT INTO public.products(id,name,category,price,stock,sizes,description,image_url,active)
 SELECT pg_catalog.gen_random_uuid(),'Fixture piece '||n,'Neckties',n,6,ARRAY['One size'],'Test','',true
 FROM pg_catalog.generate_series(1,64) AS seq(n);
UPDATE public.settings SET availability='normal';
INSERT INTO auth.users(id,email) VALUES('11111111-1111-4111-8111-111111111111','owner@example.com');
INSERT INTO public.staff_users(user_id,role) VALUES('11111111-1111-4111-8111-111111111111','owner');
INSERT INTO public.store_delivery_zones(name,fee_minor) VALUES('Fixture Zone',500);
INSERT INTO public.store_size_charts(category,title,units,columns,rows,default_for_category,active)
 VALUES('Neckties','Fixture category chart','cm',ARRAY['Style','Length'], '[ ["Classic","not a real measurement"] ]'::jsonb,true,true);
INSERT INTO public.store_promotions(name,code,kind,percent_off,scope,categories,min_subtotal_minor,max_redemptions,active)
 VALUES('Fixture code','SAVE10','percentage',10,'categories',ARRAY['Neckties'],1000,1,true);
INSERT INTO public.store_promotions(name,kind,amount_minor,scope,free_delivery,max_redemptions,active)
 VALUES('Fixture automatic','fixed',200,'all',true,1,true);
DO $assert$
BEGIN
 IF (SELECT pg_catalog.count(*) FROM public.store_stock_alerts WHERE event_type IN ('low','out'))<>0 THEN
   RAISE EXCEPTION 'Creation of active stock 2 with threshold1 should not alert'; END IF;
 IF pg_catalog.has_table_privilege('anon','public.store_promotions','SELECT')
  OR pg_catalog.has_table_privilege('anon','public.store_size_charts','SELECT')
  OR pg_catalog.has_table_privilege('anon','public.store_stock_alerts','SELECT')
  OR pg_catalog.has_function_privilege('anon','public.store_create_checkout_order_v2(jsonb,jsonb,text,uuid,text,text,text,integer)','EXECUTE')
  OR pg_catalog.has_function_privilege('anon','public.store_price_offer_v1(integer,integer,jsonb,text,text,boolean)','EXECUTE')
  OR pg_catalog.has_function_privilege('anon','public.thetieguy_store_catalog_v2()','EXECUTE') THEN
   RAISE EXCEPTION 'A privileged merchandising object or old unbounded catalog is public'; END IF;
 BEGIN
  INSERT INTO public.store_size_charts(category,title,columns,rows)
    VALUES('Neckties','Invalid chart',ARRAY['Style','Length'], '[ ["Too few columns"] ]'::jsonb);
  RAISE EXCEPTION 'Invalid chart rows passed database validation';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
END;
$assert$;
SET ROLE anon;
DO $assert$ DECLARE v jsonb;v_chart jsonb;
BEGIN
 v:=public.thetieguy_store_catalog_v3(1,24,'All','','featured');
 IF (v->>'total_count')::integer<>65 OR pg_catalog.jsonb_array_length(v->'products')<>24
   OR (v #>> '{products,0,id}')<>'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   OR (v #>> '{storefront,hero_title}')<>'A little detail.' THEN
    RAISE EXCEPTION 'Paginated/featured public catalog is wrong: %',v; END IF;
 v:=public.thetieguy_store_catalog_v3(3,24,'All','','featured');
 IF pg_catalog.jsonb_array_length(v->'products')<>17 OR (v->>'total_count')::integer<>65 THEN
    RAISE EXCEPTION 'Last page lost products'; END IF;
 v:=public.thetieguy_store_catalog_v3(1,24,'Ties','Fixture piece 53','low');
 IF (v->>'total_count')::integer<>1 OR (v #>> '{products,0,name}')<>'Fixture piece 53' THEN
    RAISE EXCEPTION 'Server-side search/filter did not span pages: %',v; END IF;
 IF pg_catalog.jsonb_array_length(public.store_cart_products_v1(ARRAY['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa']))<>1 THEN
    RAISE EXCEPTION 'Cart item beyond page not resolvable'; END IF;
 v_chart:=public.store_size_chart_for_product_v1('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
 IF v_chart->>'title'<>'Fixture category chart' THEN RAISE EXCEPTION 'Category chart not visible'; END IF;
 BEGIN
  PERFORM 1 FROM public.store_promotions;
  RAISE EXCEPTION 'Anon read private promotion';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
END;
$assert$;
RESET ROLE;
SET ROLE service_role;
SET test.role='service_role';
DO $assert$
DECLARE v_items jsonb:='[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","size":"One size","quantity":1}]'::jsonb;
 v_zone uuid;v_quote jsonb;v_order jsonb;v_paid_at timestamptz:=pg_catalog.now();v_count integer;
BEGIN
 SELECT id INTO v_zone FROM public.store_delivery_zones LIMIT 1;
 v_quote:=public.store_quote_v1(v_items,'delivery',v_zone,'SAVE10','buyer@example.com');
 -- The automatic offer saves 200 on the product and 500 on the actual fee.
 IF (v_quote->>'amount_minor')::integer<>800 OR (v_quote->>'discount_minor')::integer<>200
   OR (v_quote->>'delivery_discount_minor')::integer<>500
   OR v_quote->>'promotion_name'<>'Fixture automatic' THEN RAISE EXCEPTION 'Best offer is wrong: %',v_quote; END IF;
 BEGIN
   PERFORM public.store_create_checkout_order_v2(
    '{"name":"Fixture Buyer","email":"buyer@example.com","phone":"+233200000000"}'::jsonb,
    v_items,'delivery',v_zone,'Somewhere Accra Street','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','SAVE10',1);
   RAISE EXCEPTION 'Mismatched quote did not abort checkout';
 EXCEPTION WHEN OTHERS THEN
   IF SQLERRM NOT LIKE 'Price or promotion changed%' THEN RAISE; END IF;
 END;
 IF (SELECT pg_catalog.count(*) FROM public.store_orders)<>0 OR (SELECT pg_catalog.count(*) FROM public.store_checkout_attempts)<>0 THEN
   RAISE EXCEPTION 'Failed pricing left a stock reservation / attempt'; END IF;
 v_order:=public.store_create_checkout_order_v2(
    '{"name":"Fixture Buyer","email":"buyer@example.com","phone":"+233200000000"}'::jsonb,
    v_items,'delivery',v_zone,'Somewhere Accra Street','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','SAVE10',800);
 IF (v_order->>'amount_minor')::integer<>800 OR (SELECT amount_minor FROM public.store_orders WHERE id=(v_order->>'id')::uuid)<>800 THEN
    RAISE EXCEPTION 'Checkout did not snapshot discounted charge'; END IF;
 IF (SELECT stock FROM public.products WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>2 THEN
    RAISE EXCEPTION 'Discount checkout deducted stock before Paystack'; END IF;
 IF public.store_settle_verified_payment_v2(v_order->>'reference',(v_order->>'id')::uuid,800,'GHS',
    'buyer@example.com',v_paid_at,'test')<>'confirmed'
   OR public.store_settle_verified_payment_v2(v_order->>'reference',(v_order->>'id')::uuid,800,'GHS',
    'buyer@example.com',v_paid_at,'test')<>'confirmed' THEN RAISE EXCEPTION 'Discounted payment did not settle exactly once'; END IF;
 IF (SELECT stock FROM public.products WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>1
  OR NOT EXISTS(SELECT 1 FROM public.store_stock_alerts WHERE product_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' AND event_type='low') THEN
    RAISE EXCEPTION 'Low stock alert missing after real payment'; END IF;
 v_quote:=public.store_quote_v1(v_items,'delivery',v_zone,'SAVE10','another@example.com');
 IF (v_quote->>'amount_minor')::integer<>1400 OR v_quote->>'promotion_code'<>'SAVE10' THEN
    RAISE EXCEPTION 'Auto offer with max1 was reused or eligible code rejected: %',v_quote; END IF;
 PERFORM public.store_note_checkout_stock_issue('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
 -- Note: stock=1 and not reserved, so no blocked alert.
 IF EXISTS(SELECT 1 FROM public.store_stock_alerts WHERE event_type='checkout_blocked') THEN RAISE EXCEPTION 'False blocked alert'; END IF;
END;
$assert$;
RESET ROLE;
-- Simulate a timely payment callback arriving AFTER its promotion hold expired
-- and a second checkout reserved the final use. No auto-confirmation/stock
-- change for the older order; the newer one can still settle safely.
SET ROLE service_role;
SET test.role='service_role';
DO $delayed$
DECLARE v_items jsonb:='[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","size":"One size","quantity":1}]'::jsonb;
 a jsonb;b jsonb;v_paid_at timestamptz;v_zone uuid;
BEGIN
 SELECT id INTO v_zone FROM public.store_delivery_zones LIMIT 1;
 a:=public.store_create_checkout_order_v2('{"name":"Delayed Buyer","email":"delayed@example.com","phone":"+233200000001"}'::jsonb,
  v_items,'delivery',v_zone,'Another Accra Street','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','SAVE10',1400);
 v_paid_at:=(SELECT created_at-interval '1 second' FROM public.store_orders WHERE id=(a->>'id')::uuid);
 UPDATE public.store_orders SET reservation_expires_at=pg_catalog.now()-interval '1 millisecond' WHERE id=(a->>'id')::uuid;
 b:=public.store_create_checkout_order_v2('{"name":"Second Buyer","email":"second@example.com","phone":"+233200000002"}'::jsonb,
  v_items,'delivery',v_zone,'Second Accra Street','cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc','SAVE10',1400);
 IF public.store_settle_verified_payment_v2(a->>'reference',(a->>'id')::uuid,1400,'GHS','delayed@example.com',v_paid_at,'test')<>'provider_verified' THEN
   RAISE EXCEPTION 'Delayed over-cap charge should require staff review'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.store_orders WHERE id=(a->>'id')::uuid AND review_reason='promotion_exhausted'
  AND provider_status='verified' AND payment_status='provider_verified') THEN RAISE EXCEPTION 'Delayed charge not recorded as verified exception'; END IF;
 IF (SELECT stock FROM public.products WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>1 THEN
   RAISE EXCEPTION 'Promotion exception deducted stock'; END IF;
 IF public.store_settle_verified_payment_v2(b->>'reference',(b->>'id')::uuid,1400,'GHS','second@example.com',pg_catalog.now(),'test')<>'confirmed' THEN
   RAISE EXCEPTION 'Current promo reservation should be confirmable'; END IF;
 IF (SELECT stock FROM public.products WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>0 THEN
   RAISE EXCEPTION 'Current redemption did not deduct exactly once'; END IF;
END;
$delayed$;
RESET ROLE;
UPDATE public.products SET stock=0 WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
DO $assert$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.store_stock_alerts WHERE event_type='out' AND resolved_at IS NULL) THEN
   RAISE EXCEPTION 'Sold-out threshold alert missing'; END IF;
END; $assert$;
SET ROLE service_role;
SET test.role='service_role';
SELECT public.store_note_checkout_stock_issue('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
SELECT public.store_note_checkout_stock_issue('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
RESET ROLE;
DO $assert$ BEGIN
 IF (SELECT pg_catalog.count(*) FROM public.store_stock_alerts WHERE event_type='checkout_blocked')<>1 THEN
  RAISE EXCEPTION 'Hourly blocked checkout alert was not deduplicated'; END IF;
END; $assert$;
UPDATE public.products SET stock=5 WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
DO $assert$ BEGIN
 IF EXISTS(SELECT 1 FROM public.store_stock_alerts WHERE event_type IN ('out','low') AND resolved_at IS NULL) THEN
   RAISE EXCEPTION 'Restock did not resolve old stock alerts'; END IF;
END; $assert$;
UPDATE public.store_product_options SET low_stock_threshold=6 WHERE product_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
DO $assert$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.store_stock_alerts WHERE event_type='low' AND resolved_at IS NULL AND threshold=6)
 THEN RAISE EXCEPTION 'Raising product alert threshold should notify staff of current low stock';END IF;
END; $assert$;
UPDATE public.store_product_options SET low_stock_threshold=1 WHERE product_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
DO $assert$ BEGIN
 IF EXISTS(SELECT 1 FROM public.store_stock_alerts WHERE event_type='low' AND resolved_at IS NULL)
 THEN RAISE EXCEPTION 'Lowering product threshold should resolve stale low stock event';END IF;
END; $assert$;
SELECT 'PASS: paginated catalog, charts, private controls, best offer and cap, quote rollback, verified discounted settlement, dashboard stock alerts and threshold edits' AS result;
