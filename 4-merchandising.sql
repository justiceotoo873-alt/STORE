-- @thetieguy / Athena — editable merchandising, safe promotions and stock alerts.
-- REVIEW FIRST. This is an ADDITIVE migration AFTER 20260930_online_store_paystack.sql.
-- Do NOT run either migration on live Supabase without the owner's approval.
-- No real delivery fees, coupons, measurements or invented inventory are seeded.
-- Existing guest-order payment verification and Paystack idempotency remain intact.
BEGIN;
SET LOCAL lock_timeout='10s';
DO $guard$
BEGIN
 IF pg_catalog.to_regclass('public.store_orders') IS NULL OR
    pg_catalog.to_regprocedure('public.store_create_checkout_order(jsonb,jsonb,text,uuid,text,text)') IS NULL OR
    pg_catalog.to_regprocedure('public.store_settle_verified_payment(text,uuid,integer,text,text,timestamptz,text)') IS NULL THEN
   RAISE EXCEPTION 'Apply/review 20260930_online_store_paystack.sql first; no changes made'; END IF;
 IF pg_catalog.to_regclass('public.storefront_options') IS NOT NULL OR
    pg_catalog.to_regclass('public.store_promotions') IS NOT NULL OR
    pg_catalog.to_regprocedure('public.store_create_checkout_order_v2(jsonb,jsonb,text,uuid,text,text,text,integer)') IS NOT NULL THEN
   RAISE EXCEPTION 'Merchandising already exists; inspect deployed schema instead of rerunning'; END IF;
END;
$guard$;

