-- Athena / @thetieguy Supabase schema
-- Run in the Supabase SQL Editor as a project administrator.
-- No public/anonymous read or write policies are created for business data.
create extension if not exists pgcrypto;

create table if not exists public.staff_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner', 'staff')),
  created_at timestamptz not null default now()
);

create or replace function public.is_staff(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff_users where user_id = p_user_id);
$$;
revoke all on function public.is_staff(uuid) from public;
grant execute on function public.is_staff(uuid) to authenticated, service_role;

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  phone text not null unique check (length(trim(phone)) >= 9),
  notes text not null default '',
  first_contacted_at timestamptz not null default now(),
  last_contacted_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  status text not null default 'active' check (status in ('active', 'needs_attention', 'closed')),
  handler text not null default 'ai' check (handler in ('ai', 'human')),
  topic text not null default 'other' check (topic in ('product', 'payment', 'delivery', 'cancellation', 'refund', 'other')),
  unread_count integer not null default 0 check (unread_count >= 0),
  takeover_count integer not null default 0 check (takeover_count >= 0),
  unanswered_count integer not null default 0 check (unanswered_count >= 0),
  last_message_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete restrict,
  sender text not null check (sender in ('customer', 'athena', 'human', 'system')),
  body text not null check (length(trim(body)) > 0),
  delivery_status text not null default 'received' check (delivery_status in ('received', 'queued', 'sending', 'sent', 'failed')),
  provider_message_id text,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  category text not null default 'Other',
  price numeric(12,2) not null check (price > 0),
  stock integer not null default 0 check (stock >= 0),
  sizes text[] not null default array['One size']::text[],
  description text not null default '',
  image_url text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default ('TG-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  customer_id uuid not null references public.customers(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  size text not null default 'One size',
  quantity integer not null default 1 check (quantity > 0),
  amount numeric(12,2) not null check (amount >= 0),
  status text not null default 'new' check (status in ('new','payment_pending','paid','ready','delivered','completed','cancelled')),
  payment_status text not null default 'pending' check (payment_status in ('pending','confirmed','rejected')),
  fulfillment_method text not null default 'pickup' check (fulfillment_method in ('pickup','delivery')),
  source text not null default 'manual' check (source in ('athena','manual')),
  payment_reference text not null default '',
  paid_at timestamptz,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  type text not null default 'other' check (type in ('ai','delivery','handoff','other')),
  title text not null,
  description text not null default '',
  entity_type text not null default '' check (entity_type in ('conversation','order','product','')),
  entity_id text not null default '',
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.knowledge_entries (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) > 0),
  category text not null default 'General',
  content text not null check (length(trim(content)) > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.settings (
  id text primary key default 'main' check (id = 'main'),
  business_name text not null default '@thetieguy',
  ai_name text not null default 'Athena',
  whatsapp_number text not null default '',
  business_location text not null default '',
  opening_hours text not null default '',
  delivery_areas text not null default '',
  payment_number text not null default '',
  payment_instructions text not null default '',
  human_support_number text not null default '',
  ai_personality text not null default 'Warm, helpful, concise, and honest about stock and payments.',
  ai_greeting text not null default 'Hi! Welcome to @thetieguy. I am Athena. How can I help you today?',
  business_description text not null default '',
  current_promotions text not null default '',
  product_information text not null default 'Only offer active, in-stock products from the available products view.',
  delivery_information text not null default '',
  frequently_asked_questions text not null default 'Hand off questions you cannot answer. A human confirms payments.',
  ai_active boolean not null default false, -- safe until n8n + policies are configured
  availability text not null default 'normal' check (availability in ('normal','limited','not_taking','closed')),
  unavailable_message text not null default 'We are currently not taking new orders. Please check back soon.',
  availability_start timestamptz,
  availability_end timestamptz,
  auto_resume boolean not null default true,
  theme_palette text not null default 'wine' check (theme_palette in ('wine','burgundy','rose','slate','olive','taupe','purple')),
  theme_mode text not null default 'light' check (theme_mode in ('light','dark')),
  font_choice text not null default 'DM Sans' check (font_choice in ('DM Sans','Inter','Manrope','Plus Jakarta Sans','Caveat','Patrick Hand','Kalam','Dancing Script')),
  updated_at timestamptz not null default now()
);
insert into public.settings (id) values ('main') on conflict (id) do nothing;

create index if not exists customers_phone_idx on public.customers(phone);
create index if not exists conversations_customer_idx on public.conversations(customer_id, last_message_at desc);
create index if not exists conversations_status_idx on public.conversations(status, handler);
create index if not exists messages_thread_idx on public.messages(conversation_id, created_at);
create unique index if not exists messages_provider_id_unique on public.messages(provider_message_id) where provider_message_id is not null;
create index if not exists messages_outbound_idx on public.messages(created_at) where sender = 'human' and delivery_status in ('queued','sending');
create index if not exists orders_customer_idx on public.orders(customer_id, created_at desc);
create index if not exists orders_payment_idx on public.orders(payment_status, created_at desc);
create index if not exists orders_paid_idx on public.orders(paid_at) where payment_status = 'confirmed';
create index if not exists notifications_unread_idx on public.notifications(created_at desc) where is_read = false;

-- Timestamps are server-owned; list/order history is retained for audit.
create or replace function public.touch_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;
drop trigger if exists products_updated_at on public.products;
create trigger products_updated_at before update on public.products for each row execute function public.touch_updated_at();
drop trigger if exists orders_updated_at on public.orders;
create trigger orders_updated_at before update on public.orders for each row execute function public.touch_updated_at();
drop trigger if exists knowledge_updated_at on public.knowledge_entries;
create trigger knowledge_updated_at before update on public.knowledge_entries for each row execute function public.touch_updated_at();
drop trigger if exists settings_updated_at on public.settings;
create trigger settings_updated_at before update on public.settings for each row execute function public.touch_updated_at();

-- Customer messages advance the inbox clock and unread count automatically.
create or replace function public.bump_conversation_on_message() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.conversations
  set last_message_at = greatest(last_message_at, new.created_at),
      unread_count = unread_count + case when new.sender = 'customer' then 1 else 0 end
  where id = new.conversation_id;
  update public.customers
  set last_contacted_at = greatest(last_contacted_at, new.created_at)
  where id = (select customer_id from public.conversations where id = new.conversation_id);
  return new;
end; $$;
drop trigger if exists message_advance_thread on public.messages;
create trigger message_advance_thread after insert on public.messages for each row execute function public.bump_conversation_on_message();

-- A screenshot or an AI message must never confirm money. Only signed-in staff can
-- change a payment to 'confirmed'. Staff cannot silently reverse a confirmation.
create or replace function public.guard_payment_confirmation() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.payment_status = 'confirmed' then
      raise exception 'Create an order as pending; a signed-in human must verify it afterwards';
    end if;
    new.paid_at := null;
  else
    if old.payment_status = 'confirmed' and new.payment_status <> 'confirmed' then
      raise exception 'Confirmed payments cannot be reversed here; reconcile refunds separately';
    end if;
    if new.payment_status = 'confirmed' and old.payment_status is distinct from new.payment_status then
      if not public.is_staff(auth.uid()) then
        raise exception 'Payment confirmation requires signed-in staff';
      end if;
      new.paid_at := now();
    elsif new.payment_status = 'confirmed' then
      new.paid_at := old.paid_at; -- do not let later edits rewrite sales history
    else
      new.paid_at := null;
    end if;
    if old.payment_status = 'confirmed'
      and (old.product_id is distinct from new.product_id or old.quantity is distinct from new.quantity or old.amount is distinct from new.amount) then
      raise exception 'Paid order items and amount cannot be edited';
    end if;
  end if;
  if new.payment_status <> 'confirmed' and new.status in ('paid','ready','delivered','completed') then
    raise exception 'Verify the payment before moving the order past payment pending';
  end if;
  if new.payment_status = 'confirmed' and new.status = 'cancelled' then
    raise exception 'Reconcile a refund before cancelling a paid order';
  end if;
  return new;
end; $$;
drop trigger if exists verify_payment_by_staff on public.orders;
create trigger verify_payment_by_staff before insert or update on public.orders for each row execute function public.guard_payment_confirmation();

-- Stock is decremented only when a human verifies payment, in the SAME transaction.
-- If not enough stock remains, confirmation fails and the payment stays pending.
create or replace function public.decrement_stock_on_payment() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.payment_status = 'confirmed' and old.payment_status is distinct from new.payment_status then
    update public.products set stock = stock - new.quantity
    where id = new.product_id and stock >= new.quantity;
    if not found then raise exception 'Insufficient stock to confirm this order. Check and update inventory first.'; end if;
  end if;
  return new;
end; $$;
drop trigger if exists order_paid_decrement_stock on public.orders;
create trigger order_paid_decrement_stock after update on public.orders for each row execute function public.decrement_stock_on_payment();

-- n8n should use these views rather than guessing availability/stock.
-- Effective availability resolves automatically even if no dashboard is open.
create or replace view public.athena_runtime_context with (security_invoker = true) as
  select s.*,
    case when s.availability <> 'normal' and s.availability_start is not null and s.availability_start > now() then 'normal'
         when s.availability <> 'normal' and s.auto_resume and s.availability_end is not null and s.availability_end <= now() then 'normal'
         else s.availability end as effective_availability
  from public.settings s;
create or replace view public.athena_available_products with (security_invoker = true) as
  select id, name, category, price, stock, sizes, description, image_url, updated_at
  from public.products where active = true and stock > 0;
create or replace view public.athena_knowledge with (security_invoker = true) as
  select id, title, category, content, updated_at
  from public.knowledge_entries where is_active = true;

-- Check this immediately before n8n sends an Athena response. Not a substitute
-- for checking again immediately before the actual WhatsApp API request.
create or replace function public.athena_can_reply(p_conversation_id uuid)
returns boolean language sql stable security invoker set search_path = '' as $$
  select coalesce((select s.ai_active and c.handler = 'ai' and c.status <> 'closed'
    from public.conversations c cross join public.settings s
    where c.id = p_conversation_id and s.id = 'main'), false);
$$;

-- Optional outbound queue: the dashboard inserts 'human' messages as queued;
-- n8n with a SERVICE ROLE token atomically claims them, sends WhatsApp, then
-- updates delivery_status to 'sent' (or 'failed'). No public user can call this.
create or replace function public.claim_human_outbound(batch_size integer default 20)
returns setof public.messages language plpgsql security definer set search_path = '' as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the n8n service role can claim outbound WhatsApp messages';
  end if;
  return query
  with picked as (
    select id from public.messages
    where sender = 'human'
      and (delivery_status = 'queued' or (delivery_status = 'sending' and claimed_at < now() - interval '10 minutes'))
    order by created_at asc
    for update skip locked
    limit least(greatest(batch_size, 1), 50)
  )
  update public.messages m set delivery_status = 'sending', claimed_at = now()
  from picked where m.id = picked.id returning m.*;
end; $$;
revoke all on function public.claim_human_outbound(integer) from public, anon, authenticated;
grant execute on function public.claim_human_outbound(integer) to service_role;
grant execute on function public.athena_can_reply(uuid) to authenticated, service_role;

alter table public.staff_users enable row level security;
alter table public.customers enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.notifications enable row level security;
alter table public.knowledge_entries enable row level security;
alter table public.settings enable row level security;

drop policy if exists staff_can_read_self on public.staff_users;
create policy staff_can_read_self on public.staff_users for select to authenticated using (user_id = (select auth.uid()));

-- Only Auth users explicitly granted access in staff_users can use the browser app.
do $$ declare item text; begin
  foreach item in array array['customers','conversations','messages','products','orders','notifications','knowledge_entries','settings'] loop
    execute format('drop policy if exists dashboard_staff_all on public.%I', item);
    execute format('create policy dashboard_staff_all on public.%I for all to authenticated using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())))', item);
  end loop;
end $$;

grant usage on schema public to authenticated, service_role;
grant select on public.staff_users to authenticated;
grant select, insert, update, delete on public.customers, public.conversations, public.messages, public.products, public.orders, public.notifications, public.knowledge_entries, public.settings to authenticated;
revoke delete on public.orders, public.messages from authenticated;
grant all on public.staff_users, public.customers, public.conversations, public.messages, public.products, public.orders, public.notifications, public.knowledge_entries, public.settings to service_role;
grant select on public.athena_runtime_context, public.athena_available_products, public.athena_knowledge to authenticated, service_role;

-- Public product images: read publicly, upload/replace/remove only as signed-in staff.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 8388608, array['image/png','image/jpeg','image/webp','image/gif'])
on conflict (id) do nothing;
drop policy if exists product_images_staff_read on storage.objects;
create policy product_images_staff_read on storage.objects for select to authenticated
  using (bucket_id = 'product-images' and public.is_staff((select auth.uid())));
