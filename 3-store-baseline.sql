-- THE TIE GUY — separate public store + Paystack guest checkout.
-- Review and run ONLY in the latest Supabase project's SQL Editor, as admin.
-- Do NOT run original supabase/schema.sql over your existing database.
-- Prerequisite: public.settings EXISTS (if you dropped it, review/run
-- 20260929_recreate_deleted_settings_uuid.sql first) and staff_users/is_staff
-- are configured. This migration is intentionally not applied automatically.
-- It creates NEW store_* tables and RPCs; does not rewrite existing orders,
-- customers or products. Existing product IDs may be bigint, text or UUID.
-- Guest checkout is server-only; anon only gets a safe catalog RPC.
-- Price/stock are re-read from products in a single database transaction.
-- Paystack verification is performed by SERVER code, not Athena or a browser.
-- A service-role-only, atomic SQL RPC auto-confirms matching paid orders and
-- decrements stock once. Staff handle only exceptional/late/mismatched charges
-- and continue to control fulfillment and refunds. No AI can confirm payment.

BEGIN;
SET LOCAL lock_timeout = '10s';

DO $guard$
BEGIN
  IF pg_catalog.to_regclass('public.settings') IS NULL
     OR pg_catalog.to_regclass('public.products') IS NULL
     OR pg_catalog.to_regclass('public.staff_users') IS NULL
     OR pg_catalog.to_regprocedure('public.is_staff(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Expected existing settings/products/staff_users/is_staff(uuid). Inspect this project; no changes made.';
  END IF;
  IF (SELECT count(*) FROM public.settings) <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one existing settings row. Check the database first; no changes made.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('settings','business_name'),('settings','availability'),('settings','unavailable_message'),
      ('products','id'),('products','name'),('products','category'),('products','price'),
      ('products','stock'),('products','sizes'),('products','description'),
      ('products','image_url'),('products','active')
    ) AS needed(table_name,column_name)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
      WHERE c.table_schema='public' AND c.table_name=needed.table_name AND c.column_name=needed.column_name)
  ) THEN
    RAISE EXCEPTION 'A storefront-required settings/products column is missing. Share a read-only schema report before proceeding.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname IN ('store_orders','store_order_items','store_delivery_zones','store_checkout_attempts','store_payment_audit')
  ) OR pg_catalog.to_regprocedure('public.thetieguy_store_catalog_v2()') IS NOT NULL
    OR pg_catalog.to_regprocedure('public.store_create_checkout_order(jsonb,jsonb,text,uuid,text,text)') IS NOT NULL
    OR pg_catalog.to_regprocedure('public.store_settle_verified_payment(text,uuid,integer,text,text,timestamptz,text)') IS NOT NULL
    OR pg_catalog.to_regprocedure('public.store_flag_payment_review(text,uuid)') IS NOT NULL
    OR pg_catalog.to_regprocedure('public.store_record_verified_payment(text,uuid,integer,text,text)') IS NOT NULL
    OR pg_catalog.to_regprocedure('public.store_confirm_payment(uuid)') IS NOT NULL
    OR pg_catalog.to_regprocedure('public.store_flag_refund_needed(uuid)') IS NOT NULL
    OR pg_catalog.to_regprocedure('public.store_set_order_status(uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Store objects already exist. Do not overwrite a deployed store; inspect current schema before rerunning.';
  END IF;
END;
$guard$;

CREATE TABLE public.store_delivery_zones (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  name text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(name)) BETWEEN 2 AND 80),
  fee_minor integer NOT NULL CHECK (fee_minor BETWEEN 0 AND 100000000), -- pesewas
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
CREATE UNIQUE INDEX store_delivery_zones_name_key ON public.store_delivery_zones (pg_catalog.lower(name));
-- No delivery zones are seeded. Unknown fees are quoted/paid separately.