-- A SINGLE, staff-editable set of pre-approved design controls. The original
-- tie illustration/brand palette remain in the site's static assets. Stored
-- text is plain copy, never raw HTML/CSS or arbitrary JavaScript.
CREATE TABLE public.storefront_options (
 id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
 singleton_key boolean NOT NULL DEFAULT true UNIQUE CHECK(singleton_key),
 announcement_enabled boolean NOT NULL DEFAULT true,
 announcement_text text NOT NULL DEFAULT 'THE DETAIL MAKES THE DIFFERENCE' CHECK(pg_catalog.length(announcement_text)<=110),
 hero_eyebrow text NOT NULL DEFAULT 'THE TIE GUY · THE SIGNATURE EDIT' CHECK(pg_catalog.length(hero_eyebrow)<=95),
 hero_title text NOT NULL DEFAULT 'A little detail.' CHECK(pg_catalog.length(hero_title)<=90),
 hero_emphasis text NOT NULL DEFAULT 'A lasting' CHECK(pg_catalog.length(hero_emphasis)<=90),
 hero_final_line text NOT NULL DEFAULT 'impression.' CHECK(pg_catalog.length(hero_final_line)<=90),
 hero_description text NOT NULL DEFAULT 'Statement neckties, considered accessories, and the finishing touches that make every entrance your own.' CHECK(pg_catalog.length(hero_description)<=350),
 hero_visual text NOT NULL DEFAULT 'four-ties' CHECK(hero_visual IN ('four-ties','burgundy','bronze','gold','purple')),
 hero_cta text NOT NULL DEFAULT 'Explore the collection' CHECK(pg_catalog.length(hero_cta)<=42),
 promo_enabled boolean NOT NULL DEFAULT false,
 promo_eyebrow text NOT NULL DEFAULT '' CHECK(pg_catalog.length(promo_eyebrow)<=90),
 promo_title text NOT NULL DEFAULT '' CHECK(pg_catalog.length(promo_title)<=110),
 promo_description text NOT NULL DEFAULT '' CHECK(pg_catalog.length(promo_description)<=260),
 promo_button text NOT NULL DEFAULT 'Shop the edit' CHECK(pg_catalog.length(promo_button)<=42),
 promo_image text NOT NULL DEFAULT 'hero-tie-gold.jpg' CHECK(promo_image IN
   ('hero-tie-gold.jpg','hero-tie-burgundy.jpg','hero-tie-bronze.jpg','hero-tie-purple.jpg','tieclips-collection.jpg')),
 promo_target text NOT NULL DEFAULT 'All' CHECK(promo_target IN ('All','Ties','Clips','Brooches')),
 updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
INSERT INTO public.storefront_options DEFAULT VALUES;

-- Staff enters every measurement. A chart may be a category default; a
-- product can explicitly select any compatible chart in store_product_options.
-- Rows are arrays of plain strings matching the column order (validated in UI).
CREATE TABLE public.store_size_charts (
 id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
 category text NOT NULL CHECK(pg_catalog.length(pg_catalog.btrim(category)) BETWEEN 2 AND 80),
 title text NOT NULL CHECK(pg_catalog.length(pg_catalog.btrim(title)) BETWEEN 2 AND 100),
 units text NOT NULL DEFAULT 'cm' CHECK(units IN ('cm','in','other')),
 columns text[] NOT NULL CHECK(pg_catalog.array_length(columns,1) BETWEEN 2 AND 6),
 rows jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(pg_catalog.jsonb_typeof(rows)='array' AND pg_catalog.jsonb_array_length(rows)<=35),
 notes text NOT NULL DEFAULT '' CHECK(pg_catalog.length(notes)<=500),
 default_for_category boolean NOT NULL DEFAULT false,
 active boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
 updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
CREATE UNIQUE INDEX store_chart_one_default_per_category ON public.store_size_charts(pg_catalog.lower(category)) WHERE default_for_category=true;

-- The catalog itself has NO product-count limit. These optional attributes are
-- keyed by TEXT so existing UUID or bigint products work without coercion.
CREATE TABLE public.store_product_options (
 product_id text PRIMARY KEY CHECK(pg_catalog.length(product_id) BETWEEN 1 AND 128),
 low_stock_threshold integer NOT NULL DEFAULT 3 CHECK(low_stock_threshold BETWEEN 0 AND 100000),
 featured boolean NOT NULL DEFAULT false,
 size_chart_id uuid REFERENCES public.store_size_charts(id) ON DELETE SET NULL,
 updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

CREATE TABLE public.store_stock_alerts (
 id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
 product_id text NOT NULL,
 product_name text NOT NULL,
 event_type text NOT NULL CHECK(event_type IN ('low','out','checkout_blocked')),
 stock_at_event integer NOT NULL,
 threshold integer NOT NULL,
 created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
 resolved_at timestamptz
);
CREATE INDEX store_stock_alerts_recent_idx ON public.store_stock_alerts(created_at DESC);
CREATE INDEX store_stock_alerts_open_idx ON public.store_stock_alerts(product_id,event_type) WHERE resolved_at IS NULL;

-- One best offer per order (no silent stacking). Codes are case insensitive;
-- NULL codes denote automatic promotions. Amounts are whole pesewas.
CREATE TABLE public.store_promotions (
 id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
 name text NOT NULL CHECK(pg_catalog.length(pg_catalog.btrim(name)) BETWEEN 2 AND 100),
 code text CHECK(code IS NULL OR code ~ '^[A-Z0-9-]{4,24}$'),
 kind text NOT NULL CHECK(kind IN ('percentage','fixed')),
 percent_off numeric(5,2) NOT NULL DEFAULT 0 CHECK(percent_off BETWEEN 0 AND 100),
 amount_minor integer NOT NULL DEFAULT 0 CHECK(amount_minor BETWEEN 0 AND 100000000),
 free_delivery boolean NOT NULL DEFAULT false,
 scope text NOT NULL DEFAULT 'all' CHECK(scope IN ('all','categories','products')),
 categories text[] NOT NULL DEFAULT ARRAY[]::text[],
 product_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
 min_subtotal_minor integer NOT NULL DEFAULT 0 CHECK(min_subtotal_minor BETWEEN 0 AND 2000000000),
 max_redemptions integer CHECK(max_redemptions BETWEEN 1 AND 100000000),
 per_email_limit integer CHECK(per_email_limit BETWEEN 1 AND 100000),
 starts_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
 ends_at timestamptz CHECK(ends_at IS NULL OR ends_at>starts_at),
 active boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
 updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
 CONSTRAINT store_promo_value CHECK(
  (kind='percentage' AND amount_minor=0 AND (percent_off>0 OR free_delivery)) OR
  (kind='fixed' AND percent_off=0 AND (amount_minor>0 OR free_delivery))
 )
);
CREATE UNIQUE INDEX store_promotions_code_key ON public.store_promotions(code) WHERE code IS NOT NULL;
CREATE INDEX store_promotions_active_idx ON public.store_promotions(active,starts_at,ends_at);

ALTER TABLE public.store_orders ADD COLUMN promotion_id uuid REFERENCES public.store_promotions(id) ON DELETE RESTRICT;
ALTER TABLE public.store_orders ADD COLUMN promotion_name text;
ALTER TABLE public.store_orders ADD COLUMN promotion_code text;
ALTER TABLE public.store_orders ADD COLUMN discount_minor integer NOT NULL DEFAULT 0 CHECK(discount_minor>=0);
ALTER TABLE public.store_orders ADD COLUMN delivery_discount_minor integer NOT NULL DEFAULT 0 CHECK(delivery_discount_minor>=0);
ALTER TABLE public.store_orders DROP CONSTRAINT store_orders_review_reason_check;
ALTER TABLE public.store_orders ADD CONSTRAINT store_orders_review_reason_check CHECK(review_reason IN
 ('late_payment','missing_paid_at','invalid_paid_at','product_unavailable','stock_unavailable',
  'verification_mismatch','staff_flagged','promotion_exhausted'));
ALTER TABLE public.store_orders DROP CONSTRAINT store_orders_amount_check;
ALTER TABLE public.store_orders ADD CONSTRAINT store_orders_amount_check CHECK(
 discount_minor<subtotal_minor AND delivery_discount_minor<=COALESCE(delivery_fee_minor,0) AND
 amount_minor=subtotal_minor-discount_minor+COALESCE(delivery_fee_minor,0)-delivery_discount_minor
);
CREATE INDEX store_orders_promotion_usage_idx ON public.store_orders(promotion_id,payment_status,reservation_expires_at)
 WHERE promotion_id IS NOT NULL;

-- Public/anonymous users get *only* limited RPC results; all control tables
-- remain staff-private. Service role writes orders only via guarded routes/RPCs.
ALTER TABLE public.storefront_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_size_charts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_product_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_stock_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_promotions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.storefront_options,public.store_size_charts,public.store_product_options,
  public.store_stock_alerts,public.store_promotions FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.storefront_options,public.store_size_charts,public.store_product_options,
  public.store_promotions TO authenticated;
GRANT SELECT,UPDATE ON public.store_stock_alerts TO authenticated;
GRANT ALL ON public.storefront_options,public.store_size_charts,public.store_product_options,
  public.store_stock_alerts,public.store_promotions TO service_role;
CREATE POLICY store_options_staff ON public.storefront_options FOR ALL TO authenticated
 USING(public.is_staff((SELECT auth.uid()))) WITH CHECK(public.is_staff((SELECT auth.uid())));
CREATE POLICY store_charts_staff ON public.store_size_charts FOR ALL TO authenticated
 USING(public.is_staff((SELECT auth.uid()))) WITH CHECK(public.is_staff((SELECT auth.uid())));
CREATE POLICY store_product_options_staff ON public.store_product_options FOR ALL TO authenticated
 USING(public.is_staff((SELECT auth.uid()))) WITH CHECK(public.is_staff((SELECT auth.uid())));
CREATE POLICY store_promotions_staff ON public.store_promotions FOR ALL TO authenticated
 USING(public.is_staff((SELECT auth.uid()))) WITH CHECK(public.is_staff((SELECT auth.uid())));
CREATE POLICY store_stock_alerts_staff ON public.store_stock_alerts FOR SELECT TO authenticated
 USING(public.is_staff((SELECT auth.uid())));
CREATE POLICY store_stock_alerts_staff_update ON public.store_stock_alerts FOR UPDATE TO authenticated
 USING(public.is_staff((SELECT auth.uid()))) WITH CHECK(public.is_staff((SELECT auth.uid())));

-- Product updates from existing Athena and store-confirmed orders both trigger
-- threshold crossings. Restocking auto-resolves old low/out alerts.
CREATE FUNCTION public.store_emit_stock_alert() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $stock$
DECLARE v_threshold integer;v_old integer;
BEGIN
 SELECT COALESCE((SELECT low_stock_threshold FROM public.store_product_options WHERE product_id=NEW.id::text),3) INTO v_threshold;
 IF TG_OP='INSERT' THEN v_old:=NULL; ELSE v_old:=OLD.stock; END IF;
 IF NEW.stock>v_threshold OR NOT NEW.active THEN
   UPDATE public.store_stock_alerts SET resolved_at=pg_catalog.now()
     WHERE product_id=NEW.id::text AND event_type IN ('low','out') AND resolved_at IS NULL;
 END IF;
 IF NOT NEW.active THEN RETURN NEW; END IF;
 IF NEW.stock=0 AND (v_old IS NULL OR v_old>0) THEN
   UPDATE public.store_stock_alerts SET resolved_at=pg_catalog.now()
     WHERE product_id=NEW.id::text AND event_type='low' AND resolved_at IS NULL;
   INSERT INTO public.store_stock_alerts(product_id,product_name,event_type,stock_at_event,threshold)
     VALUES(NEW.id::text,NEW.name,'out',0,v_threshold);
 ELSIF NEW.stock>0 AND v_threshold>0 AND NEW.stock<=v_threshold
   AND (v_old IS NULL OR v_old=0 OR v_old>v_threshold) THEN
   UPDATE public.store_stock_alerts SET resolved_at=pg_catalog.now()
     WHERE product_id=NEW.id::text AND event_type='out' AND resolved_at IS NULL;
   INSERT INTO public.store_stock_alerts(product_id,product_name,event_type,stock_at_event,threshold)
     VALUES(NEW.id::text,NEW.name,'low',NEW.stock,v_threshold);
 END IF;
 RETURN NEW;
END;
$stock$;
REVOKE ALL ON FUNCTION public.store_emit_stock_alert() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER store_stock_notifications AFTER INSERT OR UPDATE OF stock,active ON public.products
 FOR EACH ROW EXECUTE FUNCTION public.store_emit_stock_alert();

-- A changed per-product threshold immediately updates the staff's event
-- queue. No invented quantity or customer event is created.
CREATE FUNCTION public.store_recheck_stock_threshold() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $threshold$
DECLARE v_p record;
BEGIN
 SELECT name,stock,active INTO v_p FROM public.products WHERE id::text=NEW.product_id;
 IF NOT FOUND THEN RETURN NEW; END IF;
 IF NOT v_p.active OR v_p.stock>NEW.low_stock_threshold THEN
   UPDATE public.store_stock_alerts SET resolved_at=pg_catalog.now()
     WHERE product_id=NEW.product_id AND event_type IN ('low','out') AND resolved_at IS NULL;
 ELSIF v_p.stock=0 THEN
   UPDATE public.store_stock_alerts SET resolved_at=pg_catalog.now()
     WHERE product_id=NEW.product_id AND event_type='low' AND resolved_at IS NULL;
   IF NOT EXISTS(SELECT 1 FROM public.store_stock_alerts WHERE product_id=NEW.product_id
      AND event_type='out' AND resolved_at IS NULL) THEN
     INSERT INTO public.store_stock_alerts(product_id,product_name,event_type,stock_at_event,threshold)
       VALUES(NEW.product_id,v_p.name,'out',0,NEW.low_stock_threshold);
   END IF;
 ELSE
   UPDATE public.store_stock_alerts SET resolved_at=pg_catalog.now()
     WHERE product_id=NEW.product_id AND event_type='out' AND resolved_at IS NULL;
   IF NOT EXISTS(SELECT 1 FROM public.store_stock_alerts WHERE product_id=NEW.product_id
      AND event_type='low' AND resolved_at IS NULL) THEN
     INSERT INTO public.store_stock_alerts(product_id,product_name,event_type,stock_at_event,threshold)
       VALUES(NEW.product_id,v_p.name,'low',v_p.stock,NEW.low_stock_threshold);
   END IF;
 END IF;
 RETURN NEW;
END;
$threshold$;
REVOKE ALL ON FUNCTION public.store_recheck_stock_threshold() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER store_threshold_notifications AFTER INSERT OR UPDATE OF low_stock_threshold ON public.store_product_options
 FOR EACH ROW EXECUTE FUNCTION public.store_recheck_stock_threshold();

-- Called only AFTER a database-authoritative stock failure in the checkout
-- route. No customer data is stored; at most one blocked alert per product/hr.
CREATE FUNCTION public.store_note_checkout_stock_issue(p_product_id text) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $blocked$
DECLARE v_product record;v_reserved integer;v_threshold integer;
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'Server access only'; END IF;
 SELECT * INTO v_product FROM public.products WHERE id::text=p_product_id;
 IF NOT FOUND OR NOT v_product.active THEN RETURN; END IF;
 SELECT COALESCE(pg_catalog.sum(i.quantity),0) INTO v_reserved FROM public.store_order_items i
 JOIN public.store_orders o ON o.id=i.order_id
 WHERE i.product_id=p_product_id AND o.reservation_expires_at>pg_catalog.now()
   AND o.payment_status IN ('pending','provider_verified') AND o.order_status<>'cancelled';
 IF v_product.stock>v_reserved THEN RETURN; END IF;
 IF EXISTS(SELECT 1 FROM public.store_stock_alerts WHERE product_id=p_product_id AND event_type='checkout_blocked'
   AND created_at>pg_catalog.now()-interval '1 hour') THEN RETURN; END IF;
 SELECT COALESCE((SELECT low_stock_threshold FROM public.store_product_options WHERE product_id=p_product_id),3) INTO v_threshold;
 INSERT INTO public.store_stock_alerts(product_id,product_name,event_type,stock_at_event,threshold)
 VALUES(p_product_id,v_product.name,'checkout_blocked',v_product.stock,v_threshold);
END;
$blocked$;
REVOKE ALL ON FUNCTION public.store_note_checkout_stock_issue(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.store_note_checkout_stock_issue(text) TO service_role;

-- Choose the SINGLE most valuable eligible offer, including delivery savings
-- only when a real configured fee exists. Serialize redemption counting by
-- locking promotion rows inside checkout. These RPCs accept only service_role.
CREATE FUNCTION public.store_price_offer_v1(
 p_subtotal integer,p_fee integer,p_lines jsonb,p_code text,p_email text,p_lock boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $price$
DECLARE
 v_code text:=pg_catalog.upper(pg_catalog.btrim(COALESCE(p_code,'')));
 v_promo public.store_promotions%ROWTYPE;
 v_found_code boolean:=false;
 v_code_eligible boolean:=false;
 v_eligible bigint;
 v_product_discount integer;
 v_delivery_discount integer;
 v_best integer:=0;
 v_best_product integer:=0;
 v_best_delivery integer:=0;
 v_best_promo public.store_promotions%ROWTYPE;
 v_used integer;
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'Server access only'; END IF;
 IF p_subtotal NOT BETWEEN 1 AND 2000000000 OR p_fee IS NOT NULL AND p_fee NOT BETWEEN 0 AND 100000000
    OR pg_catalog.jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid pricing request'; END IF;
 IF pg_catalog.length(v_code)>24 OR (v_code<>'' AND v_code !~ '^[A-Z0-9-]{4,24}$') THEN
    RAISE EXCEPTION 'Check the discount code'; END IF;
 -- Ordered locks prevent oversubscribing global limits for unrelated carts.
 FOR v_promo IN SELECT * FROM public.store_promotions WHERE active=true
    AND starts_at<=pg_catalog.now() AND (ends_at IS NULL OR ends_at>pg_catalog.now())
    AND (code IS NULL OR code=v_code) ORDER BY id LOOP
   -- Quotes never lock promotions. Actual reservations lock in a consistent
   -- order and recheck a rule after any concurrent staff edit completes.
   IF p_lock THEN
     SELECT * INTO v_promo FROM public.store_promotions WHERE id=v_promo.id FOR UPDATE;
     IF NOT FOUND OR NOT v_promo.active OR v_promo.starts_at>pg_catalog.now() OR
       (v_promo.ends_at IS NOT NULL AND v_promo.ends_at<=pg_catalog.now()) OR
       (v_promo.code IS NOT NULL AND v_promo.code<>v_code) THEN CONTINUE; END IF;
   END IF;
   IF v_promo.code=v_code AND v_code<>'' THEN v_found_code:=true; END IF;
   IF p_subtotal<v_promo.min_subtotal_minor THEN CONTINUE; END IF;
   SELECT COALESCE(pg_catalog.sum((line->>'line_total_minor')::bigint),0)
     INTO v_eligible FROM pg_catalog.jsonb_array_elements(p_lines) AS entries(line)
     WHERE v_promo.scope='all'
       OR (v_promo.scope='products' AND line->>'id'=ANY(v_promo.product_ids))
       OR (v_promo.scope='categories' AND pg_catalog.lower(line->>'category')=ANY(
         SELECT pg_catalog.lower(cat) FROM pg_catalog.unnest(v_promo.categories) AS cats(cat)));
   IF v_eligible<1 THEN CONTINUE; END IF;
   -- Count paid and currently reserved uses. Pending expired attempts don't
   -- consume codes forever; Paystack-verified exceptions still count.
   SELECT pg_catalog.count(*)::integer INTO v_used FROM public.store_orders o
     WHERE o.promotion_id=v_promo.id AND
      (o.payment_status='confirmed' OR
       (o.payment_status='provider_verified' AND o.review_reason IS DISTINCT FROM 'promotion_exhausted') OR
       (o.payment_status='pending' AND o.reservation_expires_at>pg_catalog.now() AND o.order_status<>'cancelled'));
   IF v_promo.max_redemptions IS NOT NULL AND v_used>=v_promo.max_redemptions THEN CONTINUE; END IF;
   IF v_promo.per_email_limit IS NOT NULL AND (
      SELECT pg_catalog.count(*) FROM public.store_orders o
        WHERE o.promotion_id=v_promo.id AND o.customer_email=pg_catalog.lower(pg_catalog.btrim(COALESCE(p_email,'')))
          AND (o.payment_status='confirmed' OR
       (o.payment_status='provider_verified' AND o.review_reason IS DISTINCT FROM 'promotion_exhausted') OR
            (o.payment_status='pending' AND o.reservation_expires_at>pg_catalog.now() AND o.order_status<>'cancelled'))
     )>=v_promo.per_email_limit THEN CONTINUE; END IF;
   v_product_discount:=CASE WHEN v_promo.kind='percentage'
       THEN pg_catalog.round(v_eligible*v_promo.percent_off/100)::integer
       ELSE LEAST(v_eligible,v_promo.amount_minor)::integer END;
   -- Paystack cannot initialize a zero-value transaction. Never exceed the
   -- eligible item value or reduce the actual charge below one pesewa.
   v_product_discount:=LEAST(v_product_discount,v_eligible::integer,p_subtotal-1);
   v_delivery_discount:=CASE WHEN v_promo.free_delivery THEN COALESCE(p_fee,0) ELSE 0 END;
   IF v_product_discount+v_delivery_discount<=0 THEN CONTINUE; END IF;
   IF v_promo.code=v_code AND v_code<>'' THEN v_code_eligible:=true; END IF;
   IF v_product_discount+v_delivery_discount>v_best THEN
     v_best:=v_product_discount+v_delivery_discount;
     v_best_product:=v_product_discount;
     v_best_delivery:=v_delivery_discount;
     v_best_promo:=v_promo;
   END IF;
 END LOOP;
 IF v_code<>'' AND NOT v_code_eligible THEN
   RAISE EXCEPTION 'Discount code is unavailable or does not apply to this order'; END IF;
 RETURN pg_catalog.jsonb_build_object(
   'subtotal_minor',p_subtotal,'delivery_fee_minor',p_fee,
   'discount_minor',v_best_product,'delivery_discount_minor',v_best_delivery,
   'amount_minor',p_subtotal-v_best_product+COALESCE(p_fee,0)-v_best_delivery,
   'promotion_id',v_best_promo.id,'promotion_name',v_best_promo.name,
   'promotion_code',v_best_promo.code,
   'message',CASE WHEN v_code<>'' AND v_best_promo.code IS NULL AND v_found_code
     THEN 'A better automatic offer has been applied.' ELSE NULL END
 );
END;
$price$;
REVOKE ALL ON FUNCTION public.store_price_offer_v1(integer,integer,jsonb,text,text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.store_price_offer_v1(integer,integer,jsonb,text,text,boolean) TO service_role;

-- The quote is re-priced from current database products/rates, not browser
-- prices. Checkout independently revalidates price, stock, code and expiry.
CREATE FUNCTION public.store_quote_v1(p_items jsonb,p_method text,p_zone_id uuid,p_code text,p_email text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $quote$
DECLARE
 v_line jsonb;v_p public.products%ROWTYPE;v_lines jsonb:='[]'::jsonb;
 v_id text;v_quantity integer;v_requested integer;v_price bigint;v_subtotal bigint:=0;v_fee integer;v_reserved integer;
 v_open boolean;
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'Server access only'; END IF;
 IF pg_catalog.jsonb_typeof(p_items) IS DISTINCT FROM 'array'
   OR pg_catalog.jsonb_array_length(p_items) NOT BETWEEN 1 AND 8 THEN
   RAISE EXCEPTION 'Choose between one and eight different items'; END IF;
 IF p_method NOT IN ('pickup','delivery') OR p_method IS NULL THEN RAISE EXCEPTION 'Choose pickup or delivery'; END IF;
 SELECT pg_catalog.count(*)=1 AND pg_catalog.bool_and(availability IN ('normal','available'))
   INTO v_open FROM public.settings;
 IF NOT COALESCE(v_open,false) THEN RAISE EXCEPTION 'Online orders are paused'; END IF;
 IF p_method='pickup' AND p_zone_id IS NOT NULL THEN RAISE EXCEPTION 'Pickup has no delivery zone'; END IF;
 IF p_method='pickup' THEN v_fee:=0;
 ELSIF p_zone_id IS NOT NULL THEN
   SELECT fee_minor INTO v_fee FROM public.store_delivery_zones WHERE id=p_zone_id AND active=true;
   IF NOT FOUND THEN RAISE EXCEPTION 'The selected delivery zone is no longer available'; END IF;
 END IF;
 IF EXISTS(SELECT 1 FROM (
    SELECT line->>'id',line->>'size' FROM pg_catalog.jsonb_array_elements(p_items) AS e(line)
    GROUP BY line->>'id',line->>'size' HAVING pg_catalog.count(*)>1) duplicates) THEN
   RAISE EXCEPTION 'Duplicate product and size in bag'; END IF;
 FOR v_line IN SELECT value FROM pg_catalog.jsonb_array_elements(p_items) LOOP
   v_id:=v_line->>'id';
   IF pg_catalog.jsonb_typeof(v_line) IS DISTINCT FROM 'object'
     OR pg_catalog.length(COALESCE(v_id,'')) NOT BETWEEN 1 AND 128
     OR pg_catalog.length(COALESCE(v_line->>'size','')) NOT BETWEEN 1 AND 80
     OR COALESCE(v_line->>'quantity','') !~ '^[1-9][0-9]?$'
     OR (v_line->>'quantity')::integer>10 THEN RAISE EXCEPTION 'Invalid product, size or quantity'; END IF;
   v_quantity:=(v_line->>'quantity')::integer;
   SELECT * INTO v_p FROM public.products WHERE id::text=v_id AND active=true;
   IF NOT FOUND OR NOT COALESCE(v_line->>'size'=ANY(v_p.sizes),false) THEN
     RAISE EXCEPTION 'An item or size is no longer available. Refresh your bag.'; END IF;
   SELECT COALESCE(pg_catalog.sum(i.quantity),0) INTO v_reserved FROM public.store_order_items i
     JOIN public.store_orders o ON o.id=i.order_id WHERE i.product_id=v_id
       AND o.reservation_expires_at>pg_catalog.now() AND o.payment_status IN ('pending','provider_verified')
       AND o.order_status<>'cancelled';
   SELECT pg_catalog.sum((entry->>'quantity')::integer) INTO v_requested
     FROM pg_catalog.jsonb_array_elements(p_items) AS e(entry) WHERE entry->>'id'=v_id;
   IF v_p.stock<v_reserved+v_requested THEN RAISE EXCEPTION 'Not enough stock left for %. Refresh your bag.',v_p.name; END IF;
   v_price:=pg_catalog.round(v_p.price*100)::bigint;
   IF v_price NOT BETWEEN 1 AND 100000000 THEN RAISE EXCEPTION 'Product price requires review'; END IF;
   v_subtotal:=v_subtotal+v_price*v_quantity;
   v_lines:=v_lines||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'id',v_id,'category',v_p.category,'line_total_minor',v_price*v_quantity));
 END LOOP;
 IF v_subtotal+COALESCE(v_fee,0) NOT BETWEEN 1 AND 2000000000 THEN
   RAISE EXCEPTION 'Cart total exceeds checkout limits'; END IF;
 RETURN public.store_price_offer_v1(v_subtotal::integer,v_fee,v_lines,p_code,p_email,false);
END;
$quote$;
REVOKE ALL ON FUNCTION public.store_quote_v1(jsonb,text,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.store_quote_v1(jsonb,text,uuid,text,text) TO service_role;

-- Extend (do NOT replace) the original atomic checkout. Everything below
-- rolls back, including the reservation/attempt, if the offer is not valid.
CREATE FUNCTION public.store_create_checkout_order_v2(
 p_customer jsonb,p_items jsonb,p_method text,p_zone_id uuid,
 p_address text,p_client_hash text,p_code text,p_expected_amount_minor integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $checkout2$
DECLARE v_original jsonb;v_price jsonb;v_order public.store_orders%ROWTYPE;v_lines jsonb;
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'Server access only'; END IF;
 v_original:=public.store_create_checkout_order(p_customer,p_items,p_method,p_zone_id,p_address,p_client_hash);
 SELECT * INTO v_order FROM public.store_orders WHERE id=(v_original->>'id')::uuid FOR UPDATE;
 SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',product_id,'category',category,
  'line_total_minor',line_total_minor)),'[]'::jsonb) INTO v_lines FROM public.store_order_items WHERE order_id=v_order.id;
 v_price:=public.store_price_offer_v1(v_order.subtotal_minor,v_order.delivery_fee_minor,v_lines,p_code,v_order.customer_email,true);
 IF p_expected_amount_minor IS NULL OR (v_price->>'amount_minor')::integer<>p_expected_amount_minor THEN
   RAISE EXCEPTION 'Price or promotion changed. Refresh your quote before paying.';
 END IF;
 UPDATE public.store_orders SET promotion_id=(v_price->>'promotion_id')::uuid,
   promotion_name=v_price->>'promotion_name',promotion_code=v_price->>'promotion_code',
   discount_minor=(v_price->>'discount_minor')::integer,
   delivery_discount_minor=(v_price->>'delivery_discount_minor')::integer,
   amount_minor=(v_price->>'amount_minor')::integer,updated_at=pg_catalog.now() WHERE id=v_order.id;
 RETURN v_original||pg_catalog.jsonb_build_object('amount_minor',(v_price->>'amount_minor')::integer,
    'discount_minor',(v_price->>'discount_minor')::integer,
    'delivery_discount_minor',(v_price->>'delivery_discount_minor')::integer,
    'promotion_name',v_price->>'promotion_name');
END;
$checkout2$;
REVOKE ALL ON FUNCTION public.store_create_checkout_order_v2(jsonb,jsonb,text,uuid,text,text,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.store_create_checkout_order_v2(jsonb,jsonb,text,uuid,text,text,text,integer) TO service_role;
-- Retire the old unbounded public catalog RPC once all store clients use v3.
REVOKE EXECUTE ON FUNCTION public.thetieguy_store_catalog_v2() FROM anon,authenticated;

-- Bound and validate chart structure at the database as well as in Athena.
CREATE FUNCTION public.store_chart_valid(p_columns text[],p_rows jsonb) RETURNS boolean
 LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $chartvalid$
DECLARE v_column text;v_row jsonb;v_cell jsonb;
BEGIN
 IF pg_catalog.array_length(p_columns,1) NOT BETWEEN 2 AND 6 OR
    pg_catalog.jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR pg_catalog.jsonb_array_length(p_rows)>35
 THEN RETURN false; END IF;
 FOREACH v_column IN ARRAY p_columns LOOP
   IF pg_catalog.length(pg_catalog.btrim(COALESCE(v_column,''))) NOT BETWEEN 1 AND 55 THEN RETURN false; END IF;
 END LOOP;
 FOR v_row IN SELECT value FROM pg_catalog.jsonb_array_elements(p_rows) LOOP
   IF pg_catalog.jsonb_typeof(v_row)<>'array' OR
      pg_catalog.jsonb_array_length(v_row)<>pg_catalog.array_length(p_columns,1) THEN RETURN false; END IF;
   FOR v_cell IN SELECT value FROM pg_catalog.jsonb_array_elements(v_row) LOOP
     IF pg_catalog.jsonb_typeof(v_cell)<>'string' OR pg_catalog.length(v_cell#>>'{}')>100 THEN RETURN false; END IF;
   END LOOP;
 END LOOP;
 RETURN true;
END;
$chartvalid$;
ALTER TABLE public.store_size_charts ADD CONSTRAINT store_charts_rows_valid CHECK(public.store_chart_valid(columns,rows));

-- Public list is paginated at the DATABASE. No 1,000-item truncation, no
-- single unbounded JSON catalog; sorting/searching works across ALL listings.
CREATE FUNCTION public.thetieguy_store_catalog_v3(
 p_page integer DEFAULT 1,p_limit integer DEFAULT 24,p_category text DEFAULT 'All',
 p_query text DEFAULT '',p_sort text DEFAULT 'featured'
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $catalog3$
DECLARE v_result jsonb;v_query text:=pg_catalog.lower(pg_catalog.btrim(COALESCE(p_query,'')));
BEGIN
 IF p_page IS NULL OR p_page<1 OR p_limit NOT BETWEEN 1 AND 48
   OR p_category NOT IN ('All','Ties','Clips','Brooches','Other')
   OR p_sort NOT IN ('featured','low','high','name') OR pg_catalog.length(v_query)>100 THEN
   RAISE EXCEPTION 'Invalid catalog filters'; END IF;
 WITH matching AS (
  SELECT p.*,COALESCE(o.featured,false) AS featured,
    CASE WHEN pg_catalog.lower(COALESCE(p.category,'')||' '||COALESCE(p.name,''))
           ~ 'brooch|pin|lapel|pharmacy|medical|laboratory|research|law' THEN 'Brooches'
         WHEN pg_catalog.lower(COALESCE(p.category,'')||' '||COALESCE(p.name,'')) ~ 'clip|bar' THEN 'Clips'
         WHEN pg_catalog.lower(COALESCE(p.category,'')||' '||COALESCE(p.name,'')) ~ 'tie|necktie|paisley|floral' THEN 'Ties'
         ELSE 'Other' END AS group_name
  FROM public.products p LEFT JOIN public.store_product_options o ON o.product_id=p.id::text
  WHERE p.active=true
 ), filtered AS (
  SELECT * FROM matching WHERE (p_category='All' OR group_name=p_category)
    AND (v_query='' OR pg_catalog.strpos(pg_catalog.lower(
      COALESCE(name,'')||' '||COALESCE(category,'')||' '||COALESCE(description,'')),v_query)>0)
 ), page AS (
  SELECT * FROM filtered ORDER BY
    CASE WHEN p_sort='low' THEN price END ASC NULLS LAST,
    CASE WHEN p_sort='high' THEN price END DESC NULLS LAST,
    CASE WHEN p_sort='name' THEN name END ASC NULLS LAST,
    CASE WHEN p_sort='featured' THEN featured END DESC NULLS LAST,
    CASE WHEN p_sort='featured' THEN stock>0 END DESC NULLS LAST,
    name,id::text OFFSET (p_page::bigint-1)*p_limit LIMIT p_limit
 )
 SELECT pg_catalog.jsonb_build_object(
   'business',(SELECT pg_catalog.jsonb_build_object('name',s.business_name,
      'availability',CASE WHEN s.availability IN ('normal','available') THEN 'available' ELSE 'unavailable' END,
      'unavailable_message',s.unavailable_message)
     FROM public.settings s WHERE (SELECT pg_catalog.count(*) FROM public.settings)=1 LIMIT 1),
   'storefront',(SELECT pg_catalog.to_jsonb(o)-'id'-'singleton_key'-'updated_at' FROM public.storefront_options o LIMIT 1),
   'products',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',p.id::text,'name',p.name,'category',p.category,'description',p.description,
      'image_url',p.image_url,'sizes',p.sizes,'price_minor',pg_catalog.round(p.price*100)::bigint,
      'available',p.stock>0,'has_size_chart',
        (EXISTS(SELECT 1 FROM public.store_size_charts c WHERE c.id=(SELECT size_chart_id
          FROM public.store_product_options x WHERE x.product_id=p.id::text) AND c.active=true) OR
        EXISTS(SELECT 1 FROM public.store_size_charts c WHERE c.default_for_category=true
          AND c.active=true AND pg_catalog.lower(c.category)=pg_catalog.lower(p.category))))
       ORDER BY CASE WHEN p_sort='low' THEN p.price END ASC NULLS LAST,
       CASE WHEN p_sort='high' THEN p.price END DESC NULLS LAST,
       CASE WHEN p_sort='name' THEN p.name END ASC NULLS LAST,
       CASE WHEN p_sort='featured' THEN p.featured END DESC NULLS LAST,
       CASE WHEN p_sort='featured' THEN p.stock>0 END DESC NULLS LAST,p.name,p.id::text)
     FROM page p),'[]'::jsonb),
   'total_count',(SELECT pg_catalog.count(*) FROM filtered),
   'page',p_page,'page_size',p_limit,
   'delivery_zones',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
     'id',z.id::text,'name',z.name,'fee_minor',z.fee_minor) ORDER BY z.name)
     FROM public.store_delivery_zones z WHERE z.active=true),'[]'::jsonb)
 ) INTO v_result;
 RETURN v_result;