drop policy if exists product_images_staff_upload on storage.objects;
create policy product_images_staff_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and public.is_staff((select auth.uid())));
drop policy if exists product_images_staff_update on storage.objects;
create policy product_images_staff_update on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and public.is_staff((select auth.uid())))
  with check (bucket_id = 'product-images' and public.is_staff((select auth.uid())));
drop policy if exists product_images_staff_delete on storage.objects;
create policy product_images_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and public.is_staff((select auth.uid())));

-- Subscribe to database changes for near-real-time inbox/order refresh.
do $$ declare item text; begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach item in array array['customers','conversations','messages','products','orders','notifications','knowledge_entries','settings'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = item) then
        execute format('alter publication supabase_realtime add table public.%I', item);
      end if;
    end loop;
  end if;
end $$;

-- IMPORTANT: create your own Supabase Auth user (Dashboard > Authentication > Users),
-- then grant them access using a separate statement (replace the email):
-- insert into public.staff_users (user_id, role)
-- select id, 'owner' from auth.users where email = 'you@example.com'
-- on conflict (user_id) do nothing;

-- Fresh installs include the same additive customer/WhatsApp/delivery upgrade.
-- EXISTING projects: run ONLY supabase/migrations/20260925_customer_whatsapp_deliveries.sql.
-- The following block is kept verbatim in that migration for safe live rollout.
-- Athena / @thetieguy: customer-specific identifiers, WhatsApp thread lookup,
-- order customer snapshots, and bidirectionally synchronized delivery statuses.
-- Run ONLY in the intended Supabase project's SQL Editor as a project admin,
-- BEFORE deploying the matching frontend. Back up business data first.
-- Additive and repeatable: existing UUIDs, messages, orders, and historic threads
-- remain in place. Unknown external IDs are left NULL, NEVER invented.
begin;

