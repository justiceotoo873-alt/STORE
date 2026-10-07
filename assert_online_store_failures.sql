-- Run AFTER assert_online_store.sql in the disposable local mock database.
-- These synthetic charges/customers are never added to live Supabase.
DO $assert$
BEGIN
 IF pg_catalog.has_table_privilege('anon','public.store_orders','SELECT')
    OR pg_catalog.has_table_privilege('anon','public.store_payment_audit','SELECT')
    OR pg_catalog.has_table_privilege('anon','public.store_checkout_attempts','SELECT')
    OR pg_catalog.has_table_privilege('authenticated','public.store_payment_audit','INSERT')
    OR pg_catalog.has_function_privilege('anon','public.store_create_checkout_order(jsonb,jsonb,text,uuid,text,text)','EXECUTE')
    OR pg_catalog.has_function_privilege('anon','public.store_settle_verified_payment(text,uuid,integer,text,text,timestamptz,text)','EXECUTE')
    OR pg_catalog.has_function_privilege('authenticated','public.store_settle_verified_payment(text,uuid,integer,text,text,timestamptz,text)','EXECUTE')
    OR pg_catalog.has_function_privilege('anon','public.store_flag_payment_review(text,uuid)','EXECUTE')
    OR pg_catalog.has_function_privilege('anon','public.store_flag_refund_needed(uuid)','EXECUTE') THEN
  RAISE EXCEPTION 'A privileged store table or function is exposed';
 END IF;
