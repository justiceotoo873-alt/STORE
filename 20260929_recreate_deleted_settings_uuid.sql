-- @thetieguy / Athena: RECREATE a DELETED public.settings table (fresh values).
-- Use ONLY when public.settings was dropped. This is NOT the in-place migration.
-- Paste the whole file into the SQL Editor of the intended Supabase project as
-- administrator. Do not run the project's full schema.sql on an existing DB.
-- Previously deleted values cannot be reconstructed: use a backup/export to
-- restore real contact, payment, AI, and other settings after this finishes.
-- No customers, products, orders, or other business rows are deleted/edited.
-- The only other objects touched: known Athena/storefront functions if present,
-- the missing Athena settings view, grants/RLS for this new table, and Realtime.
-- A failed statement rolls back the WHOLE transaction. Rerunning after success
-- intentionally aborts rather than silently changing an existing table.

BEGIN;
SET LOCAL lock_timeout = '10s';

DO $preflight$
BEGIN
  IF pg_catalog.to_regclass('public.settings') IS NOT NULL THEN
    RAISE EXCEPTION 'public.settings already exists; stopped to protect it. Do not run this recreate script on an existing table.';
  END IF;
  IF pg_catalog.to_regclass('public.staff_users') IS NULL
     OR pg_catalog.to_regprocedure('public.is_staff(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Expected existing staff_users table and is_staff(uuid) function. Inspect this project before recreating settings.';
  END IF;
  IF NOT pg_catalog.has_function_privilege('authenticated', 'public.is_staff(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated cannot call public.is_staff(uuid). Review staff permissions before adding a settings policy.';
  END IF;
  IF pg_catalog.to_regclass('public.athena_runtime_context') IS NOT NULL THEN
    RAISE EXCEPTION 'A pre-existing athena_runtime_context view/table needs review; refusing to overwrite it.';
  END IF;
END;
$preflight$;

-- Exactly one row is possible: UUID is the PK; singleton_key prevents a
-- second settings row even when an administrator inserts manually.
-- The old numeric ID is UNKNOWN because the table was deleted. Do not invent
-- one. If you later recover it from a backup, legacy_settings_id is available.
CREATE TABLE public.settings (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  legacy_settings_id bigint UNIQUE,
  singleton_key boolean NOT NULL DEFAULT true UNIQUE CHECK (singleton_key),

  business_name text NOT NULL DEFAULT '@thetieguy',
  ai_name text NOT NULL DEFAULT 'Athena',
  whatsapp_number text NOT NULL DEFAULT '',
  business_location text NOT NULL DEFAULT '',
  opening_hours text NOT NULL DEFAULT '',
  delivery_areas text NOT NULL DEFAULT '',
  payment_number text NOT NULL DEFAULT '',
  payment_instructions text NOT NULL DEFAULT '',
  human_support_number text NOT NULL DEFAULT '',
  ai_personality text NOT NULL DEFAULT 'Warm, helpful, concise, and honest about stock and payments.',
  ai_greeting text NOT NULL DEFAULT 'Hi! Welcome to @thetieguy. I am Athena. How can I help you today?',
  business_description text NOT NULL DEFAULT '',
  current_promotions text NOT NULL DEFAULT '',
  product_information text NOT NULL DEFAULT 'Only offer active, in-stock products from the available products view.',
  delivery_information text NOT NULL DEFAULT '',
  frequently_asked_questions text NOT NULL DEFAULT 'Hand off questions you cannot answer. A human confirms payments.',

  ai_active boolean NOT NULL DEFAULT false,
  -- The dashboard displays only Available / Unavailable. Retain the original
  -- database values to keep existing n8n and storefront availability contracts.
  availability text NOT NULL DEFAULT 'not_taking'
    CHECK (availability IN ('normal', 'not_taking')),
  unavailable_message text NOT NULL DEFAULT 'We are currently not taking new orders. Please check back soon.',
  availability_start timestamptz,
  availability_end timestamptz,
  auto_resume boolean NOT NULL DEFAULT false,

  theme_palette text NOT NULL DEFAULT 'burgundy'
    CHECK (theme_palette IN ('wine', 'burgundy', 'rose', 'slate', 'olive', 'taupe', 'purple')),
  theme_mode text NOT NULL DEFAULT 'light'
    CHECK (theme_mode IN ('light', 'dark')),
  font_choice text NOT NULL DEFAULT 'DM Sans'
    CHECK (font_choice IN ('DM Sans', 'Inter', 'Manrope', 'Plus Jakarta Sans',
                          'Caveat', 'Patrick Hand', 'Kalam', 'Dancing Script')),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

-- Keep the familiar server-side updated_at behavior without touching triggers
-- on products, orders, or other tables. The old function usually still exists
-- after DROP TABLE; recreate it only if it was removed as well.
DO $timestamp$
BEGIN
  IF pg_catalog.to_regprocedure('public.touch_updated_at()') IS NULL THEN
    EXECUTE $create$
      CREATE FUNCTION public.touch_updated_at() RETURNS trigger
      LANGUAGE plpgsql SET search_path = '' AS $body$
      BEGIN
        NEW.updated_at := pg_catalog.now();
        RETURN NEW;
      END;
      $body$;
    $create$;
  END IF;
END;
$timestamp$;

CREATE TRIGGER settings_updated_at
BEFORE UPDATE ON public.settings
FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- A newly created Supabase table can inherit default grants. Remove them
-- explicitly, then grant signed-in staff only SELECT/UPDATE. Service role is
-- for trusted backend workflows; never place that key in browser-side HTML.
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.settings FROM PUBLIC, anon, authenticated;
GRANT SELECT, UPDATE ON TABLE public.settings TO authenticated;
GRANT ALL ON TABLE public.settings TO service_role;
CREATE POLICY dashboard_staff_all ON public.settings
FOR ALL TO authenticated
USING (public.is_staff((SELECT auth.uid())))
WITH CHECK (public.is_staff((SELECT auth.uid())));

-- Recreate the original n8n-readable view if DROP TABLE ... CASCADE removed it.
-- SECURITY INVOKER means it obeys the caller's settings-table RLS. The
-- availability schedule columns remain for compatibility but start disabled.
CREATE VIEW public.athena_runtime_context WITH (security_invoker = true) AS
  SELECT s.*,
    CASE
      WHEN s.availability <> 'normal' AND s.availability_start IS NOT NULL
           AND s.availability_start > pg_catalog.now() THEN 'normal'
      WHEN s.availability <> 'normal' AND s.auto_resume
           AND s.availability_end IS NOT NULL
           AND s.availability_end <= pg_catalog.now() THEN 'normal'
      ELSE s.availability
    END AS effective_availability
  FROM public.settings AS s;
REVOKE ALL ON TABLE public.athena_runtime_context FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.athena_runtime_context TO authenticated, service_role;

INSERT INTO public.settings DEFAULT VALUES;

-- Existing functions may survive DROP TABLE and still compare id to 'main'.
-- Preserve their bodies, owners and custom grants; change ONLY that exact
-- obsolete predicate. Abort rather than blindly overwrite a different ID
-- predicate. If the original Athena function was dropped, recreate its known
-- fail-closed implementation. AI remains OFF until you explicitly enable it.
DO $functions$
DECLARE
  fn oid := pg_catalog.to_regprocedure('public.athena_can_reply(uuid)');
  catalog_fn oid := pg_catalog.to_regprocedure('public.thetieguy_public_storefront_v1()');
  body text;
BEGIN
  IF fn IS NULL THEN
    IF pg_catalog.to_regclass('public.conversations') IS NULL THEN
      RAISE NOTICE 'No conversations table: athena_can_reply(uuid) could not be restored. AI stays off; inspect the n8n workflow.';
    ELSE
      EXECUTE $create$
        CREATE FUNCTION public.athena_can_reply(p_conversation_id uuid)
        RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
        AS $body$
          SELECT COALESCE((
            SELECT s.ai_active AND c.handler = 'ai' AND c.status <> 'closed'
            FROM public.conversations AS c CROSS JOIN public.settings AS s
            WHERE c.id = p_conversation_id
              AND (SELECT pg_catalog.count(*) FROM public.settings) = 1
          ), false);
        $body$;
      $create$;
      REVOKE ALL ON FUNCTION public.athena_can_reply(uuid) FROM PUBLIC, anon;
      GRANT EXECUTE ON FUNCTION public.athena_can_reply(uuid) TO authenticated, service_role;
    END IF;
  ELSE
    SELECT pg_catalog.pg_get_functiondef(fn) INTO body;
    IF pg_catalog.strpos(body, 's.id = ''main''') > 0 THEN
      EXECUTE pg_catalog.replace(body, 's.id = ''main''',
        '(SELECT pg_catalog.count(*) FROM public.settings) = 1');
      RAISE NOTICE 'Repaired the existing athena_can_reply(uuid) old-ID filter.';
    ELSIF body ~* '\ms[.]id\M|\msettings[.]id\M' THEN
      RAISE EXCEPTION 'Existing athena_can_reply(uuid) references settings.id differently. Review its SQL; no changes committed.';
    END IF;
  END IF;

  IF catalog_fn IS NOT NULL THEN
    SELECT pg_catalog.pg_get_functiondef(catalog_fn) INTO body;
    IF pg_catalog.strpos(body, 's.id = ''main''') > 0 THEN
      EXECUTE pg_catalog.replace(body, 's.id = ''main''',
        '(SELECT pg_catalog.count(*) FROM public.settings) = 1');
      RAISE NOTICE 'Repaired the existing storefront RPC old-ID filter.';
    ELSIF body ~* '\ms[.]id\M|\msettings[.]id\M' THEN
      RAISE EXCEPTION 'Existing storefront RPC references settings.id differently. Review its SQL; no changes committed.';
    END IF;
  END IF;
END;
$functions$;

-- Re-add this recreated relation to realtime, if Supabase Realtime is enabled.
DO $realtime$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_publication_tables
                     WHERE pubname = 'supabase_realtime'
                       AND schemaname = 'public' AND tablename = 'settings') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.settings;
  END IF;
END;
$realtime$;

NOTIFY pgrst, 'reload schema';

-- Safe verification: no payment number, WhatsApp number, or private playbook.
SELECT id, business_name, ai_name, ai_active, availability,
       theme_palette, theme_mode, font_choice,
       (legacy_settings_id IS NULL) AS old_id_not_restored
FROM public.settings;
SELECT c.relrowsecurity AS rls_enabled,
       pg_catalog.has_table_privilege('anon', 'public.settings', 'SELECT') AS anon_can_read,
       (SELECT pg_catalog.count(*) FROM public.settings) AS settings_rows
FROM pg_catalog.pg_class c WHERE c.oid = 'public.settings'::regclass;
COMMIT;

-- AFTERWARD: Re-enter the real WhatsApp/payment/contact details in the staff
-- dashboard and check your n8n workflow's ID and availability assumptions.
-- The storefront RPC is patched if its exact old filter existed; if the RPC
-- itself is missing, review/run the separate storefront repair migration.
-- Never restore the old ID by guessing it or turn ai_active on until the
-- messaging workflow and manual-payment-confirmation controls are verified.