END;
$catalog3$;
REVOKE ALL ON FUNCTION public.thetieguy_store_catalog_v3(integer,integer,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.thetieguy_store_catalog_v3(integer,integer,text,text,text) TO anon,authenticated,service_role;

-- A bounded cart lookup prevents changing a category/page from erasing bag
-- products. Inactive/deleted products are omitted and flagged in the UI.
CREATE FUNCTION public.store_cart_products_v1(p_ids text[]) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $cartproducts$
DECLARE v_result jsonb;
BEGIN
 IF pg_catalog.array_length(p_ids,1) NOT BETWEEN 1 AND 8 OR
  EXISTS(SELECT 1 FROM pg_catalog.unnest(p_ids) AS ids(id) WHERE pg_catalog.length(id) NOT BETWEEN 1 AND 128)
  THEN RAISE EXCEPTION 'Invalid cart products'; END IF;
 SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id',p.id::text,'name',p.name,'category',p.category,'description',p.description,
    'image_url',p.image_url,'sizes',p.sizes,'price_minor',pg_catalog.round(p.price*100)::bigint,
    'available',p.stock>0,'has_size_chart',
      (EXISTS(SELECT 1 FROM public.store_size_charts c WHERE c.id=o.size_chart_id AND c.active=true) OR
       EXISTS(SELECT 1 FROM public.store_size_charts c WHERE c.default_for_category=true
          AND c.active=true AND pg_catalog.lower(c.category)=pg_catalog.lower(p.category)))) ORDER BY p.name),'[]'::jsonb)
 INTO v_result FROM public.products p LEFT JOIN public.store_product_options o ON o.product_id=p.id::text
 WHERE p.id::text=ANY(p_ids) AND p.active=true;
 RETURN v_result;