do $$
begin
  if to_regclass('public.customers') is null or to_regclass('public.conversations') is null
     or to_regclass('public.orders') is null or to_regclass('public.staff_users') is null then
    raise exception 'Athena base schema is missing. Do not run this migration on an unrelated project.';
  end if;
  if to_regclass('public.deliveries') is not null and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'deliveries' and column_name = 'delivery_status'
  ) then
    raise exception 'An unrelated public.deliveries table exists. Inspect and map it before continuing.';
  end if;
end $$;

alter table public.customers
  add column if not exists phone_number_id text,
  add column if not exists whatsapp_id text;
alter table public.conversations add column if not exists whatsapp_id text;
alter table public.orders
  add column if not exists customer_name text,
  add column if not exists customer_phone text,
  add column if not exists delivery_status text;

-- These are DIFFERENT IDs. phone_number_id belongs to one customer; it is NOT
-- the shared WhatsApp Business sender ID in webhook metadata.phone_number_id.
-- Nullable during legacy backfill, unique and nonblank whenever provided.
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.customers'::regclass and conname = 'customers_phone_number_id_nonblank') then
    alter table public.customers add constraint customers_phone_number_id_nonblank
      check (phone_number_id is null or length(btrim(phone_number_id)) > 0);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.customers'::regclass and conname = 'customers_whatsapp_id_nonblank') then
    alter table public.customers add constraint customers_whatsapp_id_nonblank
      check (whatsapp_id is null or length(btrim(whatsapp_id)) > 0);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.conversations'::regclass and conname = 'conversations_whatsapp_id_nonblank') then
    alter table public.conversations add constraint conversations_whatsapp_id_nonblank
      check (whatsapp_id is null or length(btrim(whatsapp_id)) > 0);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.customers'::regclass and conname = 'customers_whatsapp_id_key') then
    alter table public.customers add constraint customers_whatsapp_id_key unique (whatsapp_id);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.conversations'::regclass and conname = 'conversations_whatsapp_id_key') then
    alter table public.conversations add constraint conversations_whatsapp_id_key unique (whatsapp_id);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.conversations'::regclass and conname = 'conversations_whatsapp_id_fkey') then
    alter table public.conversations add constraint conversations_whatsapp_id_fkey
      foreign key (whatsapp_id) references public.customers(whatsapp_id)
      on update cascade on delete restrict;
  end if;
