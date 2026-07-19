-- Cute Cartel: admin access to orders + payment status
--
-- The customer-facing schema in migration.sql only ever lets a signed-in person
-- see their own rows. The admin panel needs to read every order, so this adds
-- admin policies alongside the existing "own row" ones. Postgres ORs multiple
-- permissive policies together, so customers keep exactly the access they had.

-- ============ admin predicate ============
-- Same rule the products policies already use, factored out so the four order
-- tables below cannot drift apart. aal2 means the session cleared 2FA.
create or replace function public.is_admin()
returns boolean
language sql
stable
set search_path = public
as $$
  select auth.uid() = '6e1d2e5d-5db4-47f6-904b-75f3ea385e48'::uuid
     and (auth.jwt() ->> 'aal') = 'aal2';
$$;

-- ============ payment status ============
-- No payment provider is wired up yet; the admin marks this by hand.
alter table public.orders
  add column payment_status text not null default 'unpaid';

alter table public.orders
  add constraint orders_payment_status_check
  check (payment_status in ('unpaid', 'paid', 'refunded'));

-- Fulfilment status shares the vocabulary the customer tracking page renders.
alter table public.orders
  add constraint orders_status_check
  check (status in ('placed', 'shipped', 'in_transit', 'delivered', 'cancelled'));

-- ============ admin policies ============
create policy "admin reads all orders" on public.orders
  for select using (public.is_admin());
create policy "admin updates all orders" on public.orders
  for update using (public.is_admin()) with check (public.is_admin());

create policy "admin reads all order items" on public.order_items
  for select using (public.is_admin());

create policy "admin reads all tracking" on public.tracking_events
  for select using (public.is_admin());
create policy "admin writes tracking" on public.tracking_events
  for insert with check (public.is_admin());

-- Needed for the Customer column: the admin resolves a user_id to a name.
create policy "admin reads all profiles" on public.profiles
  for select using (public.is_admin());