END;
$assert$;
-- A buyer cannot spoof a 1-pesewa price or reserve more than actual stock.
SET ROLE service_role;
SET test.role='service_role';
DO $assert$
DECLARE v_checkout jsonb;
BEGIN
 v_checkout:=public.store_create_checkout_order(
   '{"name":"Mismatch Test","email":"mismatch@example.com","phone":"+233200000000"}'::jsonb,
   '[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","size":"One size","quantity":1,"price_minor":1}]'::jsonb,
   'pickup',NULL,'','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
 IF (v_checkout->>'amount_minor')::integer<>7550 THEN RAISE EXCEPTION 'Client-controlled price got through'; END IF;
 BEGIN
  PERFORM public.store_create_checkout_order(
   '{"name":"Another Test","email":"other@example.com","phone":"+233200000001"}'::jsonb,
   '[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","size":"One size","quantity":1}]'::jsonb,
   'pickup',NULL,'','cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc');
  RAISE EXCEPTION 'Missed inventory reservation limit';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Not enough stock%' THEN RAISE; END IF;
 END;
 BEGIN
  PERFORM public.store_settle_verified_payment(v_checkout->>'reference',(v_checkout->>'id')::uuid,
   1,'GHS','mismatch@example.com',pg_catalog.now(),'test');
  RAISE EXCEPTION 'Underpaid transaction auto-confirmed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Verified payment does not match%' THEN RAISE; END IF;
 END;
 BEGIN
  PERFORM public.store_settle_verified_payment(v_checkout->>'reference',(v_checkout->>'id')::uuid,
   7550,'GHS','wrong@example.com',pg_catalog.now(),'test');
  RAISE EXCEPTION 'Wrong email auto-confirmed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Verified payment does not match%' THEN RAISE; END IF;
 END;
 IF (SELECT payment_status FROM public.store_orders WHERE id=(v_checkout->>'id')::uuid)<>'pending' THEN
  RAISE EXCEPTION 'Invalid charge incorrectly changed order status';
 END IF;
 IF public.store_flag_payment_review(v_checkout->>'reference',(v_checkout->>'id')::uuid)<>'payment_review'
   OR public.store_flag_payment_review(v_checkout->>'reference',(v_checkout->>'id')::uuid)<>'payment_review' THEN
  RAISE EXCEPTION 'Mismatched charge did not enter review once';
 END IF;
 IF (SELECT pg_catalog.count(*) FROM public.store_payment_audit WHERE order_id=(v_checkout->>'id')::uuid)<>1 THEN
  RAISE EXCEPTION 'Mismatch retry duplicated audit'; END IF;
 IF (SELECT stock FROM public.products WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>1 THEN
  RAISE EXCEPTION 'Mismatch deducted stock'; END IF;
END;
$assert$;
RESET ROLE;
-- The only remaining tie is available again because a mismatch is not a sale.
SET ROLE service_role;
SET test.role='service_role';
DO $assert$
DECLARE v_checkout jsonb;
BEGIN
 v_checkout:=public.store_create_checkout_order(
   '{"name":"Timestamp Test","email":"timestamp@example.com","phone":"+233200000000"}'::jsonb,
   '[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","size":"One size","quantity":1}]'::jsonb,
   'pickup',NULL,'','dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd');
 -- A failed direct verification must not let staff confirm an unverified order.
 IF v_checkout->>'amount_minor'<>'7550' THEN RAISE EXCEPTION 'Wrong second order amount'; END IF;
END;
$assert$;
RESET ROLE;
SET ROLE authenticated;
SET test.role='authenticated';
SET test.uid='11111111-1111-4111-8111-111111111111';
DO $assert$
DECLARE v_id uuid;
BEGIN
 SELECT id INTO v_id FROM public.store_orders WHERE customer_email='timestamp@example.com';
 BEGIN
  PERFORM public.store_confirm_payment(v_id);
  RAISE EXCEPTION 'Staff confirmed unverified Paystack transaction';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'First verify this payment%' THEN RAISE; END IF;
 END;
END;
$assert$;
RESET ROLE;
SET ROLE authenticated;
SET test.uid='22222222-2222-4222-8222-222222222222';
SET test.role='authenticated';
DO $assert$
BEGIN
 IF (SELECT pg_catalog.count(*) FROM public.store_orders)<>0 OR
    (SELECT pg_catalog.count(*) FROM public.store_payment_audit)<>0 THEN
  RAISE EXCEPTION 'Nonstaff can read private orders or audit';
 END IF;
 BEGIN
  PERFORM public.store_confirm_payment('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  RAISE EXCEPTION 'Nonstaff confirmed a store order';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Authorized staff only%' THEN RAISE; END IF;
 END;
END;
$assert$;
RESET ROLE;
SET ROLE service_role;
SET test.role='service_role';
DO $assert$
DECLARE v_id uuid;v_reference text;
BEGIN
 SELECT id,reference INTO v_id,v_reference FROM public.store_orders WHERE customer_email='timestamp@example.com';
 IF public.store_settle_verified_payment(v_reference,v_id,7550,'GHS','timestamp@example.com',
     pg_catalog.now()-interval '1 hour','test')<>'provider_verified' THEN
   RAISE EXCEPTION 'Invalid timestamp was not held for manual review'; END IF;
 IF public.store_settle_verified_payment(v_reference,v_id,7550,'GHS','timestamp@example.com',
     pg_catalog.now(),'test')<>'provider_verified' THEN
   RAISE EXCEPTION 'Retry bypassed the existing exception'; END IF;
 IF (SELECT review_reason FROM public.store_orders WHERE id=v_id)<>'invalid_paid_at'
   OR (SELECT stock FROM public.products WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>1 THEN
   RAISE EXCEPTION 'Timestamp exception incorrectly decremented stock'; END IF;
END;
$assert$;
RESET ROLE;
SET ROLE authenticated;
SET test.role='authenticated';
SET test.uid='11111111-1111-4111-8111-111111111111';
DO $assert$
DECLARE v_id uuid;
BEGIN
 SELECT id INTO v_id FROM public.store_orders WHERE customer_email='timestamp@example.com';
 IF public.store_confirm_payment(v_id)<>'confirmed'
   OR public.store_confirm_payment(v_id)<>'confirmed' THEN
  RAISE EXCEPTION 'Staff exception override was not idempotent'; END IF;
 IF (SELECT stock FROM public.products WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>0
    OR (SELECT confirmation_source FROM public.store_orders WHERE id=v_id)<>'staff'
    OR (SELECT confirmed_by FROM public.store_orders WHERE id=v_id) IS NULL THEN
  RAISE EXCEPTION 'Staff exception confirmation incorrect'; END IF;
 IF (SELECT pg_catalog.count(*) FROM public.store_payment_audit WHERE order_id=v_id AND event_type='staff_confirmed')<>1 THEN
  RAISE EXCEPTION 'Staff confirmation audit duplicated'; END IF;
END;
$assert$;
RESET ROLE;
-- A two-item order must not partially decrement product #1 when product #2
-- disappears before successful Paystack verification.
INSERT INTO public.products(id,name,category,price,stock,sizes,description,image_url,active) VALUES
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Test tie clip','Tie clips',25.00,1,ARRAY['One size'],'Fixture','',true),
 ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','Test pharmacy brooch','Brooches',39.00,1,ARRAY['One size'],'Fixture','',true),
 ('dddddddd-dddd-4ddd-8ddd-dddddddddddd','Test law brooch','Brooches',30.00,1,ARRAY['One size'],'Fixture','',true);
SET ROLE service_role;
SET test.role='service_role';
DO $assert$
DECLARE v_checkout jsonb;
BEGIN
 v_checkout:=public.store_create_checkout_order(
   '{"name":"Two Items","email":"two@example.com","phone":"+233200000000"}'::jsonb,
   '[{"id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","size":"One size","quantity":1},
     {"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","size":"One size","quantity":1}]'::jsonb,
   'pickup',NULL,'','eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee');
 IF (v_checkout->>'amount_minor')::integer<>6400 THEN RAISE EXCEPTION 'Wrong two-item price'; END IF;
END;
$assert$;
RESET ROLE;
UPDATE public.products SET stock=0 WHERE id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'; -- fixture: another sale
SET ROLE service_role;
SET test.role='service_role';
DO $assert$
DECLARE v_id uuid;v_reference text;
BEGIN
 SELECT id,reference INTO v_id,v_reference FROM public.store_orders WHERE customer_email='two@example.com';
 IF public.store_settle_verified_payment(v_reference,v_id,6400,'GHS','two@example.com',pg_catalog.now(),'test')<>'refund_needed'
    OR public.store_settle_verified_payment(v_reference,v_id,6400,'GHS','two@example.com',pg_catalog.now(),'test')<>'refund_needed' THEN
  RAISE EXCEPTION 'Unfulfillable charge did not enter refund exception once'; END IF;
 IF (SELECT stock FROM public.products WHERE id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')<>1
    OR (SELECT payment_status FROM public.store_orders WHERE id=v_id)<>'refund_needed'
    OR (SELECT order_status FROM public.store_orders WHERE id=v_id)<>'cancelled'
    OR (SELECT pg_catalog.count(*) FROM public.store_payment_audit WHERE order_id=v_id)<>1 THEN
  RAISE EXCEPTION 'Two-item failure partially deducted stock or duplicated audit'; END IF;
END;
$assert$;
RESET ROLE;
-- A charge PAID AFTER the hold ends must not auto-confirm even if stock remains.
SET ROLE service_role;
SET test.role='service_role';
DO $assert$
DECLARE v_checkout jsonb;
BEGIN
 v_checkout:=public.store_create_checkout_order(
   '{"name":"Late Test","email":"late@example.com","phone":"+233200000000"}'::jsonb,
   '[{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","size":"One size","quantity":1}]'::jsonb,
   'pickup',NULL,'','ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff');
 IF (v_checkout->>'amount_minor')::integer<>3000 THEN RAISE EXCEPTION 'Wrong late order amount'; END IF;
END;
$assert$;
RESET ROLE;
UPDATE public.store_orders SET reservation_expires_at=pg_catalog.now()-interval '1 minute'
 WHERE customer_email='late@example.com'; -- fixture only
SET ROLE service_role;
SET test.role='service_role';
DO $assert$
DECLARE v_id uuid;v_reference text;
BEGIN
 SELECT id,reference INTO v_id,v_reference FROM public.store_orders WHERE customer_email='late@example.com';
 IF public.store_settle_verified_payment(v_reference,v_id,3000,'GHS','late@example.com',pg_catalog.now(),'test')<>'provider_verified' THEN
  RAISE EXCEPTION 'Late charge was not held for review'; END IF;
 IF (SELECT review_reason FROM public.store_orders WHERE id=v_id)<>'late_payment'
    OR (SELECT stock FROM public.products WHERE id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')<>1 THEN
  RAISE EXCEPTION 'Late charge was auto-confirmed or stock changed'; END IF;
END;
$assert$;
RESET ROLE;
SET ROLE authenticated;
SET test.role='authenticated';
SET test.uid='11111111-1111-4111-8111-111111111111';
DO $assert$
DECLARE v_id uuid;
BEGIN
 SELECT id INTO v_id FROM public.store_orders WHERE customer_email='late@example.com';
 IF public.store_flag_refund_needed(v_id)<>'refund_needed'
   OR public.store_flag_refund_needed(v_id)<>'refund_needed' THEN
   RAISE EXCEPTION 'Manual refund flag was not idempotent'; END IF;
 IF (SELECT payment_status FROM public.store_orders WHERE id=v_id)<>'refund_needed'
   OR (SELECT order_status FROM public.store_orders WHERE id=v_id)<>'cancelled'
   OR (SELECT pg_catalog.count(*) FROM public.store_payment_audit WHERE order_id=v_id AND event_type='refund_review')<>1 THEN
   RAISE EXCEPTION 'Refund flag did not release hold or was not audited'; END IF;
 BEGIN
  PERFORM public.store_confirm_payment(v_id);
  RAISE EXCEPTION 'Flagged refund charge got staff-confirmed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'First verify this payment%' THEN RAISE; END IF;
 END;
END;
$assert$;
RESET ROLE;
UPDATE public.settings SET availability='closed'; -- legacy mock; new UUID settings may use 'not_taking'
SET ROLE service_role;
SET test.role='service_role';
DO $assert$
BEGIN
 BEGIN
  PERFORM public.store_create_checkout_order(
   '{"name":"Paused Test","email":"paused@example.com","phone":"+233200000000"}'::jsonb,
   '[{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","size":"One size","quantity":1}]'::jsonb,
   'pickup',NULL,'','abababababababababababababababababababababababababababababababab');
  RAISE EXCEPTION 'Checkout ignored business availability';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Online orders are paused%' THEN RAISE; END IF;
 END;
END;
$assert$;
RESET ROLE;
SELECT 'PASS: grants/RLS, forged price/amount, idempotence, late/mismatch/review, atomic multi-item stock, staff override, and paused sales' AS result;