end $$;
create unique index if not exists customers_phone_number_id_unique
  on public.customers (phone_number_id) where phone_number_id is not null;

-- Safe legacy backfill: attach only an unambiguous single existing thread.
-- Multiple historical threads stay untouched so no messages are reassigned.
update public.conversations as t set whatsapp_id = c.whatsapp_id
from public.customers as c
where t.customer_id = c.id and c.whatsapp_id is not null and t.whatsapp_id is null
  and (select count(*) from public.conversations as other where other.customer_id = c.id) = 1;

create or replace function public.require_customer_whatsapp_thread()
returns trigger language plpgsql set search_path = '' as $$
declare customer_whatsapp_id text;
begin
  select c.whatsapp_id into customer_whatsapp_id from public.customers c where c.id = new.customer_id;
  if customer_whatsapp_id is null then
    raise exception 'Set the customer whatsapp_id before creating or linking a conversation';
  end if;
  if new.whatsapp_id is null then new.whatsapp_id := customer_whatsapp_id; end if;
  if new.whatsapp_id is distinct from customer_whatsapp_id then
    raise exception 'Conversation whatsapp_id must match its customer whatsapp_id';
  end if;
  return new;
end; $$;
drop trigger if exists conversation_require_whatsapp_id on public.conversations;
create trigger conversation_require_whatsapp_id
  before insert or update of customer_id, whatsapp_id on public.conversations
  for each row execute function public.require_customer_whatsapp_thread();

