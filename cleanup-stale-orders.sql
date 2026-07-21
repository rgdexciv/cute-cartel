-- Cute Cartel: one-time reclaim of stock held by pre-PayMongo orders
--
-- Orders CC-1300 onward were created by the old place_order, which decremented
-- stock but recorded no product_id and no expires_at. The cron sweep added in
-- migration-paymongo.sql only reclaims orders that carry a deadline, so these
-- rows hold their inventory indefinitely and need clearing by hand once.
--
-- Run the sections in order. Sections 1 and 2 only read; nothing is mutated
-- until section 3, and section 3 is written so that running it twice is
-- harmless.

-- ============ 1. what is actually stuck ============
-- Read this before anything else. If an order here was genuinely paid for out
-- of band, stop: restoring its stock would be wrong.
select o.order_no,
       o.status,
       o.payment_status,
       o.total_cents,
       o.placed_at,
       o.expires_at,
       count(oi.id) as line_count
  from public.orders o
  left join public.order_items oi on oi.order_id = o.id
 where o.payment_status = 'unpaid'
   and o.expires_at is null
 group by o.id
 order by o.placed_at;

-- ============ 2. can every line be matched back to a product ============
-- product_id is null on these rows, so the match is by name. Any line listed
-- here as unmatched cannot have its stock restored automatically and must be
-- corrected by hand in the admin panel.
select oi.id as order_item_id,
       o.order_no,
       oi.product_name,
       oi.qty,
       p.id as matched_product_id,
       case when p.id is null then 'UNMATCHED - fix by hand' else 'ok' end as status
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  left join public.products p on p.name = oi.product_name
 where o.payment_status = 'unpaid'
   and o.expires_at is null
   and oi.product_id is null
 order by o.order_no, oi.product_name;

-- ============ 3. reclaim ============
-- Only proceed once sections 1 and 2 look right. Wrapped in a transaction so a
-- failure part-way leaves stock exactly as it was.
begin;

-- Backfill product_id where the name matches exactly one product. Doing this
-- first means the restore below works off a key, and it is what makes a second
-- run a no-op: these rows stop qualifying as 'product_id is null'.
update public.order_items oi
   set product_id = p.id
  from public.products p,
       public.orders o
 where oi.order_id = o.id
   and o.payment_status = 'unpaid'
   and o.expires_at is null
   and oi.product_id is null
   and p.name = oi.product_name;

-- Give the stock back. Restricted to the same set section 1 listed: unpaid, no
-- deadline. An order that got paid or expired in the meantime is skipped.
update public.products p
   set stock = p.stock + reclaim.qty
  from (
    select oi.product_id, sum(oi.qty) as qty
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where o.payment_status = 'unpaid'
       and o.expires_at is null
       and oi.product_id is not null
     group by oi.product_id
  ) as reclaim
 where p.id = reclaim.product_id;

-- Close the orders out. This is what stops a repeat run double-restoring: after
-- it, payment_status is no longer 'unpaid' and nothing above matches them again.
insert into public.tracking_events (order_id, status, note, location)
select o.id, 'cancelled', 'Cancelled before payment was available', 'Online'
  from public.orders o
 where o.payment_status = 'unpaid'
   and o.expires_at is null;

update public.orders
   set status = 'cancelled',
       payment_status = 'expired'
 where payment_status = 'unpaid'
   and expires_at is null;

-- Check the numbers look sane, then commit. Roll back instead if they do not.
select id, name, stock from public.products order by name;

commit;