CREATE TABLE public.store_orders (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  order_number text NOT NULL UNIQUE,
  reference text NOT NULL UNIQUE,
  checkout_token uuid NOT NULL UNIQUE DEFAULT pg_catalog.gen_random_uuid(),
  customer_name text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(customer_name)) BETWEEN 2 AND 100),
  customer_email text NOT NULL,
  customer_phone text NOT NULL,
  fulfillment_method text NOT NULL CHECK (fulfillment_method IN ('pickup','delivery')),
  delivery_zone_id uuid REFERENCES public.store_delivery_zones(id) ON DELETE SET NULL,
  delivery_zone_name text,
  delivery_address text NOT NULL DEFAULT '',
  notes text NOT NULL DEFAULT '',
  subtotal_minor integer NOT NULL CHECK (subtotal_minor > 0),
  delivery_fee_minor integer CHECK (delivery_fee_minor >= 0), -- NULL = quote separately
  amount_minor integer NOT NULL CHECK (amount_minor > 0),
  currency text NOT NULL DEFAULT 'GHS' CHECK (currency='GHS'),
  provider_status text NOT NULL DEFAULT 'pending' CHECK (provider_status IN ('pending','verified')),
  payment_status text NOT NULL DEFAULT 'pending' CHECK (payment_status IN ('pending','provider_verified','payment_review','confirmed','refund_needed','refunded')),
  order_status text NOT NULL DEFAULT 'new' CHECK (order_status IN ('new','processing','ready','out_for_delivery','completed','cancelled')),
  reservation_expires_at timestamptz NOT NULL DEFAULT (pg_catalog.now()+interval '30 minutes'),
  provider_paid_at timestamptz, -- actual paid_at returned by Paystack, never a webhook arrival time
  provider_domain text CHECK (provider_domain IN ('test','live')),
  confirmation_source text NOT NULL DEFAULT 'none' CHECK (confirmation_source IN ('none','paystack','staff')),
  review_reason text CHECK (review_reason IN ('late_payment','missing_paid_at','invalid_paid_at','product_unavailable','stock_unavailable','verification_mismatch','staff_flagged')),
  confirmed_at timestamptz,
  confirmed_by uuid,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CONSTRAINT store_orders_amount_check CHECK (amount_minor = subtotal_minor + COALESCE(delivery_fee_minor,0)),
  CONSTRAINT store_order_confirmation_check CHECK (
    (payment_status='confirmed' AND provider_status='verified' AND confirmation_source<>'none' AND confirmed_at IS NOT NULL
       AND order_status IN ('processing','ready','out_for_delivery','completed'))
    OR (payment_status<>'confirmed' AND confirmation_source='none' AND confirmed_at IS NULL AND confirmed_by IS NULL)
  ),
  CONSTRAINT store_order_confirmation_actor_check CHECK (
    (confirmation_source='staff' AND confirmed_by IS NOT NULL) OR (confirmation_source<>'staff' AND confirmed_by IS NULL)
  )
);
CREATE INDEX store_orders_recent_idx ON public.store_orders(created_at DESC);
CREATE INDEX store_orders_payment_idx ON public.store_orders(payment_status,created_at DESC);

CREATE TABLE public.store_order_items (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.store_orders(id) ON DELETE RESTRICT,
  product_id text NOT NULL, -- safe snapshot of UUID/bigint/text product ID
  product_name text NOT NULL,
  category text NOT NULL,
  image_url text NOT NULL DEFAULT '',
  size text NOT NULL,
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 10),
  unit_price_minor integer NOT NULL CHECK (unit_price_minor > 0),
  line_total_minor integer NOT NULL CHECK (line_total_minor = quantity * unit_price_minor)
);
CREATE INDEX store_order_items_order_idx ON public.store_order_items(order_id);
CREATE INDEX store_order_items_product_idx ON public.store_order_items(product_id);

