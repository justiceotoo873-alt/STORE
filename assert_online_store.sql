-- DISPOSABLE LOCAL PostgreSQL ASSERTIONS. Never run this fixture on Supabase.
-- Match Supabase's service_role RLS-bypass behavior in the disposable cluster.
ALTER ROLE service_role BYPASSRLS;
INSERT INTO public.products(id,name,category,price,stock,sizes,description,image_url,active)
 VALUES('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Test paisley tie','Neckties',75.50,2,ARRAY['One size'],'Fixture','',true);
UPDATE public.settings SET availability='normal';
INSERT INTO auth.users(id,email) VALUES('11111111-1111-4111-8111-111111111111','owner@example.com');
INSERT INTO public.staff_users(user_id,role) VALUES('11111111-1111-4111-8111-111111111111','owner');
INSERT INTO public.store_delivery_zones(name,fee_minor) VALUES('Test Zone',1400);
DO $assert$
DECLARE v_data jsonb;
BEGIN
 v_data:=public.thetieguy_store_catalog_v2();
 IF (v_data #>> '{products,0,id}') <> 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    OR (v_data #>> '{products,0,price_minor}')::integer <> 7550
    OR (v_data #>> '{delivery_zones,0,fee_minor}')::integer <> 1400
    OR (v_data #>> '{business,availability}') <> 'available' THEN
  RAISE EXCEPTION 'Catalog returned unexpected public data: %', v_data;
 END IF;
END;
$assert$;
SET ROLE anon;
SELECT public.thetieguy_store_catalog_v2() #>> '{business,name}' AS public_brand;
RESET ROLE;
SET ROLE service_role;
SET test.role='service_role';
DO $assert$
DECLARE v_data jsonb; v_paid_at timestamptz:=pg_catalog.now();
BEGIN
 v_data:=public.store_create_checkout_order(
   '{"name":"Local Test","email":"Local@Example.com","phone":"+233200000000"}'::jsonb,
   '[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","size":"One size","quantity":1}]'::jsonb,
   'delivery',(SELECT id FROM public.store_delivery_zones LIMIT 1),'Accra street, local test','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
 IF (v_data->>'amount_minor')::integer<>8950 OR (v_data->>'token') IS NULL THEN
  RAISE EXCEPTION 'Wrong database-authoritative checkout amount or token: %', v_data;
 END IF;
 IF (SELECT stock FROM public.products WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>2 THEN
  RAISE EXCEPTION 'Stock decremented before Paystack verification';
 END IF;
 IF (SELECT customer_email FROM public.store_orders WHERE id=(v_data->>'id')::uuid)<>'local@example.com' THEN
  RAISE EXCEPTION 'Customer email not normalized';
 END IF;
 IF public.store_settle_verified_payment(v_data->>'reference',(v_data->>'id')::uuid,8950,'GHS',
    'local@example.com',v_paid_at,'test')<>'confirmed' THEN
  RAISE EXCEPTION 'Valid Paystack transaction was not automatically confirmed';
 END IF;
 IF public.store_settle_verified_payment(v_data->>'reference',(v_data->>'id')::uuid,8950,'GHS',
    'local@example.com',v_paid_at,'test')<>'confirmed' THEN
  RAISE EXCEPTION 'Retry of Paystack webhook/callback was not idempotent';
 END IF;
 IF (SELECT stock FROM public.products WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>1 THEN
  RAISE EXCEPTION 'Auto confirmation did not decrement inventory exactly once';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.store_orders WHERE id=(v_data->>'id')::uuid
    AND payment_status='confirmed' AND order_status='processing' AND provider_status='verified'
    AND confirmation_source='paystack' AND confirmed_by IS NULL AND confirmed_at IS NOT NULL
    AND provider_paid_at=v_paid_at AND provider_domain='test') THEN
  RAISE EXCEPTION 'Auto confirmation provenance/payment timestamps are incorrect';
 END IF;
 IF (SELECT pg_catalog.count(*) FROM public.store_payment_audit WHERE order_id=(v_data->>'id')::uuid)<>1 THEN
  RAISE EXCEPTION 'Duplicate or missing auto-confirmation audit record';
 END IF;
END;
$assert$;
RESET ROLE;
SET ROLE authenticated;
SET test.role='authenticated';
SET test.uid='11111111-1111-4111-8111-111111111111';
DO $assert$
DECLARE v_id uuid;
BEGIN
 SELECT id INTO v_id FROM public.store_orders WHERE customer_email='local@example.com';
 IF public.store_set_order_status(v_id,'ready')<>'ready' THEN RAISE EXCEPTION 'Paid order cannot move to ready'; END IF;
 IF public.store_set_order_status(v_id,'out_for_delivery')<>'out_for_delivery' THEN RAISE EXCEPTION 'Delivery did not advance'; END IF;
 IF (SELECT pg_catalog.count(*) FROM public.store_payment_audit WHERE order_id=v_id AND event_type='auto_confirmed')<>1 THEN
  RAISE EXCEPTION 'Staff action rewrote payment audit'; END IF;
END;
$assert$;
RESET ROLE;
SELECT 'PASS: server-verified payment auto-confirmed exactly once; provider/staff distinct, stock/audit/delivery/catalog correct' AS result;
