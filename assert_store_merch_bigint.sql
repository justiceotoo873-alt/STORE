-- Disposable local bigint-ID fixture; never run against live Supabase.
INSERT INTO public.store_product_options(product_id,low_stock_threshold) VALUES('9223372036854775807',1);
INSERT INTO public.store_promotions(name,code,kind,percent_off,active) VALUES('Bigint fixture','BIGINT10','percentage',10,true);
SET ROLE anon;
DO $assert$ DECLARE v jsonb;BEGIN
 v:=public.thetieguy_store_catalog_v3(1,24,'Ties','','featured');
 IF v #>> '{products,0,id}' <> '9223372036854775807' THEN RAISE EXCEPTION 'Bigint product ID truncated by catalog';END IF;
 IF pg_catalog.jsonb_array_length(public.store_cart_products_v1(ARRAY['9223372036854775807']))<>1 THEN RAISE EXCEPTION 'Bigint cart lookup failed'; END IF;
END;$assert$;
RESET ROLE;
SET ROLE service_role;SET test.role='service_role';
DO $assert$ DECLARE v_items jsonb:='[{"id":"9223372036854775807","size":"One size","quantity":1}]'::jsonb;v_price jsonb;v_order jsonb;BEGIN
 v_price:=public.store_quote_v1(v_items,'pickup',null,'BIGINT10','bigint@example.com');
 IF (v_price->>'amount_minor')::integer<>10799 THEN RAISE EXCEPTION 'Bigint ID quote wrong: %',v_price;END IF;
 v_order:=public.store_create_checkout_order_v2('{"name":"Bigint Buyer","email":"bigint@example.com","phone":"+233200000000"}'::jsonb,v_items,'pickup',null,'','dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd','BIGINT10',10799);
 IF public.store_settle_verified_payment_v2(v_order->>'reference',(v_order->>'id')::uuid,10799,'GHS','bigint@example.com',pg_catalog.now(),'test')<>'confirmed' THEN RAISE EXCEPTION 'Bigint discounted settlement failed'; END IF;
END;$assert$;
RESET ROLE;
DO $assert$ BEGIN
 IF (SELECT stock FROM public.products WHERE id=9223372036854775807)<>1 THEN RAISE EXCEPTION 'Bigint stock not deducted once'; END IF;
END;$assert$;
SELECT 'PASS: bigint-ID merch catalog/cart/quote/discounted checkout/auto-settlement' AS result;