-- A hashed network identifier; never store raw IPs here. An hourly cap is a
-- small anti-abuse layer, NOT a substitute for bot protection at high volume.
CREATE TABLE public.store_checkout_attempts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_hash text NOT NULL CHECK (client_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
CREATE INDEX store_checkout_attempts_recent_idx ON public.store_checkout_attempts(client_hash,created_at DESC);

-- Append-only payment decisions. Staff can read, not edit. Never store card
-- information, webhook bodies, customer PII, or secret keys here.
CREATE TABLE public.store_payment_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id uuid NOT NULL REFERENCES public.store_orders(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('auto_confirmed','staff_confirmed','payment_review','refund_review')),
  detail text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
CREATE INDEX store_payment_audit_order_idx ON public.store_payment_audit(order_id,created_at DESC);

-- Explicitly remove default-public privileges before adding limited grants.
ALTER TABLE public.store_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_delivery_zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_checkout_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_payment_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.store_orders, public.store_order_items, public.store_delivery_zones, public.store_checkout_attempts FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.store_payment_audit FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE public.store_checkout_attempts_id_seq FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.store_payment_audit_id_seq FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.store_orders, public.store_order_items, public.store_payment_audit TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.store_delivery_zones TO authenticated;
GRANT ALL ON TABLE public.store_orders, public.store_order_items, public.store_delivery_zones, public.store_checkout_attempts TO service_role;
GRANT SELECT ON TABLE public.store_payment_audit TO service_role;
GRANT ALL ON SEQUENCE public.store_checkout_attempts_id_seq TO service_role;
CREATE POLICY store_orders_staff_read ON public.store_orders FOR SELECT TO authenticated USING (public.is_staff((SELECT auth.uid())));
CREATE POLICY store_order_items_staff_read ON public.store_order_items FOR SELECT TO authenticated USING (public.is_staff((SELECT auth.uid())));
CREATE POLICY store_payment_audit_staff_read ON public.store_payment_audit FOR SELECT TO authenticated USING (public.is_staff((SELECT auth.uid())));
CREATE POLICY store_zones_staff_all ON public.store_delivery_zones FOR ALL TO authenticated
 USING (public.is_staff((SELECT auth.uid()))) WITH CHECK (public.is_staff((SELECT auth.uid())));

-- Public read-only catalog: ONLY active products and public business status.
-- Product IDs are text to avoid rounding bigint IDs in JavaScript; prices are
-- whole pesewas. Never publish settings.payments or customer records here.
CREATE FUNCTION public.thetieguy_store_catalog_v2() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $catalog$
 SELECT pg_catalog.jsonb_build_object(
  'business',pg_catalog.jsonb_build_object(
    'name',s.business_name,
    'availability', CASE WHEN s.availability IN ('normal','available') THEN 'available' ELSE 'unavailable' END,
    'unavailable_message',s.unavailable_message
  ),
  'products',COALESCE((SELECT pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object('id',p.id::text,'name',p.name,'category',p.category,
        'description',p.description,'image_url',p.image_url,'sizes',p.sizes,
        'price_minor',pg_catalog.round(p.price*100)::bigint,
        'available',p.stock>0) ORDER BY (p.stock>0) DESC,p.name,p.id)
      FROM public.products p WHERE p.active=true), '[]'::jsonb),
  'delivery_zones',COALESCE((SELECT pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object('id',z.id::text,'name',z.name,'fee_minor',z.fee_minor) ORDER BY z.name)
      FROM public.store_delivery_zones z WHERE z.active=true), '[]'::jsonb)
 ) FROM public.settings s WHERE (SELECT pg_catalog.count(*) FROM public.settings)=1 LIMIT 1;
$catalog$;
REVOKE ALL ON FUNCTION public.thetieguy_store_catalog_v2() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.thetieguy_store_catalog_v2() TO anon, authenticated, service_role;