-- When a legacy customer's real wa_id is entered later, link their most recent
-- open thread (or most recent closed one). Older threads retain UUID links and
-- NULL wa_id until a human reviews/archives them. Updating an existing wa_id
-- cascades through the FK, so the linked conversation always follows it.
create or replace function public.attach_legacy_whatsapp_thread()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.whatsapp_id is null and new.whatsapp_id is not null then
    update public.conversations set whatsapp_id = new.whatsapp_id
    where id = (
      select t.id from public.conversations t
      where t.customer_id = new.id and t.whatsapp_id is null
      order by case when t.status = 'closed' then 1 else 0 end,
               t.last_message_at desc, t.id desc limit 1
    ) and not exists (
      select 1 from public.conversations t
      where t.customer_id = new.id and t.whatsapp_id is not null
    );
  end if;
  return new;
end; $$;
drop trigger if exists customers_attach_legacy_thread on public.customers;
create trigger customers_attach_legacy_thread after update of whatsapp_id on public.customers
  for each row execute function public.attach_legacy_whatsapp_thread();

-- Backfill legacy columns without falsifying their original updated_at dates.
-- Preserve whether the existing timestamp trigger was enabled (including
-- ALWAYS/REPLICA mode); restore it in this same transaction after backfill.
do $$
declare mode char;
begin
  select t.tgenabled into mode from pg_trigger t
  where t.tgrelid = 'public.orders'::regclass and t.tgname = 'orders_updated_at';
  if mode in ('O','A','R') then
    perform set_config('athena.migration_orders_updated_at_mode', mode, true);
    alter table public.orders disable trigger orders_updated_at;
  end if;
