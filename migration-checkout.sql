-- Cute Cartel: checkout
--
-- The browser may not write orders directly. products is admin-write-only under
-- RLS, so a customer cannot decrement stock from the client even in principle,
-- and any price the client sends is forgeable. Checkout therefore runs entirely
-- inside this function: it takes product ids and quantities, and derives names,
-- prices and totals from the products table itself.

-- Order numbers continue the series the demo seed used (CC-1042 … CC-1203).
create sequence if not exists public.order_no_seq start 1300;

create or replace function public.place_order(items jsonb)
returns table (order_id uuid, order_no text, total_cents integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  new_order_id uuid;
  new_order_no text;
  running_total integer := 0;
  item record;
  prod record;
begin
  if uid is null then
    raise exception 'You must be signed in to place an order.' using errcode = '42501';
  end if;

  if items is null or jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception 'Your cart is empty.' using errcode = '22023';
  end if;

  new_order_no := 'CC-' || nextval('public.order_no_seq');

  insert into public.orders (user_id, order_no, status, payment_status, total_cents)
  values (uid, new_order_no, 'placed', 'unpaid', 0)
  returning id into new_order_id;

  for item in
    -- Collapsing duplicate ids here means a cart listing the same product twice
    -- is still checked against stock once, as a single combined quantity.
    select (e ->> 'id')::uuid as product_id, sum((e ->> 'qty')::integer) as qty
    from jsonb_array_elements(items) as e
    group by 1
  loop
    if item.qty is null or item.qty < 1 then
      raise exception 'Invalid quantity.' using errcode = '22023';
    end if;

    -- FOR UPDATE serialises concurrent checkouts competing for the last unit.
    select id, name, emoji, price_cents, stock, is_active
      into prod
      from public.products
     where id = item.product_id
     for update;

    if not found or not prod.is_active then
      raise exception 'A product in your cart is no longer available.' using errcode = '22023';
    end if;

    if prod.stock < item.qty then
      raise exception 'Only % left of %.', prod.stock, prod.name using errcode = '22023';
    end if;

    insert into public.order_items (order_id, product_name, emoji, qty, price_cents)
    values (new_order_id, prod.name, prod.emoji, item.qty, prod.price_cents);

    update public.products set stock = stock - item.qty where id = prod.id;

    running_total := running_total + (prod.price_cents * item.qty);
  end loop;

  update public.orders set total_cents = running_total where id = new_order_id;

  insert into public.tracking_events (order_id, status, note, location)
  values (new_order_id, 'placed', 'Order placed', 'Online');

  return query select new_order_id, new_order_no, running_total;
end;
$$;

-- Signed-in customers only. anon has no order to attach to.
revoke execute on function public.place_order(jsonb) from public, anon;
grant execute on function public.place_order(jsonb) to authenticated;