-- Atomic service-role-only checkout. Snapshots and totals are calculated by
-- PostgreSQL from existing products; browser names, prices and stock ignored.
-- Active 30-minute reservations are counted before another checkout can take
-- the last item. A late Paystack charge still needs staff review or a refund.
CREATE FUNCTION public.store_create_checkout_order(
  p_customer jsonb, p_items jsonb, p_method text, p_zone_id uuid,
  p_address text, p_client_hash text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $checkout$
DECLARE
  v_name text := pg_catalog.btrim(COALESCE(p_customer->>'name',''));
  v_email text := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_customer->>'email','')));
  v_phone text := pg_catalog.btrim(COALESCE(p_customer->>'phone',''));
  v_notes text := pg_catalog.btrim(COALESCE(p_customer->>'notes',''));
  v_address text := pg_catalog.btrim(COALESCE(p_address,''));
  v_product_id text;
  v_product record;
  v_item jsonb;
  v_size text;
  v_qty integer;
  v_requested integer;
  v_reserved integer;
  v_unit_minor bigint;
  v_subtotal bigint := 0;
  v_fee integer;
  v_zone_name text;
  v_id uuid := pg_catalog.gen_random_uuid();
  v_reference text := 'TG' || pg_catalog.replace(v_id::text,'-','');
  v_number text := 'TG-' || pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(v_id::text,'-',''),1,10));
  v_token uuid := pg_catalog.gen_random_uuid();
  v_open boolean;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'Server access only'; END IF;
  IF p_client_hash IS NULL OR p_client_hash !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid request'; END IF;
  IF pg_catalog.length(v_name) NOT BETWEEN 2 AND 100
    OR pg_catalog.length(v_email) NOT BETWEEN 5 AND 254
    OR v_email !~* '^[a-z0-9._%+-]+@[a-z0-9.-]+[.][a-z]{2,}$'
    OR pg_catalog.length(v_phone) NOT BETWEEN 9 AND 24
    OR v_phone !~ '^[+0-9 ()-]+$' OR pg_catalog.length(v_notes)>500 THEN
    RAISE EXCEPTION 'Check your name, email and phone details';
  END IF;
  IF p_method NOT IN ('pickup','delivery') OR p_method IS NULL THEN RAISE EXCEPTION 'Choose pickup or delivery'; END IF;
  IF p_method='delivery' AND pg_catalog.length(v_address) NOT BETWEEN 8 AND 350 THEN
    RAISE EXCEPTION 'Add a delivery address';
  END IF;
  IF p_method='pickup' AND (p_zone_id IS NOT NULL OR v_address <> '') THEN RAISE EXCEPTION 'Pickup has no delivery zone/address'; END IF;
  IF pg_catalog.jsonb_typeof(p_items) IS DISTINCT FROM 'array'
    OR pg_catalog.jsonb_array_length(p_items) NOT BETWEEN 1 AND 8 THEN
    RAISE EXCEPTION 'Choose between one and eight different items';
  END IF;
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_items) LOOP
    IF pg_catalog.jsonb_typeof(v_item) IS DISTINCT FROM 'object'
      OR pg_catalog.length(COALESCE(v_item->>'id','')) NOT BETWEEN 1 AND 128
      OR pg_catalog.length(COALESCE(v_item->>'size','')) NOT BETWEEN 1 AND 80
      OR COALESCE(v_item->>'quantity','') !~ '^[1-9][0-9]?$'
      OR (v_item->>'quantity')::integer > 10 THEN
      RAISE EXCEPTION 'Invalid product, size or quantity';
    END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM (SELECT entries.item->>'id', entries.item->>'size'
       FROM pg_catalog.jsonb_array_elements(p_items) AS entries(item)
       GROUP BY entries.item->>'id', entries.item->>'size' HAVING pg_catalog.count(*)>1) duplicates) THEN
    RAISE EXCEPTION 'Duplicate product and size in bag';
  END IF;
  SELECT (pg_catalog.count(*)=1 AND pg_catalog.bool_and(availability IN ('normal','available')))
     INTO v_open FROM public.settings;
  IF NOT COALESCE(v_open,false) THEN RAISE EXCEPTION 'Online orders are paused'; END IF;

  IF p_method='pickup' THEN v_fee:=0;
  ELSIF p_zone_id IS NOT NULL THEN
    SELECT fee_minor,name INTO v_fee,v_zone_name FROM public.store_delivery_zones
      WHERE id=p_zone_id AND active=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'The selected delivery zone is no longer available'; END IF;
  END IF;

  -- Serialize attempts for this hashed client over 1 hour. Retry after an
  -- abandoned Paystack session does not make a second successful charge.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_client_hash, 94));
  IF (SELECT pg_catalog.count(*) FROM public.store_checkout_attempts
      WHERE client_hash=p_client_hash AND created_at>pg_catalog.now()-interval '1 hour') >= 5 THEN
    RAISE EXCEPTION 'Too many checkout attempts. Please wait before trying again.';
  END IF;

  -- Lock products in sorted order so concurrent checkout/confirmation share
  -- the same inventory critical section, even for multi-item orders.
  FOR v_product_id IN SELECT DISTINCT entries.item->>'id'
       FROM pg_catalog.jsonb_array_elements(p_items) AS entries(item) ORDER BY 1 LOOP
    SELECT p.* INTO v_product FROM public.products p
       WHERE p.id::text=v_product_id AND p.active=true FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'An item is no longer available. Refresh your bag.'; END IF;
    SELECT pg_catalog.sum((entries.item->>'quantity')::integer) INTO v_requested
       FROM pg_catalog.jsonb_array_elements(p_items) AS entries(item) WHERE entries.item->>'id'=v_product_id;
    SELECT COALESCE(pg_catalog.sum(i.quantity),0) INTO v_reserved
      FROM public.store_order_items i JOIN public.store_orders o ON o.id=i.order_id
      WHERE i.product_id=v_product_id AND o.reservation_expires_at>pg_catalog.now()
        AND o.payment_status IN ('pending','provider_verified') AND o.order_status<>'cancelled';
    IF v_product.stock < v_requested + v_reserved THEN
      RAISE EXCEPTION 'Not enough stock left for %. Refresh your bag.', v_product.name;
    END IF;
    v_unit_minor:=pg_catalog.round(v_product.price*100)::bigint;
    IF v_unit_minor < 1 OR v_unit_minor > 100000000 THEN RAISE EXCEPTION 'Product price requires review'; END IF;
    FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_items) WHERE value->>'id'=v_product_id LOOP
      v_size:=v_item->>'size';v_qty:=(v_item->>'quantity')::integer;
      IF NOT COALESCE(v_size=ANY(v_product.sizes),false) THEN
        RAISE EXCEPTION 'A size is no longer available for %',v_product.name;
      END IF;
      v_subtotal:=v_subtotal+v_unit_minor*v_qty;
    END LOOP;
  END LOOP;
  IF v_subtotal+(COALESCE(v_fee,0)) NOT BETWEEN 1 AND 2000000000 THEN
     RAISE EXCEPTION 'Cart total exceeds checkout limits';
  END IF;
  INSERT INTO public.store_checkout_attempts(client_hash) VALUES(p_client_hash);
  INSERT INTO public.store_orders(id,order_number,reference,checkout_token,customer_name,
      customer_email,customer_phone,fulfillment_method,delivery_zone_id,
      delivery_zone_name,delivery_address,notes,subtotal_minor,delivery_fee_minor,amount_minor)
    VALUES(v_id,v_number,v_reference,v_token,v_name,v_email,v_phone,p_method,
      CASE WHEN p_method='delivery' THEN p_zone_id ELSE NULL END,v_zone_name,
      CASE WHEN p_method='delivery' THEN v_address ELSE '' END,v_notes,
      v_subtotal::integer,v_fee,(v_subtotal+COALESCE(v_fee,0))::integer);
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_items) LOOP
    SELECT p.* INTO v_product FROM public.products p WHERE p.id::text=v_item->>'id';
    v_unit_minor:=pg_catalog.round(v_product.price*100)::bigint;
    v_qty:=(v_item->>'quantity')::integer;
    INSERT INTO public.store_order_items(order_id,product_id,product_name,category,
        image_url,size,quantity,unit_price_minor,line_total_minor)
      VALUES(v_id,v_product.id::text,v_product.name,v_product.category,
        v_product.image_url,v_item->>'size',v_qty,v_unit_minor::integer,(v_unit_minor*v_qty)::integer);
  END LOOP;
  RETURN pg_catalog.jsonb_build_object('id',v_id,'reference',v_reference,'order_number',v_number,
    'amount_minor',(v_subtotal+COALESCE(v_fee,0))::integer,'token',v_token);
