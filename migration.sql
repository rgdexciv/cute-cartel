-- Cute Cartel: accounts schema (profiles, addresses, orders, items, tracking) + RLS

-- ============ profiles ============
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  phone text,
  sakura_points integer not null default 0,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

create policy "own profile select" on public.profiles for select using (auth.uid() = id);
create policy "own profile update" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- auto-create profile on signup
create function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', ''));
  return new;
end;
$$;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- ============ addresses ============
create table public.addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  label text,
  recipient text,
  line1 text,
  line2 text,
  city text,
  region text,
  postal text,
  country text default 'Philippines',
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.addresses enable row level security;
create policy "own addresses" on public.addresses for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============ orders ============
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  order_no text not null,
  status text not null default 'placed',
  total_cents integer not null default 0,
  placed_at timestamptz not null default now()
);
alter table public.orders enable row level security;
create policy "own orders" on public.orders for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============ order_items ============
create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_name text not null,
  emoji text,
  qty integer not null default 1,
  price_cents integer not null default 0
);
alter table public.order_items enable row level security;
create policy "own order items" on public.order_items for all
  using (exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()))
  with check (exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()));

-- ============ tracking_events ============
create table public.tracking_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  status text not null,
  note text,
  location text,
  happened_at timestamptz not null default now()
);
alter table public.tracking_events enable row level security;
create policy "own tracking" on public.tracking_events for all
  using (exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()))
  with check (exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()));

-- ============ demo seed RPC ============
-- idempotent: seeds sample orders for the calling user only if they have none
create function public.seed_demo_orders()
returns void language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  o1 uuid; o2 uuid; o3 uuid;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from public.orders where user_id = uid) then return; end if;

  -- order 1: delivered
  insert into public.orders (user_id, order_no, status, total_cents, placed_at)
    values (uid, 'CC-1042', 'delivered', 4890, now() - interval '18 days') returning id into o1;
  insert into public.order_items (order_id, product_name, emoji, qty, price_cents) values
    (o1, 'Sakura Plush Keychain', '🌸', 2, 1290),
    (o1, 'Matcha Lip Balm', '🍵', 1, 2310);
  insert into public.tracking_events (order_id, status, note, location, happened_at) values
    (o1, 'placed', 'Order placed', 'Online', now() - interval '18 days'),
    (o1, 'shipped', 'Left warehouse', 'Tokyo, JP', now() - interval '16 days'),
    (o1, 'in_transit', 'Cleared customs', 'Manila, PH', now() - interval '14 days'),
    (o1, 'delivered', 'Delivered to doorstep', 'Your address', now() - interval '12 days');

  -- order 2: in transit
  insert into public.orders (user_id, order_no, status, total_cents, placed_at)
    values (uid, 'CC-1177', 'in_transit', 6750, now() - interval '5 days') returning id into o2;
  insert into public.order_items (order_id, product_name, emoji, qty, price_cents) values
    (o2, 'Mochi Squish Set', '🍡', 1, 3450),
    (o2, 'Cloud Cat Socks', '🐱', 3, 1100);
  insert into public.tracking_events (order_id, status, note, location, happened_at) values
    (o2, 'placed', 'Order placed', 'Online', now() - interval '5 days'),
    (o2, 'shipped', 'Left warehouse', 'Tokyo, JP', now() - interval '3 days'),
    (o2, 'in_transit', 'In transit to PH', 'In flight ✈️', now() - interval '1 day');

  -- order 3: just placed
  insert into public.orders (user_id, order_no, status, total_cents, placed_at)
    values (uid, 'CC-1203', 'placed', 2990, now() - interval '6 hours') returning id into o3;
  insert into public.order_items (order_id, product_name, emoji, qty, price_cents) values
    (o3, 'Strawberry Milk Pin', '🍓', 1, 990),
    (o3, 'Bunny Tote Bag', '🐰', 1, 2000);
  insert into public.tracking_events (order_id, status, note, location, happened_at) values
    (o3, 'placed', 'Order placed', 'Online', now() - interval '6 hours');

  -- welcome points
  update public.profiles set sakura_points = 120 where id = uid;
end;
$$;
-- hardening: handle_new_user is trigger-only; seed is authenticated-only
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.seed_demo_orders() from public, anon;
grant execute on function public.seed_demo_orders() to authenticated;
