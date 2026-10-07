-- WHY DOESN'T THE ONLINE STORE SHOW MY PRODUCTS?  (READ-ONLY)
-- Safe to run any time in the Supabase SQL Editor. It writes nothing (every
-- statement runs in a read-only transaction) and the one function it calls is
-- STABLE. It never changes products, settings or orders.
--
-- Run it, then read the last result grid and the "NOTICE" lines.
-- Verdict lines are prefixed with RESULT:.

-- Each statement below runs in its own read-only transaction, so one failing
-- check never hides the others. Change nothing here to make it write.
set default_transaction_read_only = on;

-- =====================================================================
-- 0) Guard: are the base tables even present?
-- =====================================================================
do $guard$
begin
  if pg_catalog.to_regclass('public.products') is null or pg_catalog.to_regclass('public.settings') is null then
    raise notice 'RESULT: public.products and/or public.settings do not exist in this project. You are on the wrong Supabase project, or the base dashboard schema was never created. The checks below will fail — run deploy/00_preflight_read_only.sql instead.';
  else
    raise notice 'RESULT: base tables found (public.products, public.settings).';
  end if;
end;
$guard$;

-- =====================================================================
-- 1) Products and the exact reason each one would be hidden
--    (the store shows a product only when products.active = true)
-- =====================================================================
select p.id::text as product_id,
       p.name,
       p.category,
       p.price,
       p.stock,
       p.active,
       pg_catalog.length(coalesce(p.image_url, '')) > 0 as has_image,
       coalesce(pg_catalog.array_length(p.sizes, 1), 0) as size_count,
       case
         when p.active is not true then 'HIDDEN: active is false — turn the product on'
         when p.name is null or pg_catalog.btrim(p.name) = '' then 'BROKEN: name is empty'
         when p.price is null then 'BROKEN: price is empty'
         when p.stock is null or p.stock <= 0 then 'SHOWN but sold out (available = false, no buy button)'
         else 'SHOWN normally'
       end as store_visibility
  from public.products p
 order by p.active desc nulls last, p.name;

-- =====================================================================
-- 2) Store-side configuration the catalog reads
-- =====================================================================
select (select pg_catalog.count(*) from public.products) as products_total,
       (select pg_catalog.count(*) from public.products where active is true) as products_active,
       (select pg_catalog.count(*) from public.settings) as settings_rows,
       (select s.availability from public.settings s limit 1) as availability,
       (select s.business_name from public.settings s limit 1) as business_name,
       pg_catalog.to_regprocedure('public.thetieguy_store_catalog_v3(integer,integer,text,text,text)') is not null
         as catalog_rpc_exists,
       pg_catalog.to_regprocedure('public.thetieguy_store_cart_products_v1(text[])') is not null
         as cart_rpc_exists,
       case when pg_catalog.to_regprocedure('public.thetieguy_store_catalog_v3(integer,integer,text,text,text)') is not null
            then pg_catalog.has_function_privilege('anon',
              'public.thetieguy_store_catalog_v3(integer,integer,text,text,text)', 'EXECUTE')
            else false end as anon_may_call_catalog;

-- =====================================================================
-- 3) What the store's own catalog call returns right now
-- =====================================================================
do $diagnose$
declare v_json jsonb;
begin
  if pg_catalog.to_regprocedure('public.thetieguy_store_catalog_v3(integer,integer,text,text,text)') is null then
    raise notice 'RESULT: the catalog function is MISSING — the store SQL migrations have not been applied to this project. That alone is why the site shows no products (its /api/catalog returns HTTP 503).';
    return;
  end if;
  begin
    execute $q$select public.thetieguy_store_catalog_v3(1, 24, 'All', '', 'featured')$q$ into v_json;
    raise notice 'RESULT: catalog call succeeded — total_count=%, availability=%, storefront_row_present=%',
      coalesce(v_json->>'total_count', 'null'),
      coalesce(v_json->'business'->>'availability', 'missing'),
      coalesce((v_json->'storefront') is not null, false);
    raise notice 'RESULT: first product names the store would receive: %',
      coalesce((select pg_catalog.string_agg(value->>'name', ' | ')
                             from pg_catalog.jsonb_array_elements(v_json->'products')), '(none)');
  exception when others then
    raise notice 'RESULT: the catalog call FAILED with: % — the store will show "temporarily unavailable" (HTTP 503) until this is fixed.', sqlerrm;
  end;
end;
$diagnose$;

-- =====================================================================
-- 4) One-line verdict
-- =====================================================================
select case
         when pg_catalog.to_regprocedure('public.thetieguy_store_catalog_v3(integer,integer,text,text,text)') is null
           then 'MIGRATIONS NOT APPLIED — apply 20260930_online_store_paystack.sql then 20261001_store_merchandising.sql.'
         when not pg_catalog.has_function_privilege('anon',
              'public.thetieguy_store_catalog_v3(integer,integer,text,text,text)', 'EXECUTE')
           then 'RPC EXISTS BUT anon CANNOT EXECUTE IT — the store gets HTTP 401/403; re-run the migration grants.'
         when (select pg_catalog.count(*) from public.settings) <> 1
           then 'SETTINGS ROW PROBLEM — the store needs exactly one row in public.settings.'
         when (select pg_catalog.count(*) from public.products where active is true) = 0
           then 'NO ACTIVE PRODUCTS — every product is switched off (active = false) or the table is empty.'
         else 'STORE-SIDE DATA LOOKS FINE — if the live site is still empty, the store project is using different Supabase keys/URL or an old deployment.'
       end as verdict;