END;
$checkout$;
REVOKE ALL ON FUNCTION public.store_create_checkout_order(jsonb,jsonb,text,uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.store_create_checkout_order(jsonb,jsonb,text,uuid,text,text) TO service_role;

-- Called ONLY after this merchant's server fetched the transaction directly
-- from Paystack (GET verify), checked status=success, exact reference, amount,
-- GHS, customer email, order ID metadata and test/live mode. Never accept a
-- browser redirect or webhook's own data as proof. This SECURITY DEFINER RPC
-- atomically changes the order and stock; simultaneous webhook/return/cron
-- retries cannot decrement stock twice. Only staff handle exceptional charges.
CREATE FUNCTION public.store_settle_verified_payment(
 p_reference text,p_order_id uuid,p_amount_minor integer,p_currency text,p_email text,
 p_paid_at timestamptz,p_domain text
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $settle$
DECLARE
  v_order public.store_orders%ROWTYPE;
  v_row record;
  v_stock integer;
  v_active boolean;
  v_reserved integer;
  v_reason text;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'Server access only'; END IF;
  IF p_domain NOT IN ('test','live') OR p_domain IS NULL THEN RAISE EXCEPTION 'Invalid Paystack mode'; END IF;
  SELECT * INTO v_order FROM public.store_orders WHERE reference=p_reference AND id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown store payment reference'; END IF;
  IF v_order.amount_minor<>p_amount_minor OR v_order.currency<>p_currency OR p_currency<>'GHS'
     OR v_order.customer_email IS DISTINCT FROM pg_catalog.lower(p_email) THEN
    RAISE EXCEPTION 'Verified payment does not match the order';
  END IF;
  IF v_order.provider_domain IS NOT NULL AND v_order.provider_domain<>p_domain THEN
    RAISE EXCEPTION 'Paystack test/live mode changed for this order';
  END IF;
  IF v_order.payment_status IN ('confirmed','refund_needed','refunded','payment_review') THEN
    RETURN v_order.payment_status; -- retries never overwrite decisions
  END IF;
  IF v_order.payment_status='provider_verified' AND v_order.review_reason IS NOT NULL THEN
    RETURN 'provider_verified'; -- staff exception already recorded
  END IF;

  IF p_paid_at IS NULL THEN v_reason:='missing_paid_at';
  ELSIF p_paid_at < v_order.created_at-interval '5 minutes' OR p_paid_at > pg_catalog.now()+interval '5 minutes' THEN
    v_reason:='invalid_paid_at';
  ELSIF p_paid_at > v_order.reservation_expires_at THEN v_reason:='late_payment';
  END IF;
  IF v_reason IS NOT NULL THEN
    UPDATE public.store_orders SET provider_status='verified',provider_domain=p_domain,
      provider_paid_at=p_paid_at,payment_status='provider_verified',review_reason=v_reason,
      updated_at=pg_catalog.now() WHERE id=v_order.id;
    INSERT INTO public.store_payment_audit(order_id,event_type,detail)
      VALUES(v_order.id,'payment_review',v_reason);
    RETURN 'provider_verified'; -- human decides late/missing timestamp cases
  END IF;

  -- FIRST lock and validate EVERY item before changing ANY product stock.
  -- Both checkout and settlement lock products in sorted text-ID order.
  IF NOT EXISTS(SELECT 1 FROM public.store_order_items WHERE order_id=v_order.id) THEN
    v_reason:='product_unavailable';
  END IF;
  FOR v_row IN SELECT i.product_id,pg_catalog.sum(i.quantity)::integer AS qty
    FROM public.store_order_items i WHERE i.order_id=v_order.id
    GROUP BY i.product_id ORDER BY i.product_id LOOP
    SELECT p.stock,p.active INTO v_stock,v_active FROM public.products p
      WHERE p.id::text=v_row.product_id FOR UPDATE;
    IF NOT FOUND OR NOT COALESCE(v_active,false) THEN v_reason:='product_unavailable';EXIT; END IF;
    SELECT COALESCE(pg_catalog.sum(i.quantity),0) INTO v_reserved
      FROM public.store_order_items i JOIN public.store_orders o ON o.id=i.order_id
      WHERE i.product_id=v_row.product_id AND o.id<>v_order.id
        AND o.reservation_expires_at>pg_catalog.now()
        AND o.payment_status IN ('pending','provider_verified') AND o.order_status<>'cancelled';
    IF v_stock < v_row.qty+v_reserved THEN v_reason:='stock_unavailable';EXIT; END IF;
  END LOOP;
  -- A charged but unfulfillable order is NOT a sale. No stock changed; staff
  -- must resolve/issue a Paystack refund manually. No automatic money movement.
  IF v_reason IS NOT NULL THEN
    UPDATE public.store_orders SET provider_status='verified',provider_domain=p_domain,
      provider_paid_at=p_paid_at,payment_status='refund_needed',order_status='cancelled',
      review_reason=v_reason,updated_at=pg_catalog.now() WHERE id=v_order.id;
    INSERT INTO public.store_payment_audit(order_id,event_type,detail)
      VALUES(v_order.id,'refund_review',v_reason);
    RETURN 'refund_needed';
  END IF;
  -- At this point all product locks are held. A surprising UPDATE failure
  -- aborts the *entire* transaction rather than partially changing stock.
  FOR v_row IN SELECT i.product_id,pg_catalog.sum(i.quantity)::integer AS qty
    FROM public.store_order_items i WHERE i.order_id=v_order.id
    GROUP BY i.product_id ORDER BY i.product_id LOOP
    UPDATE public.products SET stock=stock-v_row.qty
      WHERE id::text=v_row.product_id AND stock>=v_row.qty;
    IF NOT FOUND THEN RAISE EXCEPTION 'Product stock changed during Paystack settlement'; END IF;
  END LOOP;
  UPDATE public.store_orders SET provider_status='verified',provider_domain=p_domain,
    provider_paid_at=p_paid_at,payment_status='confirmed',order_status='processing',
    confirmation_source='paystack',confirmed_at=pg_catalog.now(),confirmed_by=NULL,
    review_reason=NULL,updated_at=pg_catalog.now() WHERE id=v_order.id;
  INSERT INTO public.store_payment_audit(order_id,event_type,detail)
    VALUES(v_order.id,'auto_confirmed',p_domain);
  RETURN 'confirmed';
END;
$settle$;
REVOKE ALL ON FUNCTION public.store_settle_verified_payment(text,uuid,integer,text,text,timestamptz,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.store_settle_verified_payment(text,uuid,integer,text,text,timestamptz,text)
  TO service_role;

-- A successful Paystack transaction that fails the server's reference,
-- amount, email, currency, metadata or mode comparison must NOT auto-confirm.
-- Flag for manual review without claiming the order was paid in full.
CREATE FUNCTION public.store_flag_payment_review(p_reference text,p_order_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $mismatch$
DECLARE v_order public.store_orders%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'Server access only'; END IF;
  SELECT * INTO v_order FROM public.store_orders WHERE reference=p_reference AND id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown store payment reference'; END IF;
  IF v_order.payment_status IN ('confirmed','refund_needed','refunded','payment_review') THEN
    RETURN v_order.payment_status;
  END IF;
  UPDATE public.store_orders SET payment_status='payment_review',review_reason='verification_mismatch',
    updated_at=pg_catalog.now() WHERE id=v_order.id;
  INSERT INTO public.store_payment_audit(order_id,event_type,detail)
    VALUES(v_order.id,'payment_review','verification_mismatch');
  RETURN 'payment_review';
END;
$mismatch$;
REVOKE ALL ON FUNCTION public.store_flag_payment_review(text,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.store_flag_payment_review(text,uuid) TO service_role;

-- Exceptional paid orders (e.g. late payment) may need a HUMAN override.
-- Staff must check the reference and exact amount in Paystack before clicking.
-- Normal matching payments use store_settle_verified_payment and skip this RPC.
CREATE FUNCTION public.store_confirm_payment(p_order_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $confirm$
DECLARE
  v_order public.store_orders%ROWTYPE;
  v_row record;
  v_product record;
  v_reserved integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'authenticated' OR NOT public.is_staff(auth.uid()) THEN
    RAISE EXCEPTION 'Authorized staff only'; END IF;
  SELECT * INTO v_order FROM public.store_orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Store order not found'; END IF;
  IF v_order.payment_status='confirmed' THEN RETURN 'confirmed'; END IF;
  IF v_order.provider_status<>'verified' OR v_order.payment_status<>'provider_verified' THEN
    RAISE EXCEPTION 'First verify this payment in Paystack; the transaction is not ready for human confirmation';
  END IF;
  FOR v_row IN SELECT product_id,pg_catalog.sum(quantity)::integer AS qty
    FROM public.store_order_items WHERE order_id=p_order_id GROUP BY product_id ORDER BY product_id LOOP
    SELECT p.* INTO v_product FROM public.products p WHERE p.id::text=v_row.product_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Product removed after checkout; arrange a refund or manual resolution'; END IF;
    SELECT COALESCE(pg_catalog.sum(i.quantity),0) INTO v_reserved
      FROM public.store_order_items i JOIN public.store_orders o ON o.id=i.order_id
      WHERE i.product_id=v_row.product_id AND o.id<>p_order_id
        AND o.reservation_expires_at>pg_catalog.now()
        AND o.payment_status IN ('pending','provider_verified') AND o.order_status<>'cancelled';
    IF v_product.stock < v_row.qty+v_reserved THEN
      RAISE EXCEPTION 'Insufficient stock for %. Do not fulfil; handle refund or restock first.',v_product.name;
    END IF;
    UPDATE public.products SET stock=stock-v_row.qty WHERE id::text=v_row.product_id AND stock>=v_row.qty;
    IF NOT FOUND THEN RAISE EXCEPTION 'Product stock changed; try again or arrange a refund'; END IF;
  END LOOP;
  UPDATE public.store_orders SET payment_status='confirmed',order_status='processing',
    confirmation_source='staff',review_reason=NULL,
    confirmed_at=pg_catalog.now(),confirmed_by=auth.uid(),updated_at=pg_catalog.now()
    WHERE id=p_order_id;
  INSERT INTO public.store_payment_audit(order_id,event_type,detail)
    VALUES(p_order_id,'staff_confirmed','human_verified_exception');
  RETURN 'confirmed';
END;
$confirm$;
REVOKE ALL ON FUNCTION public.store_confirm_payment(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.store_confirm_payment(uuid) TO authenticated;

-- A human can flag a verified but unfulfillable charge for refund review. This
-- does NOT process a refund; refunds must be performed separately in Paystack.
-- Never flag already-confirmed orders here: stock/inventory must be reconciled.
CREATE FUNCTION public.store_flag_refund_needed(p_order_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $refund$
DECLARE v_order public.store_orders%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'authenticated' OR NOT public.is_staff(auth.uid()) THEN
    RAISE EXCEPTION 'Authorized staff only'; END IF;
  SELECT * INTO v_order FROM public.store_orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Store order not found'; END IF;
  IF v_order.payment_status='refund_needed' THEN RETURN 'refund_needed'; END IF;
  IF v_order.provider_status<>'verified' OR v_order.payment_status<>'provider_verified' THEN
    RAISE EXCEPTION 'Only an unconfirmed Paystack-verified charge may be flagged for refund review';
  END IF;
  UPDATE public.store_orders SET payment_status='refund_needed',order_status='cancelled',
    review_reason='staff_flagged',updated_at=pg_catalog.now() WHERE id=p_order_id;
  INSERT INTO public.store_payment_audit(order_id,event_type,detail)
    VALUES(p_order_id,'refund_review','staff_flagged');
  RETURN 'refund_needed';
END;
$refund$;
REVOKE ALL ON FUNCTION public.store_flag_refund_needed(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.store_flag_refund_needed(uuid) TO authenticated;

CREATE FUNCTION public.store_set_order_status(p_order_id uuid,p_status text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $status$
DECLARE v_order public.store_orders%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'authenticated' OR NOT public.is_staff(auth.uid()) THEN
    RAISE EXCEPTION 'Authorized staff only'; END IF;
  SELECT * INTO v_order FROM public.store_orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Store order not found'; END IF;
  IF v_order.payment_status<>'confirmed' THEN RAISE EXCEPTION 'Payment must be confirmed before fulfillment'; END IF;
  IF (v_order.order_status='processing' AND p_status='ready')
    OR (v_order.order_status='ready' AND p_status='completed' AND v_order.fulfillment_method='pickup')
    OR (v_order.order_status='ready' AND p_status='out_for_delivery' AND v_order.fulfillment_method='delivery')
    OR (v_order.order_status='out_for_delivery' AND p_status='completed') THEN
    UPDATE public.store_orders SET order_status=p_status,updated_at=pg_catalog.now() WHERE id=p_order_id;
    RETURN p_status;
  END IF;
  RAISE EXCEPTION 'Invalid order status change; paid orders require separate refund handling before cancellation';
END;
$status$;
REVOKE ALL ON FUNCTION public.store_set_order_status(uuid,text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.store_set_order_status(uuid,text) TO authenticated;

-- Staff sees new online orders on another device without waiting for a page
-- reload. The dashboard also refreshes when focused and every 20 seconds.
DO $publication$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='store_orders') THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.store_orders;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='store_delivery_zones') THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.store_delivery_zones;
    END IF;
  END IF;
END;
$publication$;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
NOTIFY pgrst, 'reload schema';
SELECT pg_catalog.has_table_privilege('anon','public.store_orders','SELECT') AS anon_can_read_orders,
       pg_catalog.has_function_privilege('anon','public.thetieguy_store_catalog_v2()','EXECUTE') AS anon_can_read_catalog,
       (SELECT pg_catalog.count(*) FROM public.store_delivery_zones) AS published_zone_rates;
COMMIT;

-- SETUP: Add real delivery zones to store_delivery_zones via signed-in
-- dashboard/Supabase Table Editor. No made-up zone names or fees are inserted.
-- Recommended: test with sk_test_ and Paystack test payments before live.
-- Set PAYSTACK_SECRET_KEY + SUPABASE_SERVICE_ROLE_KEY ONLY in the STORE's Vercel
-- server-side environment. Configure webhook: https://YOUR-STORE/api/paystack-webhook.
-- Verify human confirmation against your Paystack merchant dashboard.