end $$;

-- Capture real customer name/phone on existing orders without changing the
-- customer foreign key or re-writing past purchases when a profile changes.
update public.orders as o set
  customer_name = coalesce(nullif(o.customer_name, ''), c.name),
  customer_phone = coalesce(nullif(o.customer_phone, ''), c.phone)
from public.customers as c
where o.customer_id = c.id and (o.customer_name is null or o.customer_name = ''
                              or o.customer_phone is null or o.customer_phone = '');
alter table public.orders alter column customer_name set not null;
alter table public.orders alter column customer_phone set not null;

-- Delivery status is distinct from payment status and order progress.
-- Existing delivery orders receive a status based on their known order stage;
-- do not assert that a merely "ready" package was actually delivered.
update public.orders set delivery_status = case
  when fulfillment_method = 'pickup' then 'not_applicable'
  when status = 'cancelled' then 'cancelled'
  when status in ('delivered', 'completed') then 'delivered'
  else 'pending'
end where delivery_status is null;
alter table public.orders alter column delivery_status set default 'not_applicable';
alter table public.orders alter column delivery_status set not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.orders'::regclass and conname = 'orders_delivery_status_check') then
    alter table public.orders add constraint orders_delivery_status_check
      check (delivery_status in ('not_applicable','pending','scheduled','out_for_delivery','delivered','failed','cancelled'));
  end if;
end $$;

create table if not exists public.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete restrict,
  delivery_status text not null default 'pending'
    check (delivery_status in ('not_applicable','pending','scheduled','out_for_delivery','delivered','failed','cancelled')),
  delivery_location text not null default '',
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists deliveries_status_idx on public.deliveries(delivery_status, updated_at desc);

-- Seed tracking rows for past delivery orders, preserving already recorded rows.
insert into public.deliveries (order_id, delivery_status, delivered_at)
select o.id, o.delivery_status, case when o.delivery_status = 'delivered' then o.updated_at else null end
from public.orders o where o.fulfillment_method = 'delivery'
on conflict (order_id) do nothing;
-- When deliveries existed before the migration, prefer its existing status.
update public.orders o set delivery_status = d.delivery_status
from public.deliveries d where d.order_id = o.id and o.fulfillment_method = 'delivery'
  and o.delivery_status is distinct from d.delivery_status;
do $$
declare mode text := current_setting('athena.migration_orders_updated_at_mode', true);
begin
  if mode = 'O' then alter table public.orders enable trigger orders_updated_at;
  elsif mode = 'A' then alter table public.orders enable always trigger orders_updated_at;
  elsif mode = 'R' then alter table public.orders enable replica trigger orders_updated_at;
  end if;
end $$;