END;
$cartproducts$;
REVOKE ALL ON FUNCTION public.store_cart_products_v1(text[]) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.store_cart_products_v1(text[]) TO anon,authenticated,service_role;

CREATE FUNCTION public.store_size_chart_for_product_v1(p_product_id text) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $publicchart$
DECLARE v_p public.products%ROWTYPE;v_chart public.store_size_charts%ROWTYPE;v_id uuid;
BEGIN
 IF pg_catalog.length(p_product_id) NOT BETWEEN 1 AND 128 THEN RETURN NULL; END IF;
 SELECT * INTO v_p FROM public.products WHERE id::text=p_product_id AND active=true;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT size_chart_id INTO v_id FROM public.store_product_options WHERE product_id=p_product_id;
 IF v_id IS NOT NULL THEN
   SELECT * INTO v_chart FROM public.store_size_charts WHERE id=v_id AND active=true;
 END IF;
 IF v_chart.id IS NULL THEN
   SELECT * INTO v_chart FROM public.store_size_charts WHERE default_for_category=true AND active=true
     AND pg_catalog.lower(category)=pg_catalog.lower(v_p.category) LIMIT 1;
 END IF;
 IF v_chart.id IS NULL THEN RETURN NULL; END IF;
 RETURN pg_catalog.jsonb_build_object('title',v_chart.title,'units',v_chart.units,
   'columns',v_chart.columns,'rows',v_chart.rows,'notes',v_chart.notes);
END;
$publicchart$;
REVOKE ALL ON FUNCTION public.store_size_chart_for_product_v1(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.store_size_chart_for_product_v1(text) TO anon,authenticated,service_role;

-- A delayed (but timely) Paystack confirmation may arrive after its
-- 30-minute promo reservation expired and another checkout took the last
-- redemption. Keep the REAL charge for human review rather than silently
-- oversubscribing a limit or marking an unfulfillable order confirmed.
-- Only call this from the independently verified Paystack reconciliation path.
CREATE FUNCTION public.store_settle_verified_payment_v2(
 p_reference text,p_order_id uuid,p_amount_minor integer,p_currency text,p_email text,
 p_paid_at timestamptz,p_domain text
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $settle2$
DECLARE v_order public.store_orders%ROWTYPE;v_offer public.store_promotions%ROWTYPE;v_id text;v_uses integer;v_email_uses integer;
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'Server access only'; END IF;
 SELECT * INTO v_order FROM public.store_orders WHERE reference=p_reference AND id=p_order_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown store payment reference'; END IF;
 IF p_domain NOT IN ('test','live') OR p_domain IS NULL OR
    v_order.amount_minor<>p_amount_minor OR p_currency<>'GHS' OR v_order.currency<>p_currency
    OR v_order.customer_email IS DISTINCT FROM pg_catalog.lower(p_email) OR
    (v_order.provider_domain IS NOT NULL AND v_order.provider_domain<>p_domain) THEN
    RAISE EXCEPTION 'Verified payment does not match the order'; END IF;
 IF v_order.payment_status IN ('confirmed','refund_needed','refunded','payment_review') THEN
   RETURN v_order.payment_status; END IF;
 IF v_order.payment_status='provider_verified' AND v_order.review_reason IS NOT NULL THEN
   RETURN 'provider_verified'; END IF;
 -- The original settlement handles bad/missing/late Paystack timestamps.
 IF v_order.promotion_id IS NULL OR p_paid_at IS NULL OR
    p_paid_at<v_order.created_at-interval '5 minutes' OR
    p_paid_at>pg_catalog.now()+interval '5 minutes' OR p_paid_at>v_order.reservation_expires_at THEN
   RETURN public.store_settle_verified_payment(p_reference,p_order_id,p_amount_minor,p_currency,p_email,p_paid_at,p_domain);
 END IF;
 -- Same product-then-promotion lock order as checkout; the legacy settlement
 -- later reacquires these product locks within this same transaction.
 FOR v_id IN SELECT DISTINCT i.product_id FROM public.store_order_items i
   WHERE i.order_id=v_order.id ORDER BY 1 LOOP
   PERFORM 1 FROM public.products WHERE id::text=v_id FOR UPDATE;
 END LOOP;
 SELECT * INTO v_offer FROM public.store_promotions WHERE id=v_order.promotion_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Promotion record removed; review payment'; END IF;
 SELECT pg_catalog.count(*)::integer INTO v_uses FROM public.store_orders o
   WHERE o.id<>v_order.id AND o.promotion_id=v_offer.id AND
     (o.payment_status='confirmed' OR
       (o.payment_status='provider_verified' AND o.review_reason IS DISTINCT FROM 'promotion_exhausted') OR
      (o.payment_status='pending' AND o.reservation_expires_at>pg_catalog.now() AND o.order_status<>'cancelled'));
 SELECT pg_catalog.count(*)::integer INTO v_email_uses FROM public.store_orders o
   WHERE o.id<>v_order.id AND o.promotion_id=v_offer.id AND o.customer_email=v_order.customer_email AND
     (o.payment_status='confirmed' OR
       (o.payment_status='provider_verified' AND o.review_reason IS DISTINCT FROM 'promotion_exhausted') OR
      (o.payment_status='pending' AND o.reservation_expires_at>pg_catalog.now() AND o.order_status<>'cancelled'));
 IF (v_offer.max_redemptions IS NOT NULL AND v_uses>=v_offer.max_redemptions) OR
    (v_offer.per_email_limit IS NOT NULL AND v_email_uses>=v_offer.per_email_limit) THEN
   UPDATE public.store_orders SET provider_status='verified',provider_domain=p_domain,
      provider_paid_at=p_paid_at,payment_status='provider_verified',review_reason='promotion_exhausted',
      updated_at=pg_catalog.now() WHERE id=v_order.id;
   INSERT INTO public.store_payment_audit(order_id,event_type,detail)
      VALUES(v_order.id,'payment_review','promotion_exhausted');
   RETURN 'provider_verified'; -- only a person can decide refund/manual resolution
 END IF;
 RETURN public.store_settle_verified_payment(p_reference,p_order_id,p_amount_minor,p_currency,p_email,p_paid_at,p_domain);
END;
$settle2$;
REVOKE ALL ON FUNCTION public.store_settle_verified_payment_v2(text,uuid,integer,text,text,timestamptz,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.store_settle_verified_payment_v2(text,uuid,integer,text,text,timestamptz,text) TO service_role;

DO $publication$
DECLARE v_table text;
BEGIN
 IF EXISTS(SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime') THEN
   FOREACH v_table IN ARRAY ARRAY['storefront_options','store_size_charts','store_product_options','store_stock_alerts','store_promotions'] LOOP
     IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_publication_tables WHERE pubname='supabase_realtime'
          AND schemaname='public' AND tablename=v_table) THEN
       EXECUTE pg_catalog.format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I',v_table);
     END IF;
   END LOOP;
 END IF;
END;
$publication$;
NOTIFY pgrst,'reload schema';
COMMIT;