-- New orders receive a snapshot; subsequent customer profile edits do not
-- change history. The database chooses the initial delivery status.
create or replace function public.capture_order_customer_and_delivery()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    select c.name, c.phone into new.customer_name, new.customer_phone
    from public.customers c where c.id = new.customer_id;
  elsif new.customer_id is distinct from old.customer_id then
    select c.name, c.phone into new.customer_name, new.customer_phone
    from public.customers c where c.id = new.customer_id;
  end if;
  if new.fulfillment_method = 'pickup' then
    new.delivery_status := 'not_applicable';
  elsif new.delivery_status is null or new.delivery_status = 'not_applicable' then
    new.delivery_status := 'pending';
  end if;
  if new.fulfillment_method = 'delivery' then
    -- Derive a milestone only when order progress/fulfillment actually changes.
    -- Direct edits to either delivery_status field remain bidirectional.
    if tg_op = 'INSERT' then
      if new.status = 'cancelled' then new.delivery_status := 'cancelled'; end if;
      if new.status in ('delivered','completed') then new.delivery_status := 'delivered'; end if;
    elsif new.status is distinct from old.status or new.fulfillment_method is distinct from old.fulfillment_method then
      if new.status = 'cancelled' then new.delivery_status := 'cancelled'; end if;
      if new.status in ('delivered','completed') then new.delivery_status := 'delivered'; end if;
    end if;
    if new.delivery_status = 'delivered' and new.payment_status <> 'confirmed' then
      raise exception 'A delivery cannot be marked delivered before a staff member verifies payment';
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists orders_capture_customer_delivery on public.orders;
create trigger orders_capture_customer_delivery before insert or update on public.orders
  for each row execute function public.capture_order_customer_and_delivery();

create or replace function public.stamp_delivery()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.delivery_status = 'delivered' then new.delivered_at := coalesce(new.delivered_at, now()); end if;
  else
    if new.order_id is distinct from old.order_id then
      raise exception 'A delivery cannot be reassigned to another order';
    end if;
    if new.delivery_status = 'delivered' and old.delivery_status is distinct from 'delivered' then
      new.delivered_at := coalesce(new.delivered_at, now());
    end if;
    new.updated_at := now();
  end if;
  return new;
end; $$;
drop trigger if exists deliveries_stamp on public.deliveries;
create trigger deliveries_stamp before insert or update on public.deliveries
  for each row execute function public.stamp_delivery();

-- Only synchronize the *delivery_status* fields. Do not auto-confirm payments,
-- advance paid order stages, decrement stock, or delete a delivery record.
-- WHERE IS DISTINCT FROM prevents recursive trigger loops.
create or replace function public.sync_delivery_from_order()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.fulfillment_method = 'delivery' then
    insert into public.deliveries (order_id, delivery_status)
      values (new.id, new.delivery_status)
    on conflict (order_id) do update set delivery_status = excluded.delivery_status
      where public.deliveries.delivery_status is distinct from excluded.delivery_status;
  else
    update public.deliveries set delivery_status = 'not_applicable'
    where order_id = new.id and delivery_status is distinct from 'not_applicable';
  end if;
  return new;
end; $$;
drop trigger if exists orders_sync_delivery on public.orders;
create trigger orders_sync_delivery
  after insert or update of fulfillment_method, status, delivery_status on public.orders
  for each row execute function public.sync_delivery_from_order();

create or replace function public.sync_order_from_delivery()
returns trigger language plpgsql set search_path = '' as $$
declare method text;
begin
  select o.fulfillment_method into method from public.orders o where o.id = new.order_id;
  if method <> 'delivery' and new.delivery_status <> 'not_applicable' then
    raise exception 'Pickup orders cannot have an active delivery status';
  end if;
  update public.orders set delivery_status = new.delivery_status
  where id = new.order_id and delivery_status is distinct from new.delivery_status;
  return new;
end; $$;
drop trigger if exists deliveries_sync_order on public.deliveries;
create trigger deliveries_sync_order after insert or update of delivery_status on public.deliveries
  for each row execute function public.sync_order_from_delivery();

alter table public.deliveries enable row level security;
drop policy if exists dashboard_staff_all on public.deliveries;
create policy dashboard_staff_all on public.deliveries for all to authenticated
  using (public.is_staff((select auth.uid())))
  with check (public.is_staff((select auth.uid())));
grant select, insert, update on public.deliveries to authenticated;
revoke delete on public.deliveries from authenticated;
grant all on public.deliveries to service_role;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') and
     not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'deliveries') then
    alter publication supabase_realtime add table public.deliveries;
  end if;
end $$;
notify pgrst, 'reload schema';
commit;

-- After running: check for customers missing their real IDs, and legacy threads
-- that still need a WhatsApp ID. See supabase/verify_customer_delivery_migration.sql.
