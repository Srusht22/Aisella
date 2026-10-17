-- Aisellia — Phase 7: orders, drafts, seller approval and the order lifecycle.
--
-- Model (Phase 3 backend-and-data-model.md §4.4, §6; Phase 1 §6.3–6.5 BR-20..BR-44):
--   * orders → order_items (name, variant, SKU and price snapshots) → order_status_events
--     (append-only, one per transition) → return_lines / cod_collections.
--   * Status changes happen only inside the api functions below, and a trigger refuses any
--     status change that is not in app.order_transitions (Phase 1 BR-30), whoever attempts it.
--   * Approval is the only way to `approved`: an end user who is the store OWNER, with a
--     confirmed email, on an order in `pending_approval`. It re-validates every line under row
--     locks and deducts stock atomically (Phase 6 E §2). service_role, anon and the AI never
--     approve: there is no other path.
--   * Totals, fees, prices and status are computed here. Values the client sends for them are
--     refused (unknown fields), never trusted.
--   * Each line records stock_deducted: the units currently taken from stock for it. Approval
--     sets it, edits move it by the difference, cancellation and restocking returns give it back
--     (written-off units stay taken).
--     Σ(order movements of a variant) = −Σ(stock_deducted of its lines), always.
--   * Same conventions as Phases 5–6: `app` tables with SELECT-only RLS, `api` SECURITY DEFINER
--     functions with the envelope, NOT_FOUND for other stores, idempotency keys, audit.

-- ---------------------------------------------------------------------------------------------
-- Order numbers (BR-35): per store, allocated in the creating transaction. The first is #1001.
-- ---------------------------------------------------------------------------------------------
alter table app.stores
  add column last_order_number integer not null default 1000 check (last_order_number >= 1000);

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- Allowed status changes (Phase 1 BR-30; Phase 3 §6.5). `via` names the only function that may
-- perform it; `system` is the automatic draft ↔ pending_approval re-evaluation after an edit.
create table app.order_transitions (
  from_status text not null,
  to_status   text not null,
  via         text not null check (via in ('system', 'approve', 'reject', 'transition', 'cancel', 'return')),
  primary key (from_status, to_status)
);
insert into app.order_transitions (from_status, to_status, via) values
  ('draft', 'pending_approval', 'system'),
  ('pending_approval', 'draft', 'system'),
  ('draft', 'rejected', 'reject'),
  ('pending_approval', 'rejected', 'reject'),
  ('pending_approval', 'approved', 'approve'),
  ('approved', 'processing', 'transition'),
  ('approved', 'dispatched', 'transition'),
  ('processing', 'dispatched', 'transition'),
  ('approved', 'cancelled', 'cancel'),
  ('processing', 'cancelled', 'cancel'),
  ('dispatched', 'delivered', 'transition'),
  ('dispatched', 'delivery_failed', 'transition'),
  ('delivery_failed', 'dispatched', 'transition'),
  ('dispatched', 'returned', 'return'),
  ('delivery_failed', 'returned', 'return');

create table app.orders (
  id                  uuid primary key default gen_random_uuid(),
  store_id            uuid not null references app.stores (id),
  number              integer not null check (number > 1000),
  status              text not null check (status in ('draft', 'pending_approval', 'rejected', 'approved',
                                                      'processing', 'dispatched', 'delivered',
                                                      'delivery_failed', 'returned', 'cancelled')),
  origin              text not null default 'manual' check (origin in ('manual', 'ai')),
  is_test             boolean not null default false,
  currency            text not null check (currency in ('IQD', 'USD')),
  -- Customer snapshot (no customer records in Phase 7, decision P7-D1).
  customer_name       text check (customer_name is null or (char_length(customer_name) between 1 and 80 and customer_name = btrim(customer_name))),
  customer_phone      text check (customer_phone is null or customer_phone ~ '^\+9647[0-9]{9}$'),
  customer_phone2     text check (customer_phone2 is null or customer_phone2 ~ '^\+9647[0-9]{9}$'),
  -- Delivery snapshot: the zone's name and fee are copied, so later zone edits never change it.
  zone_id             uuid,
  zone_name           text,
  city_text           text check (city_text is null or (char_length(city_text) between 1 and 60 and city_text = btrim(city_text))),
  area                text check (area is null or (char_length(area) between 1 and 80 and area = btrim(area))),
  landmark            text check (landmark is null or char_length(landmark) between 1 and 120),
  address_details     text check (address_details is null or char_length(address_details) between 1 and 300),
  delivery_fee        integer check (delivery_fee is null or delivery_fee between 0 and 10000000),
  delivery_fee_source text check (delivery_fee_source in ('zone', 'seller')),
  payment_method      text check (payment_method in ('cod', 'other')),
  payment_note        text check (payment_note is null or char_length(payment_note) between 1 and 120),
  discount            integer not null default 0 check (discount between 0 and 1000000000),
  subtotal            bigint not null default 0 check (subtotal >= 0),
  total               bigint not null default 0 check (total >= 0),
  cod_due             bigint not null default 0 check (cod_due >= 0),
  cod_collected       bigint not null default 0 check (cod_collected >= 0),
  customer_note       text check (customer_note is null or char_length(customer_note) between 1 and 500),
  internal_note       text check (internal_note is null or char_length(internal_note) between 1 and 500),
  courier_note        text check (courier_note is null or char_length(courier_note) between 1 and 120),
  failure_reason      text check (failure_reason in ('unreachable', 'refused', 'wrong_address', 'other')),
  closed_reason       text,
  closed_note         text check (closed_note is null or char_length(closed_note) between 1 and 300),
  approved_by         uuid,
  approved_at         timestamptz,
  confirmation_marked_sent_at timestamptz,
  created_by          uuid,
  search_text         text not null default '',
  phone_digits        text not null default '',
  version             integer not null default 1 check (version >= 1),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  status_changed_at   timestamptz not null default now(),
  unique (store_id, id),
  unique (store_id, number),
  foreign key (store_id, zone_id) references app.delivery_zones (store_id, id),
  constraint orders_discount_le_subtotal check (discount <= subtotal),
  constraint orders_total_formula check (total = subtotal - discount + coalesce(delivery_fee, 0)),
  -- Approved and later orders always carry who approved and when (BR-22, never the system).
  constraint orders_approval_recorded check (
    (status in ('draft', 'pending_approval', 'rejected')) = (approved_by is null and approved_at is null))
);
create index orders_store_status on app.orders (store_id, status, created_at desc);
create index orders_store_created on app.orders (store_id, created_at desc, id);
create index orders_search on app.orders using gin (search_text extensions.gin_trgm_ops);

create table app.order_items (
  id                  uuid primary key default gen_random_uuid(),
  store_id            uuid not null,
  order_id            uuid not null,
  position            integer not null default 0,
  -- variant/product are null only for an unresolved AI line (Phase 8); manual lines are resolved.
  variant_id          uuid,
  product_id          uuid,
  resolution          text not null default 'resolved'
                        check (resolution in ('resolved', 'choose_product', 'variant_needed', 'not_in_catalog')),
  customer_text       text check (customer_text is null or char_length(customer_text) between 1 and 200),
  name_snapshot       text not null check (char_length(name_snapshot) between 1 and 200),
  variant_label_snapshot text not null default '',
  sku_snapshot        text,
  quantity            integer not null check (quantity between 1 and 999),
  quantity_basis      text not null default 'confirmed' check (quantity_basis in ('stated', 'inferred', 'confirmed')),
  quoted_unit_price   integer check (quoted_unit_price is null or quoted_unit_price between 1 and 1000000000),
  approved_unit_price integer check (approved_unit_price is null or approved_unit_price between 1 and 1000000000),
  stock_deducted      integer not null default 0 check (stock_deducted between 0 and 999),
  created_at          timestamptz not null default now(),
  unique (store_id, id),
  foreign key (store_id, order_id) references app.orders (store_id, id),
  foreign key (store_id, variant_id) references app.product_variants (store_id, id),
  foreign key (store_id, product_id) references app.products (store_id, id),
  constraint order_items_resolved check ((resolution = 'resolved') = (variant_id is not null)),
  constraint order_items_deducted_le_quantity check (stock_deducted <= quantity)
);
create index order_items_order on app.order_items (order_id, position);
create index order_items_variant on app.order_items (store_id, variant_id);
create unique index order_items_one_line_per_variant on app.order_items (order_id, variant_id) where variant_id is not null;

create table app.order_status_events (
  id            bigint generated always as identity primary key,
  store_id      uuid not null,
  order_id      uuid not null,
  from_status   text,
  to_status     text not null,
  actor_user_id uuid,
  actor_system  text check (actor_system in ('validation')),
  reason        text,
  note          text check (note is null or char_length(note) between 1 and 300),
  created_at    timestamptz not null default now(),
  foreign key (store_id, order_id) references app.orders (store_id, id),
  constraint order_status_events_actor check (actor_user_id is not null or actor_system is not null)
);
create index order_status_events_order on app.order_status_events (order_id, id);

create table app.return_lines (
  id            uuid primary key default gen_random_uuid(),
  store_id      uuid not null,
  order_id      uuid not null,
  order_item_id uuid not null unique,
  restock_qty   integer not null check (restock_qty between 0 and 999),
  writeoff_qty  integer not null check (writeoff_qty between 0 and 999),
  created_at    timestamptz not null default now(),
  foreign key (store_id, order_id) references app.orders (store_id, id),
  foreign key (store_id, order_item_id) references app.order_items (store_id, id)
);

create table app.cod_collections (
  id          bigint generated always as identity primary key,
  store_id    uuid not null,
  order_id    uuid not null,
  amount      bigint not null check (amount > 0),
  recorded_by uuid not null,
  created_at  timestamptz not null default now(),
  foreign key (store_id, order_id) references app.orders (store_id, id)
);
create index cod_collections_order on app.cod_collections (order_id);

-- Order movements name their order (Phase 1 BR-15, Phase 6 E §2.3).
alter table app.inventory_movements add column order_id uuid;
alter table app.inventory_movements
  add constraint inventory_movements_order_fk foreign key (store_id, order_id) references app.orders (store_id, id);
alter table app.inventory_movements
  add constraint inventory_movements_order_reason check (
    (reason in ('order_approved', 'order_edited', 'order_cancelled', 'order_returned_restock')) = (order_id is not null));
create index inventory_movements_order on app.inventory_movements (store_id, order_id) where order_id is not null;

-- ---------------------------------------------------------------------------------------------
-- Storage-level guards
-- ---------------------------------------------------------------------------------------------

-- Status history and the transition table are append-only / fixed (BR-34). Only the account
-- purge may delete history, and it says so for its own transaction.
create function app.protect_history()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('aisellia.purge', true), '') = 'on' then
    return old;
  end if;
  raise exception '% is append-only (%)', tg_table_name, tg_op using errcode = 'AS002';
end;
$$;
create trigger order_status_events_append_only
  before update or delete on app.order_status_events
  for each row execute function app.protect_history();
create trigger order_transitions_fixed
  before insert or update or delete on app.order_transitions
  for each row execute function app.protect_history();

-- Whatever writes the row, a status change must be an allowed transition, a new order starts as
-- draft or pending_approval, and orders are never deleted outside the purge.
create function app.guard_order_status()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if coalesce(current_setting('aisellia.purge', true), '') = 'on' then
      return old;
    end if;
    raise exception 'orders are never deleted' using errcode = 'AS002';
  end if;
  if tg_op = 'INSERT' then
    if new.status not in ('draft', 'pending_approval') then
      raise exception 'a new order starts as draft or pending_approval' using errcode = 'AS002';
    end if;
    return new;
  end if;
  if new.status <> old.status and not exists (
       select 1 from app.order_transitions t where t.from_status = old.status and t.to_status = new.status) then
    raise exception 'order transition % -> % is not allowed', old.status, new.status using errcode = 'AS002';
  end if;
  if new.store_id <> old.store_id or new.number <> old.number or new.is_test <> old.is_test
     or new.currency <> old.currency then
    raise exception 'order identity is immutable' using errcode = 'AS002';
  end if;
  return new;
end;
$$;
create trigger orders_status_guard
  before insert or update or delete on app.orders
  for each row execute function app.guard_order_status();

-- A variant on any order line is never deleted (BR-17); upsert_product reports VARIANT_IN_USE
-- (this raises the same business failure its handler already returns).
create function app.protect_ordered_variant()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('aisellia.purge', true), '') = 'on' then
    return old;
  end if;
  if exists (select 1 from app.order_items i where i.variant_id = old.id) then
    perform app.fail('VARIANT_IN_USE', jsonb_build_object('variant_ids', jsonb_build_array(old.id), 'reason', 'ordered'));
  end if;
  return old;
end;
$$;
create trigger product_variants_keep_ordered
  before delete on app.product_variants
  for each row execute function app.protect_ordered_variant();

-- ---------------------------------------------------------------------------------------------
-- RLS (defence in depth; the app reads through the api functions below).
-- ---------------------------------------------------------------------------------------------
alter table app.order_transitions enable row level security;
alter table app.orders enable row level security;
alter table app.order_items enable row level security;
alter table app.order_status_events enable row level security;
alter table app.return_lines enable row level security;
alter table app.cod_collections enable row level security;

create policy orders_select_member on app.orders
  for select to authenticated using (app.is_member(store_id));
create policy order_items_select_member on app.order_items
  for select to authenticated using (app.is_member(store_id));
create policy order_status_events_select_member on app.order_status_events
  for select to authenticated using (app.is_member(store_id));
create policy return_lines_select_member on app.return_lines
  for select to authenticated using (app.is_member(store_id));
create policy cod_collections_select_member on app.cod_collections
  for select to authenticated using (app.is_member(store_id));
-- order_transitions: no policy; only the definer functions read it.

revoke all on app.order_transitions, app.orders, app.order_items, app.order_status_events,
  app.return_lines, app.cod_collections from public, anon, authenticated;
grant select on app.orders, app.order_items, app.order_status_events, app.return_lines,
  app.cod_collections to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- Who did something, as the caller sees it.
create function app.actor_label(p_user uuid)
returns text language sql stable
as $$
  select case when p_user is null then 'system'
              when p_user = (select auth.uid()) then 'you'
              else 'member' end;
$$;

-- Missing required fields (BR-36), in display order. Empty = complete (pending_approval).
create function app.order_issues(p_order_id uuid)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(i.issue order by i.ord), '[]'::jsonb)
    from app.orders o
    cross join lateral (
      select 1 as ord, jsonb_build_object('field', 'customer_name', 'kind', 'missing') as issue where o.customer_name is null
      union all select 2, jsonb_build_object('field', 'customer_phone', 'kind', 'missing') where o.customer_phone is null
      union all select 3, jsonb_build_object('field', 'zone', 'kind', 'missing') where o.zone_id is null and o.city_text is null
      union all select 4, jsonb_build_object('field', 'area', 'kind', 'missing') where o.area is null
      union all select 5, jsonb_build_object('field', 'delivery_fee', 'kind', 'missing') where o.delivery_fee is null
      union all select 6, jsonb_build_object('field', 'payment_method', 'kind', 'missing') where o.payment_method is null
      union all select 7, jsonb_build_object('field', 'lines', 'kind', 'missing')
        where not exists (select 1 from app.order_items l where l.order_id = o.id)
      union all select 8 + l.position, jsonb_build_object('field', 'lines', 'kind', 'unresolved', 'item_id', l.id)
        from app.order_items l where l.order_id = o.id and l.resolution <> 'resolved'
      union all select 8 + l.position, jsonb_build_object('field', 'lines', 'kind', 'quantity_inferred', 'item_id', l.id)
        from app.order_items l where l.order_id = o.id and l.resolution = 'resolved' and l.quantity_basis = 'inferred'
    ) i
   where o.id = p_order_id;
$$;

-- Public shape of an order (the contract for every reader and every mutation result). Lines
-- carry the snapshot AND the live catalog state, so the review screen can show price changes,
-- stock and availability before approval (OR-02).
create function app.order_json(p_order_id uuid)
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'id', o.id,
    'store_id', o.store_id,
    'number', o.number,
    'status', o.status,
    'origin', o.origin,
    'is_test', o.is_test,
    'currency', o.currency,
    'customer', jsonb_build_object('name', o.customer_name, 'phone', o.customer_phone, 'phone2', o.customer_phone2),
    'delivery', jsonb_build_object(
      'zone_id', o.zone_id, 'zone_name', o.zone_name, 'city_text', o.city_text, 'area', o.area,
      'landmark', o.landmark, 'details', o.address_details, 'fee', o.delivery_fee,
      'fee_source', o.delivery_fee_source, 'courier_note', o.courier_note),
    'payment', jsonb_build_object('method', o.payment_method, 'note', o.payment_note,
                                  'cod_due', o.cod_due, 'cod_collected', o.cod_collected,
                                  'cod_outstanding', greatest(o.cod_due - o.cod_collected, 0)),
    'discount', o.discount,
    'subtotal', o.subtotal,
    'total', o.total,
    'customer_note', o.customer_note,
    'internal_note', o.internal_note,
    'failure_reason', o.failure_reason,
    'closed_reason', o.closed_reason,
    'closed_note', o.closed_note,
    'approved_by', app.actor_label(o.approved_by),
    'approved_at', o.approved_at,
    'confirmation_marked_sent_at', o.confirmation_marked_sent_at,
    'version', o.version,
    'created_at', o.created_at,
    'updated_at', o.updated_at,
    'status_changed_at', o.status_changed_at,
    'issues', app.order_issues(o.id),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id,
        'variant_id', l.variant_id,
        'product_id', l.product_id,
        'resolution', l.resolution,
        'customer_text', l.customer_text,
        'name', l.name_snapshot,
        'variant_label', l.variant_label_snapshot,
        'sku', l.sku_snapshot,
        'quantity', l.quantity,
        'quantity_basis', l.quantity_basis,
        'quoted_unit_price', l.quoted_unit_price,
        'approved_unit_price', l.approved_unit_price,
        'unit_price', coalesce(l.approved_unit_price, l.quoted_unit_price),
        'line_total', l.quantity::bigint * coalesce(l.approved_unit_price, l.quoted_unit_price, 0),
        'stock_deducted', l.stock_deducted,
        'image_path', (select i.storage_path from app.product_images i where i.product_id = l.product_id
                        order by i.position limit 1),
        'current', case when v.id is null then null else jsonb_build_object(
          'price', coalesce(v.price_override, p.base_price),
          'stock_on_hand', v.stock_on_hand,
          'track_stock', p.track_stock,
          'available', v.available,
          'product_status', p.status,
          'variant_status', v.status) end,
        'return', (select jsonb_build_object('restock_qty', r.restock_qty, 'writeoff_qty', r.writeoff_qty)
                     from app.return_lines r where r.order_item_id = l.id)
      ) order by l.position, l.created_at, l.id)
      from app.order_items l
      left join app.product_variants v on v.id = l.variant_id
      left join app.products p on p.id = v.product_id
      where l.order_id = o.id), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'from', e.from_status, 'to', e.to_status,
        'actor', case when e.actor_system is not null then 'system' else app.actor_label(e.actor_user_id) end,
        'reason', e.reason, 'note', e.note, 'created_at', e.created_at) order by e.id)
      from app.order_status_events e where e.order_id = o.id), '[]'::jsonb),
    'cod_collections', coalesce((
      select jsonb_agg(jsonb_build_object('amount', c.amount, 'actor', app.actor_label(c.recorded_by),
                                          'created_at', c.created_at) order by c.id)
      from app.cod_collections c where c.order_id = o.id), '[]'::jsonb)
  )
  from app.orders o
  where o.id = p_order_id;
$$;

-- What an edit changes, for the audit (before/after of the fields that differ; BR-33, BR-34).
create function app.order_audit_state(p_order_id uuid)
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'customer_name', o.customer_name, 'customer_phone', o.customer_phone, 'customer_phone2', o.customer_phone2,
    'zone_name', o.zone_name, 'city_text', o.city_text, 'area', o.area, 'landmark', o.landmark,
    'address_details', o.address_details, 'delivery_fee', o.delivery_fee,
    'payment_method', o.payment_method, 'payment_note', o.payment_note, 'discount', o.discount,
    'customer_note', o.customer_note, 'internal_note', o.internal_note, 'total', o.total,
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
                         'variant_id', l.variant_id, 'name', l.name_snapshot, 'variant_label', l.variant_label_snapshot,
                         'quantity', l.quantity, 'unit_price', coalesce(l.approved_unit_price, l.quoted_unit_price))
                       order by l.position, l.id)
                       from app.order_items l where l.order_id = o.id), '[]'::jsonb))
  from app.orders o where o.id = p_order_id;
$$;

create function app.jsonb_changed(p_before jsonb, p_after jsonb, p_side text)
returns jsonb language sql immutable
as $$
  select coalesce(jsonb_object_agg(k, case when p_side = 'before' then p_before -> k else p_after -> k end), '{}'::jsonb)
    from jsonb_object_keys(p_after) k
   where (p_before -> k) is distinct from (p_after -> k);
$$;

-- Recomputes subtotal and total from the lines (BR-24) and the search fields. p_money (from
-- order_write_header) carries a new discount and delivery fee; they are written in the same
-- statement as the totals, so the total and discount CHECKs always hold.
create function app.order_recompute(p_order_id uuid, p_money jsonb default null)
returns void
language plpgsql
as $$
declare
  v_order app.orders;
  v_subtotal bigint;
  v_discount integer;
  v_fee integer;
  v_source text;
begin
  select * into v_order from app.orders where id = p_order_id;
  v_discount := case when p_money is null then v_order.discount else (p_money ->> 'discount')::integer end;
  v_fee := case when p_money is null then v_order.delivery_fee else (p_money ->> 'delivery_fee')::integer end;
  v_source := case when p_money is null then v_order.delivery_fee_source else p_money ->> 'delivery_fee_source' end;
  select coalesce(sum(l.quantity::bigint * coalesce(l.approved_unit_price, l.quoted_unit_price, 0)), 0)
    into v_subtotal from app.order_items l where l.order_id = p_order_id;
  if v_subtotal < v_discount then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"discount": "exceeds_subtotal"}}');
  end if;
  update app.orders o set
    subtotal = v_subtotal,
    discount = v_discount,
    delivery_fee = v_fee,
    delivery_fee_source = v_source,
    total = v_subtotal - v_discount + coalesce(v_fee, 0),
    search_text = app.search_normalize(
      '#' || o.number || ' ' || coalesce(o.customer_name, '') || ' ' || coalesce(o.area, '') || ' ' ||
      coalesce(o.zone_name, o.city_text, '') || ' ' ||
      coalesce((select string_agg(l.name_snapshot || ' ' || l.variant_label_snapshot || ' ' || coalesce(l.sku_snapshot, ''), ' ')
                  from app.order_items l where l.order_id = o.id), '')),
    -- International and local forms, so "0750 123 4567" and "+964 750…" both match.
    phone_digits = concat_ws(' ',
      substr(o.customer_phone, 2), '0' || substr(o.customer_phone, 5),
      substr(o.customer_phone2, 2), '0' || substr(o.customer_phone2, 5))
  where o.id = p_order_id;
end;
$$;

-- Validation of an order payload (create_order, update_draft, edit_approved_order). Missing
-- values are allowed in a draft (they become issues); invalid values never are.
create function app.order_field_errors(p_store_id uuid, p_order jsonb, p_current_zone uuid)
returns jsonb
language plpgsql stable
as $$
declare
  v_errors jsonb := '{}'::jsonb;
  v_allowed text[] := array['customer_name', 'customer_phone', 'customer_phone2', 'zone_id', 'city_text',
                            'area', 'landmark', 'address_details', 'delivery_fee', 'payment_method',
                            'payment_note', 'discount', 'customer_note', 'internal_note', 'lines'];
  v_key text;
  v_text text;
  v_num jsonb;
  v_line jsonb;
  v_lines jsonb := coalesce(p_order -> 'lines', '[]'::jsonb);
  v_i integer := 0;
  v_seen uuid[] := '{}';
  v_variant uuid;
  v_store app.stores;
begin
  -- Anything else (status, total, approved_by, store_id, prices…) is refused, not ignored.
  for v_key in select k from jsonb_object_keys(p_order) k where not (k = any (v_allowed)) loop
    v_errors := v_errors || jsonb_build_object(v_key, 'unknown');
  end loop;

  foreach v_key in array array['customer_name:80', 'city_text:60', 'area:80', 'landmark:120',
                               'address_details:300', 'payment_note:120', 'customer_note:500',
                               'internal_note:500'] loop
    if p_order ? split_part(v_key, ':', 1) and jsonb_typeof(p_order -> split_part(v_key, ':', 1)) <> 'null' then
      if jsonb_typeof(p_order -> split_part(v_key, ':', 1)) <> 'string' then
        v_errors := v_errors || jsonb_build_object(split_part(v_key, ':', 1), 'invalid');
      elsif char_length(btrim(p_order ->> split_part(v_key, ':', 1))) > split_part(v_key, ':', 2)::integer then
        v_errors := v_errors || jsonb_build_object(split_part(v_key, ':', 1), 'too_long');
      end if;
    end if;
  end loop;
  foreach v_key in array array['customer_phone', 'customer_phone2'] loop
    v_text := nullif(btrim(coalesce(p_order ->> v_key, '')), '');
    if v_text is not null and v_text !~ '^\+9647[0-9]{9}$' then
      v_errors := v_errors || jsonb_build_object(v_key, 'invalid');
    end if;
  end loop;

  v_text := nullif(p_order ->> 'zone_id', '');
  if v_text is not null then
    if v_text !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      v_errors := v_errors || '{"zone_id": "invalid"}';
    elsif v_text::uuid is distinct from p_current_zone
          and not exists (select 1 from app.delivery_zones z
                           where z.id = v_text::uuid and z.store_id = p_store_id and z.active) then
      v_errors := v_errors || '{"zone_id": "invalid"}';
    end if;
  end if;

  foreach v_key in array array['delivery_fee:10000000', 'discount:1000000000'] loop
    v_num := p_order -> split_part(v_key, ':', 1);
    if v_num is not null and jsonb_typeof(v_num) <> 'null' and (
         jsonb_typeof(v_num) <> 'number' or (v_num::text)::numeric <> trunc((v_num::text)::numeric)
         or (v_num::text)::numeric not between 0 and split_part(v_key, ':', 2)::numeric) then
      v_errors := v_errors || jsonb_build_object(split_part(v_key, ':', 1), 'invalid');
    end if;
  end loop;

  select * into v_store from app.stores where id = p_store_id;
  v_text := p_order ->> 'payment_method';
  if v_text is not null then
    if v_text not in ('cod', 'other') then
      v_errors := v_errors || '{"payment_method": "invalid"}';
    elsif (v_text = 'cod' and not v_store.cod_enabled) or (v_text = 'other' and not v_store.other_payment_enabled) then
      v_errors := v_errors || '{"payment_method": "disabled"}';
    end if;
  end if;

  if jsonb_typeof(v_lines) <> 'array' then
    return v_errors || '{"lines": "invalid"}';
  end if;
  if jsonb_array_length(v_lines) > 50 then
    return v_errors || '{"lines": "too_many"}';
  end if;
  for v_line in select * from jsonb_array_elements(v_lines) loop
    if jsonb_typeof(v_line) <> 'object' then
      v_errors := v_errors || jsonb_build_object('lines.' || v_i, 'invalid');
    else
      for v_key in select k from jsonb_object_keys(v_line) k where k not in ('variant_id', 'quantity') loop
        v_errors := v_errors || jsonb_build_object('lines.' || v_i || '.' || v_key, 'unknown');
      end loop;
      v_text := v_line ->> 'variant_id';
      if v_text is null or v_text !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
        v_errors := v_errors || jsonb_build_object('lines.' || v_i || '.variant_id', 'required');
      else
        v_variant := v_text::uuid;
        if v_variant = any (v_seen) then
          v_errors := v_errors || jsonb_build_object('lines.' || v_i || '.variant_id', 'duplicate');
        elsif not exists (select 1 from app.product_variants v where v.id = v_variant and v.store_id = p_store_id) then
          -- Another store's variant reads exactly like a random id.
          v_errors := v_errors || jsonb_build_object('lines.' || v_i || '.variant_id', 'unknown');
        end if;
        v_seen := v_seen || v_variant;
      end if;
      v_num := v_line -> 'quantity';
      if v_num is null or jsonb_typeof(v_num) <> 'number' or (v_num::text)::numeric <> trunc((v_num::text)::numeric)
         or (v_num::text)::numeric not between 1 and 999 then
        v_errors := v_errors || jsonb_build_object('lines.' || v_i || '.quantity', 'out_of_range');
      end if;
    end if;
    v_i := v_i + 1;
  end loop;
  return v_errors;
end;
$$;

-- Writes the header fields of a validated payload (full state: an absent field is cleared).
-- Returns the discount and delivery fee for order_recompute, which writes them with the totals.
create function app.order_write_header(p_order_id uuid, p_order jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_zone app.delivery_zones;
  v_fee integer := (p_order ->> 'delivery_fee')::integer;
  v_order app.orders;
begin
  select * into v_order from app.orders where id = p_order_id;
  if nullif(p_order ->> 'zone_id', '') is not null then
    select * into v_zone from app.delivery_zones where id = (p_order ->> 'zone_id')::uuid;
  end if;
  update app.orders set
    customer_name   = nullif(btrim(coalesce(p_order ->> 'customer_name', '')), ''),
    customer_phone  = nullif(btrim(coalesce(p_order ->> 'customer_phone', '')), ''),
    customer_phone2 = nullif(btrim(coalesce(p_order ->> 'customer_phone2', '')), ''),
    zone_id         = v_zone.id,
    -- A zone kept from before keeps its snapshot name even if the zone was renamed or removed.
    zone_name       = case when v_zone.id is null then null
                           when v_zone.id = v_order.zone_id then v_order.zone_name else v_zone.name end,
    city_text       = nullif(btrim(coalesce(p_order ->> 'city_text', '')), ''),
    area            = nullif(btrim(coalesce(p_order ->> 'area', '')), ''),
    landmark        = nullif(btrim(coalesce(p_order ->> 'landmark', '')), ''),
    address_details = nullif(btrim(coalesce(p_order ->> 'address_details', '')), ''),
    payment_method  = p_order ->> 'payment_method',
    payment_note    = case when p_order ->> 'payment_method' = 'other'
                           then nullif(btrim(coalesce(p_order ->> 'payment_note', '')), '') end,
    customer_note   = nullif(btrim(coalesce(p_order ->> 'customer_note', '')), ''),
    internal_note   = nullif(btrim(coalesce(p_order ->> 'internal_note', '')), ''),
    updated_at      = now()
  where id = p_order_id;
  return jsonb_build_object(
    'discount', coalesce((p_order ->> 'discount')::integer, 0),
    -- A kept zone keeps its snapshot fee; a new zone brings its current fee; a seller fee wins.
    'delivery_fee', case when v_fee is not null then v_fee
                         when v_zone.id is not null and v_zone.id = v_order.zone_id
                              and v_order.delivery_fee_source = 'zone' then v_order.delivery_fee
                         else v_zone.fee end,
    'delivery_fee_source', case when v_fee is not null then 'seller'
                                when v_zone.id is not null then 'zone' end);
end;
$$;

-- Lines of a draft (no stock effect, Phase 3 §6.3). The list is the new state, identified by
-- variant: a line kept from before keeps its quoted price (BR-23); a new line must be an active,
-- sellable product and is quoted at the current catalog price.
create function app.order_write_draft_lines(p_store_id uuid, p_order_id uuid, p_lines jsonb)
returns void
language plpgsql
as $$
declare
  v_line jsonb;
  v_i integer := 0;
  v_variant app.product_variants;
  v_product app.products;
  v_existing app.order_items;
  v_kept uuid[] := '{}';
  v_unavailable jsonb := '{}'::jsonb;
begin
  for v_line in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select * into v_variant from app.product_variants where id = (v_line ->> 'variant_id')::uuid;
    select * into v_product from app.products where id = v_variant.product_id;
    select * into v_existing from app.order_items where order_id = p_order_id and variant_id = v_variant.id;
    if v_existing.id is not null then
      update app.order_items set quantity = (v_line ->> 'quantity')::integer, quantity_basis = 'confirmed',
                                 position = v_i
       where id = v_existing.id;
      v_kept := v_kept || v_existing.id;
    elsif v_product.status <> 'active' or v_variant.status <> 'active'
          or (not v_product.track_stock and not v_variant.available) then
      v_unavailable := v_unavailable || jsonb_build_object('lines.' || v_i || '.variant_id', 'unavailable');
    else
      insert into app.order_items (store_id, order_id, position, variant_id, product_id, name_snapshot,
                                   variant_label_snapshot, sku_snapshot, quantity, quoted_unit_price)
      values (p_store_id, p_order_id, v_i, v_variant.id, v_product.id, v_product.name, v_variant.label,
              v_variant.sku, (v_line ->> 'quantity')::integer, coalesce(v_variant.price_override, v_product.base_price))
      returning id into v_existing.id;
      v_kept := v_kept || v_existing.id;
    end if;
    v_i := v_i + 1;
  end loop;
  if v_unavailable <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_unavailable));
  end if;
  delete from app.order_items where order_id = p_order_id and not (id = any (v_kept));
end;
$$;

-- Records a status change: the row, the immutable event (BR-34) and the timestamp.
create function app.order_set_status(p_order_id uuid, p_to text, p_reason text, p_note text, p_system boolean default false)
returns void
language plpgsql
as $$
declare
  v_order app.orders;
begin
  select * into v_order from app.orders where id = p_order_id;
  if v_order.status = p_to then
    return;
  end if;
  update app.orders set status = p_to, status_changed_at = now(), updated_at = now() where id = p_order_id;
  insert into app.order_status_events (store_id, order_id, from_status, to_status, actor_user_id, actor_system, reason, note)
  values (v_order.store_id, p_order_id, v_order.status, p_to, auth.uid(),
          case when p_system then 'validation' end, p_reason, p_note);
end;
$$;

-- draft ↔ pending_approval from completeness, after every draft edit (BR-30 "automatic").
create function app.order_reevaluate(p_order_id uuid)
returns void
language plpgsql
as $$
declare
  v_status text := (select status from app.orders where id = p_order_id);
  v_target text;
begin
  if v_status not in ('draft', 'pending_approval') then
    return;
  end if;
  v_target := case when app.order_issues(p_order_id) = '[]'::jsonb then 'pending_approval' else 'draft' end;
  perform app.order_set_status(p_order_id, v_target, null, null, true);
end;
$$;

-- Moves stock for one order line by p_delta (negative = taken from stock) with a ledger row
-- naming the order. The caller holds the variant lock. Returns {before, after}.
create function app.order_move_stock(p_store_id uuid, p_order_id uuid, p_variant_id uuid, p_delta integer, p_reason text)
returns jsonb
language plpgsql
as $$
declare
  v_before integer;
  v_after integer;
begin
  select stock_on_hand into v_before from app.product_variants where id = p_variant_id;
  v_after := v_before + p_delta;
  if v_after < 0 then
    -- The caller checked availability under the same lock; this is a backstop.
    perform app.fail('INSUFFICIENT_STOCK', jsonb_build_object('lines', jsonb_build_array(
      jsonb_build_object('variant_id', p_variant_id, 'available', v_before, 'requested', -p_delta))));
  end if;
  update app.product_variants set stock_on_hand = v_after, updated_at = now() where id = p_variant_id;
  insert into app.inventory_movements (store_id, variant_id, delta, resulting_qty, reason, actor_user_id, order_id)
  values (p_store_id, p_variant_id, p_delta, v_after, p_reason, auth.uid(), p_order_id);
  return jsonb_build_object('before', v_before, 'after', v_after);
end;
$$;

-- Locks the order for a mutation and checks version. NOT_FOUND for another store's order.
create function app.lock_order(p_store_id uuid, p_order_id uuid, p_expected_version integer)
returns app.orders
language plpgsql
as $$
declare
  v_order app.orders;
begin
  select * into v_order from app.orders where id = p_order_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  return v_order;
end;
$$;

create function app.check_version(p_order app.orders, p_expected_version integer)
returns void
language plpgsql
as $$
begin
  if p_expected_version is null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"expected_version": "required"}}');
  end if;
  if p_order.version <> p_expected_version then
    perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', p_order.version,
                                                            'current_status', p_order.status));
  end if;
end;
$$;

create function app.invalid_transition(p_order app.orders, p_to text)
returns void
language plpgsql
as $$
begin
  perform app.fail('INVALID_TRANSITION', jsonb_build_object('current_status', p_order.status, 'to', p_to,
                                                            'current_version', p_order.version));
end;
$$;

-- Locks the products (share) and variants (update) of a set of variant ids in ascending id
-- order: the order upsert_product, adjust_stock and every order function use (no deadlocks).
create function app.lock_variants(p_variant_ids uuid[])
returns void
language plpgsql
as $$
begin
  perform 1 from app.products p
   where p.id in (select v.product_id from app.product_variants v where v.id = any (p_variant_ids))
   order by p.id for share;
  perform 1 from app.product_variants v where v.id = any (p_variant_ids) order by v.id for update;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.create_order: a manual order (Phase 3 §6.1). Always draft or pending_approval, decided by
-- the server from completeness; never approved, never moves stock (BR-20, BR-31).
-- ---------------------------------------------------------------------------------------------
create function api.create_order(p_store_id uuid, p_order jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_errors jsonb;
  v_hash text;
  v_result jsonb;
  v_number integer;
  v_order_id uuid;
  v_status text;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.create_draft');
  if p_order is null or jsonb_typeof(p_order) <> 'object' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"order": "required"}}');
  end if;
  v_errors := app.order_field_errors(p_store_id, p_order, null);
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'order', p_order));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'create_order', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  update app.stores set last_order_number = last_order_number + 1 where id = p_store_id
    returning last_order_number into v_number;
  insert into app.orders (store_id, number, status, origin, currency, created_by)
  values (p_store_id, v_number, 'draft', 'manual', (select currency from app.stores where id = p_store_id), v_uid)
  returning id into v_order_id;
  perform app.order_write_draft_lines(p_store_id, v_order_id, p_order -> 'lines');
  perform app.order_recompute(v_order_id, app.order_write_header(v_order_id, p_order));
  -- One creation event (∅ → draft or pending_approval), decided by completeness.
  v_status := case when app.order_issues(v_order_id) = '[]'::jsonb then 'pending_approval' else 'draft' end;
  update app.orders set status = v_status where id = v_order_id;
  insert into app.order_status_events (store_id, order_id, from_status, to_status, actor_user_id)
  values (p_store_id, v_order_id, null, v_status, v_uid);
  perform app.audit(p_store_id, 'order.create', 'order', v_order_id, null, app.order_audit_state(v_order_id));

  v_result := app.ok(app.order_json(v_order_id));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'create_order', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('create_order', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.update_draft: edit a draft or pending order (full state). Re-evaluates draft ↔ pending.
-- ---------------------------------------------------------------------------------------------
create function api.update_draft(p_store_id uuid, p_order_id uuid, p_expected_version integer, p_order jsonb,
                                 p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_order app.orders;
  v_errors jsonb;
  v_hash text;
  v_result jsonb;
  v_before jsonb;
  v_after jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.edit_draft');
  if p_order is null or jsonb_typeof(p_order) <> 'object' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"order": "required"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'order_id', p_order_id,
                                                'version', p_expected_version, 'order', p_order));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'update_draft', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  v_order := app.lock_order(p_store_id, p_order_id, p_expected_version);
  if v_order.status not in ('draft', 'pending_approval') then
    perform app.invalid_transition(v_order, v_order.status);
  end if;
  perform app.check_version(v_order, p_expected_version);
  v_errors := app.order_field_errors(p_store_id, p_order, v_order.zone_id);
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  v_before := app.order_audit_state(p_order_id);
  perform app.order_write_draft_lines(p_store_id, p_order_id, p_order -> 'lines');
  update app.orders set version = version + 1 where id = p_order_id;
  perform app.order_recompute(p_order_id, app.order_write_header(p_order_id, p_order));
  perform app.order_reevaluate(p_order_id);
  v_after := app.order_audit_state(p_order_id);
  if v_after <> v_before then
    perform app.audit(p_store_id, 'order.update_draft', 'order', p_order_id,
                      app.jsonb_changed(v_before, v_after, 'before'), app.jsonb_changed(v_before, v_after, 'after'));
  end if;

  v_result := app.ok(app.order_json(p_order_id));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'update_draft', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('update_draft', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.approve_order: THE approval gate (Phase 3 §6.2 steps 1–12; BR-20..BR-23, BR-30).
--   Only an end user who is the store's owner, with a confirmed email, approves; only from
--   pending_approval; all-or-nothing under the order lock and the variant locks (id order).
--   p_price_choices: {item_id: "quoted" | "current"} for lines whose catalog price changed.
-- ---------------------------------------------------------------------------------------------
create function api.approve_order(p_store_id uuid, p_order_id uuid, p_expected_version integer,
                                  p_price_choices jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_member app.store_members;
  v_order app.orders;
  v_choices jsonb := coalesce(p_price_choices, '{}'::jsonb);
  v_hash text;
  v_result jsonb;
  v_issues jsonb;
  v_line record;
  v_unavailable jsonb := '[]'::jsonb;
  v_short jsonb := '[]'::jsonb;
  v_changed jsonb := '[]'::jsonb;
  v_stock_after jsonb := '[]'::jsonb;
  v_move jsonb;
  v_price integer;
  v_code text;
  v_detail text;
  v_state text;
begin
  -- 2. Caller: end user (never anon or service_role), owner only, confirmed email.
  v_uid := app.require_end_user();
  v_member := app.require_permission(p_store_id, 'orders.approve');
  if v_member.role <> 'owner' then
    perform app.fail('FORBIDDEN');
  end if;
  if not exists (select 1 from auth.users u where u.id = v_uid and u.email_confirmed_at is not null) then
    perform app.fail('EMAIL_NOT_VERIFIED');
  end if;
  if jsonb_typeof(v_choices) <> 'object' or exists (
       select 1 from jsonb_each(v_choices) c where jsonb_typeof(c.value) <> 'string' or c.value #>> '{}' not in ('quoted', 'current')) then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"price_choices": "invalid"}}');
  end if;

  -- 1. Idempotency.
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'order_id', p_order_id,
                                                'version', p_expected_version, 'choices', v_choices));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'approve_order', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  -- 3–5. Lock the order; status, version, completeness.
  v_order := app.lock_order(p_store_id, p_order_id, p_expected_version);
  if v_order.status = 'draft' then
    perform app.fail('INCOMPLETE_ORDER', jsonb_build_object('issues', app.order_issues(p_order_id)));
  elsif v_order.status <> 'pending_approval' then
    perform app.invalid_transition(v_order, 'approved');
  end if;
  perform app.check_version(v_order, p_expected_version);
  v_issues := app.order_issues(p_order_id);
  if v_issues <> '[]'::jsonb then
    perform app.fail('INCOMPLETE_ORDER', jsonb_build_object('issues', v_issues));
  end if;

  -- 6. Lock products and variants in id order.
  perform app.lock_variants(array(select variant_id from app.order_items where order_id = p_order_id));

  -- 7. Re-validate every line against the catalog as it is now (a displayed value is no proof).
  for v_line in
    select l.id, l.quantity, l.quoted_unit_price, v.id as variant_id, v.stock_on_hand, v.available,
           v.status as variant_status, p.status as product_status, p.track_stock,
           coalesce(v.price_override, p.base_price) as current_price
      from app.order_items l
      join app.product_variants v on v.id = l.variant_id
      join app.products p on p.id = v.product_id
     where l.order_id = p_order_id
     order by l.position, l.id
  loop
    if v_line.product_status <> 'active' or v_line.variant_status <> 'active'
       or (not v_line.track_stock and not v_line.available) then
      v_unavailable := v_unavailable || jsonb_build_object('item_id', v_line.id, 'reason',
        case when v_line.product_status = 'archived' or v_line.variant_status = 'archived' then 'archived'
             when v_line.product_status = 'inactive' then 'inactive' else 'unavailable' end);
    elsif v_line.track_stock and not v_order.is_test and v_line.stock_on_hand < v_line.quantity then
      v_short := v_short || jsonb_build_object('item_id', v_line.id, 'requested', v_line.quantity,
                                               'available', v_line.stock_on_hand);
    end if;
    if v_line.current_price <> v_line.quoted_unit_price and not v_choices ? v_line.id::text then
      v_changed := v_changed || jsonb_build_object('item_id', v_line.id, 'quoted', v_line.quoted_unit_price,
                                                   'current', v_line.current_price);
    end if;
  end loop;
  if v_unavailable <> '[]'::jsonb then
    perform app.fail('LINE_UNAVAILABLE', jsonb_build_object('lines', v_unavailable));
  end if;
  if v_short <> '[]'::jsonb then
    perform app.fail('INSUFFICIENT_STOCK', jsonb_build_object('lines', v_short));
  end if;
  if v_changed <> '[]'::jsonb then
    perform app.fail('PRICE_CHANGED', jsonb_build_object('items', v_changed));
  end if;

  -- 8–9. Movements, balances, approved prices and snapshots (frozen from now on).
  for v_line in
    select l.id, l.quantity, l.quoted_unit_price, v.id as variant_id, v.label, v.sku, p.name, p.track_stock,
           coalesce(v.price_override, p.base_price) as current_price
      from app.order_items l
      join app.product_variants v on v.id = l.variant_id
      join app.products p on p.id = v.product_id
     where l.order_id = p_order_id
     order by v.id
  loop
    v_price := case when v_choices ->> v_line.id::text = 'current' then v_line.current_price
                    else v_line.quoted_unit_price end;
    update app.order_items set approved_unit_price = v_price, name_snapshot = v_line.name,
                               variant_label_snapshot = v_line.label, sku_snapshot = v_line.sku
     where id = v_line.id;
    if v_line.track_stock and not v_order.is_test then
      v_move := app.order_move_stock(p_store_id, p_order_id, v_line.variant_id, -v_line.quantity, 'order_approved');
      update app.order_items set stock_deducted = v_line.quantity where id = v_line.id;
      v_stock_after := v_stock_after || (jsonb_build_object('item_id', v_line.id, 'variant_id', v_line.variant_id,
        'name', v_line.name, 'label', v_line.label) || v_move);
    end if;
  end loop;
  perform app.order_recompute(p_order_id);
  update app.orders set
    approved_by = v_uid,
    approved_at = now(),
    status = 'approved',
    status_changed_at = now(),
    cod_due = case when payment_method = 'cod' then total else 0 end,
    version = version + 1,
    updated_at = now()
  where id = p_order_id;
  insert into app.order_status_events (store_id, order_id, from_status, to_status, actor_user_id)
  values (p_store_id, p_order_id, 'pending_approval', 'approved', v_uid);

  -- 10. Prices are now committed in the store currency.
  update app.stores set currency_locked_at = now() where id = p_store_id and currency_locked_at is null;

  -- 11–12. Audit and idempotency.
  perform app.audit(p_store_id, 'order.approve', 'order', p_order_id,
                    jsonb_build_object('status', 'pending_approval'),
                    jsonb_build_object('status', 'approved', 'total', (select total from app.orders where id = p_order_id),
                                       'price_choices', v_choices, 'stock', v_stock_after));
  v_result := app.ok(app.order_json(p_order_id) || jsonb_build_object('stock_after', v_stock_after));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'approve_order', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('approve_order', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.reject_draft (OR-04): draft or pending → rejected (terminal), with a reason. No stock.
-- ---------------------------------------------------------------------------------------------
create function api.reject_draft(p_store_id uuid, p_order_id uuid, p_expected_version integer, p_reason text,
                                 p_note text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_order app.orders;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_hash text;
  v_result jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.reject');
  if p_reason is null or p_reason not in ('customer_changed_mind', 'not_serious', 'duplicate', 'out_of_stock',
                                          'cannot_deliver', 'other') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"reason": "invalid"}}');
  elsif p_reason = 'other' and v_note is null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"note": "required"}}');
  elsif char_length(coalesce(v_note, '')) > 300 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"note": "too_long"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'order_id', p_order_id,
                                                'version', p_expected_version, 'reason', p_reason, 'note', v_note));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'reject_draft', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  v_order := app.lock_order(p_store_id, p_order_id, p_expected_version);
  if v_order.status not in ('draft', 'pending_approval') then
    perform app.invalid_transition(v_order, 'rejected');
  end if;
  perform app.check_version(v_order, p_expected_version);
  update app.orders set closed_reason = p_reason, closed_note = v_note, version = version + 1 where id = p_order_id;
  perform app.order_set_status(p_order_id, 'rejected', p_reason, v_note);
  perform app.audit(p_store_id, 'order.reject', 'order', p_order_id, jsonb_build_object('status', v_order.status),
                    jsonb_build_object('status', 'rejected', 'reason', p_reason));

  v_result := app.ok(app.order_json(p_order_id));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'reject_draft', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('reject_draft', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.edit_approved_order (BR-33, OR-06 edit mode): approved or processing only. The payload is
-- the full state. Item and quantity changes move stock by the difference, atomically; increases
-- and new lines are re-validated like an approval. Kept lines keep their approved price; a new
-- line takes the current catalog price. Returns the order plus stock_diff[].
-- ---------------------------------------------------------------------------------------------
create function api.edit_approved_order(p_store_id uuid, p_order_id uuid, p_expected_version integer,
                                        p_order jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_order app.orders;
  v_errors jsonb;
  v_hash text;
  v_result jsonb;
  v_before jsonb;
  v_after jsonb;
  v_line jsonb;
  v_i integer := 0;
  v_existing app.order_items;
  v_variant app.product_variants;
  v_product app.products;
  v_qty integer;
  v_target integer;
  v_kept uuid[] := '{}';
  v_variant_ids uuid[];
  v_unavailable jsonb := '[]'::jsonb;
  v_short jsonb := '[]'::jsonb;
  v_diff jsonb := '[]'::jsonb;
  v_move jsonb;
  v_issues jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.edit_approved');
  if p_order is null or jsonb_typeof(p_order) <> 'object' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"order": "required"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'order_id', p_order_id,
                                                'version', p_expected_version, 'order', p_order));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'edit_approved_order', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  v_order := app.lock_order(p_store_id, p_order_id, p_expected_version);
  if v_order.status not in ('approved', 'processing') then
    perform app.invalid_transition(v_order, v_order.status);
  end if;
  perform app.check_version(v_order, p_expected_version);
  v_errors := app.order_field_errors(p_store_id, p_order, v_order.zone_id);
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;
  if coalesce((p_order ->> 'discount')::integer, 0) <> v_order.discount then
    perform app.require_permission(p_store_id, 'orders.discount');
  end if;

  v_before := app.order_audit_state(p_order_id);
  select array_agg(distinct x) into v_variant_ids from (
    select variant_id as x from app.order_items where order_id = p_order_id and variant_id is not null
    union select (l ->> 'variant_id')::uuid from jsonb_array_elements(coalesce(p_order -> 'lines', '[]'::jsonb)) l) s;
  perform app.lock_variants(coalesce(v_variant_ids, '{}'));

  -- Check every new line and increase first; nothing changes unless all pass.
  for v_line in select * from jsonb_array_elements(coalesce(p_order -> 'lines', '[]'::jsonb)) loop
    select * into v_variant from app.product_variants where id = (v_line ->> 'variant_id')::uuid;
    select * into v_product from app.products where id = v_variant.product_id;
    select * into v_existing from app.order_items where order_id = p_order_id and variant_id = v_variant.id;
    v_qty := (v_line ->> 'quantity')::integer;
    if v_existing.id is null or v_qty > v_existing.quantity then
      if v_product.status <> 'active' or v_variant.status <> 'active'
         or (not v_product.track_stock and not v_variant.available) then
        v_unavailable := v_unavailable || jsonb_build_object('index', v_i, 'variant_id', v_variant.id,
          'reason', case when v_product.status = 'archived' or v_variant.status = 'archived' then 'archived'
                         when v_product.status = 'inactive' then 'inactive' else 'unavailable' end);
      elsif v_product.track_stock and not v_order.is_test
            and v_variant.stock_on_hand < v_qty - coalesce(v_existing.stock_deducted, 0) then
        v_short := v_short || jsonb_build_object('index', v_i, 'variant_id', v_variant.id,
          'requested', v_qty - coalesce(v_existing.stock_deducted, 0), 'available', v_variant.stock_on_hand);
      end if;
    end if;
    v_i := v_i + 1;
  end loop;
  if v_unavailable <> '[]'::jsonb then
    perform app.fail('LINE_UNAVAILABLE', jsonb_build_object('lines', v_unavailable));
  end if;
  if v_short <> '[]'::jsonb then
    perform app.fail('INSUFFICIENT_STOCK', jsonb_build_object('lines', v_short));
  end if;

  -- Apply lines and stock differences.
  v_i := 0;
  for v_line in select * from jsonb_array_elements(coalesce(p_order -> 'lines', '[]'::jsonb)) loop
    select * into v_variant from app.product_variants where id = (v_line ->> 'variant_id')::uuid;
    select * into v_product from app.products where id = v_variant.product_id;
    select * into v_existing from app.order_items where order_id = p_order_id and variant_id = v_variant.id;
    v_qty := (v_line ->> 'quantity')::integer;
    -- Units held for the line: the quantity when the product tracks stock; otherwise unchanged
    -- (what was taken earlier stays taken until the line is removed, cancelled or returned).
    v_target := case when v_order.is_test then 0
                     when v_product.track_stock then v_qty
                     else least(coalesce(v_existing.stock_deducted, 0), v_qty) end;
    if v_existing.id is null then
      insert into app.order_items (store_id, order_id, position, variant_id, product_id, name_snapshot,
                                   variant_label_snapshot, sku_snapshot, quantity, quoted_unit_price,
                                   approved_unit_price, stock_deducted)
      values (p_store_id, p_order_id, v_i, v_variant.id, v_product.id, v_product.name, v_variant.label, v_variant.sku,
              v_qty, coalesce(v_variant.price_override, v_product.base_price),
              coalesce(v_variant.price_override, v_product.base_price), v_target)
      returning id into v_existing.id;
      v_existing.stock_deducted := 0;
    else
      update app.order_items set quantity = v_qty, position = v_i, stock_deducted = v_target where id = v_existing.id;
    end if;
    v_kept := v_kept || v_existing.id;
    if v_target <> v_existing.stock_deducted then
      v_move := app.order_move_stock(p_store_id, p_order_id, v_variant.id, v_existing.stock_deducted - v_target, 'order_edited');
      v_diff := v_diff || (jsonb_build_object('variant_id', v_variant.id, 'name', v_product.name, 'label', v_variant.label,
                                             'delta', v_existing.stock_deducted - v_target) || v_move);
    end if;
    v_i := v_i + 1;
  end loop;
  -- Removed lines give back what they held.
  for v_existing in select * from app.order_items where order_id = p_order_id and not (id = any (v_kept)) order by variant_id loop
    if v_existing.stock_deducted > 0 then
      v_move := app.order_move_stock(p_store_id, p_order_id, v_existing.variant_id, v_existing.stock_deducted, 'order_edited');
      v_diff := v_diff || (jsonb_build_object('variant_id', v_existing.variant_id, 'name', v_existing.name_snapshot,
                                             'label', v_existing.variant_label_snapshot,
                                             'delta', v_existing.stock_deducted) || v_move);
    end if;
    delete from app.order_items where id = v_existing.id;
  end loop;

  perform app.order_recompute(p_order_id, app.order_write_header(p_order_id, p_order));
  v_issues := app.order_issues(p_order_id);
  if v_issues <> '[]'::jsonb then
    perform app.fail('INCOMPLETE_ORDER', jsonb_build_object('issues', v_issues));
  end if;
  update app.orders set cod_due = case when payment_method = 'cod' then total else 0 end,
                        version = version + 1, updated_at = now()
   where id = p_order_id;
  v_after := app.order_audit_state(p_order_id);
  perform app.audit(p_store_id, 'order.edit', 'order', p_order_id,
                    app.jsonb_changed(v_before, v_after, 'before'),
                    app.jsonb_changed(v_before, v_after, 'after') || jsonb_build_object('stock_diff', v_diff));

  v_result := app.ok(app.order_json(p_order_id) || jsonb_build_object('stock_diff', v_diff));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'edit_approved_order', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('edit_approved_order', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.cancel_order (OR-09): approved or processing → cancelled, reason required. Everything the
-- lines hold goes back to stock exactly once (the status is terminal). COD due becomes 0 (BR-44).
-- ---------------------------------------------------------------------------------------------
create function api.cancel_order(p_store_id uuid, p_order_id uuid, p_expected_version integer, p_reason text,
                                 p_note text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_order app.orders;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_hash text;
  v_result jsonb;
  v_line app.order_items;
  v_restocked jsonb := '[]'::jsonb;
  v_move jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.cancel');
  if p_reason is null or p_reason not in ('customer_cancelled', 'out_of_stock', 'cannot_deliver', 'duplicate', 'other') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"reason": "invalid"}}');
  elsif p_reason = 'other' and v_note is null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"note": "required"}}');
  elsif char_length(coalesce(v_note, '')) > 300 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"note": "too_long"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'order_id', p_order_id,
                                                'version', p_expected_version, 'reason', p_reason, 'note', v_note));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'cancel_order', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  v_order := app.lock_order(p_store_id, p_order_id, p_expected_version);
  if v_order.status not in ('approved', 'processing') then
    perform app.invalid_transition(v_order, 'cancelled');
  end if;
  perform app.check_version(v_order, p_expected_version);
  perform app.lock_variants(array(select variant_id from app.order_items where order_id = p_order_id));
  for v_line in select * from app.order_items where order_id = p_order_id and stock_deducted > 0 order by variant_id loop
    v_move := app.order_move_stock(p_store_id, p_order_id, v_line.variant_id, v_line.stock_deducted, 'order_cancelled');
    update app.order_items set stock_deducted = 0 where id = v_line.id;
    v_restocked := v_restocked || (jsonb_build_object('item_id', v_line.id, 'variant_id', v_line.variant_id,
      'name', v_line.name_snapshot, 'label', v_line.variant_label_snapshot, 'quantity', v_line.stock_deducted) || v_move);
  end loop;
  update app.orders set closed_reason = p_reason, closed_note = v_note, cod_due = 0, version = version + 1
   where id = p_order_id;
  perform app.order_set_status(p_order_id, 'cancelled', p_reason, v_note);
  perform app.audit(p_store_id, 'order.cancel', 'order', p_order_id, jsonb_build_object('status', v_order.status),
                    jsonb_build_object('status', 'cancelled', 'reason', p_reason, 'restocked', v_restocked));

  v_result := app.ok(app.order_json(p_order_id) || jsonb_build_object('restocked', v_restocked));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'cancel_order', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('cancel_order', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.transition_order (OR-05, OR-08): processing, dispatched, delivered, delivery_failed.
--   dispatched: complete delivery details; optional courier_note. delivered: optional
--   cod_collected (0 … due). delivery_failed: reason (unreachable, refused, wrong_address,
--   other + note). No stock effect. There is no generic "set status".
-- ---------------------------------------------------------------------------------------------
create function api.transition_order(p_store_id uuid, p_order_id uuid, p_expected_version integer, p_to text,
                                     p_payload jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_order app.orders;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_hash text;
  v_result jsonb;
  v_note text;
  v_reason text;
  v_amount jsonb;
  v_key text;
  v_issues jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  if p_to is null or p_to not in ('processing', 'dispatched', 'delivered', 'delivery_failed') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"to": "invalid"}}');
  end if;
  if jsonb_typeof(v_payload) <> 'object' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"payload": "invalid"}}');
  end if;
  for v_key in select k from jsonb_object_keys(v_payload) k
                where k not in ('courier_note', 'cod_collected', 'reason', 'note') loop
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object(v_key, 'unknown')));
  end loop;
  v_note := nullif(btrim(coalesce(v_payload ->> 'note', v_payload ->> 'courier_note', '')), '');
  if p_to = 'delivery_failed' then
    v_reason := v_payload ->> 'reason';
    if v_reason is null or v_reason not in ('unreachable', 'refused', 'wrong_address', 'other') then
      perform app.fail('VALIDATION_FAILED', '{"fields": {"reason": "invalid"}}');
    elsif v_reason = 'other' and v_note is null then
      perform app.fail('VALIDATION_FAILED', '{"fields": {"note": "required"}}');
    end if;
  end if;
  if char_length(coalesce(v_note, '')) > 120 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"note": "too_long"}}');
  end if;
  v_amount := v_payload -> 'cod_collected';
  if v_amount is not null and jsonb_typeof(v_amount) <> 'null' and (
       p_to <> 'delivered' or jsonb_typeof(v_amount) <> 'number'
       or (v_amount::text)::numeric <> trunc((v_amount::text)::numeric) or (v_amount::text)::numeric < 0) then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"cod_collected": "invalid"}}');
  end if;

  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'order_id', p_order_id,
                                                'version', p_expected_version, 'to', p_to, 'payload', v_payload));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'transition_order', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  v_order := app.lock_order(p_store_id, p_order_id, p_expected_version);
  if not exists (select 1 from app.order_transitions t
                  where t.from_status = v_order.status and t.to_status = p_to and t.via = 'transition') then
    perform app.invalid_transition(v_order, p_to);
  end if;
  perform app.check_version(v_order, p_expected_version);

  if p_to = 'dispatched' then
    v_issues := app.order_issues(p_order_id);
    if v_issues <> '[]'::jsonb then
      perform app.fail('INCOMPLETE_ORDER', jsonb_build_object('issues', v_issues));
    end if;
    update app.orders set courier_note = coalesce(v_note, courier_note), failure_reason = null where id = p_order_id;
  elsif p_to = 'delivery_failed' then
    update app.orders set failure_reason = v_reason where id = p_order_id;
  elsif p_to = 'delivered' and coalesce((v_amount::text)::numeric, 0) > 0 then
    if (v_amount::text)::numeric > v_order.cod_due - v_order.cod_collected then
      perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object('cod_collected', 'exceeds_due'),
                                                               'cod_outstanding', v_order.cod_due - v_order.cod_collected));
    end if;
    insert into app.cod_collections (store_id, order_id, amount, recorded_by)
    values (p_store_id, p_order_id, (v_amount::text)::bigint, v_uid);
    update app.orders set cod_collected = cod_collected + (v_amount::text)::bigint where id = p_order_id;
  end if;
  update app.orders set version = version + 1 where id = p_order_id;
  perform app.order_set_status(p_order_id, p_to, v_reason, v_note);
  perform app.audit(p_store_id, 'order.transition', 'order', p_order_id, jsonb_build_object('status', v_order.status),
                    jsonb_build_object('status', p_to) || v_payload);

  v_result := app.ok(app.order_json(p_order_id));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'transition_order', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('transition_order', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.record_return (OR-08 "Mark returned"): dispatched or delivery_failed → returned. Every line
-- must be decided: restock_qty + writeoff_qty = quantity. Restocked units go back to stock (at
-- most what the line held); written-off units create no movement (Phase 3 §6.3).
-- ---------------------------------------------------------------------------------------------
create function api.record_return(p_store_id uuid, p_order_id uuid, p_expected_version integer, p_lines jsonb,
                                  p_note text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_order app.orders;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_lines jsonb := coalesce(p_lines, '[]'::jsonb);
  v_hash text;
  v_result jsonb;
  v_item app.order_items;
  v_decision jsonb;
  v_restock integer;
  v_writeoff integer;
  v_back integer;
  v_restocked jsonb := '[]'::jsonb;
  v_move jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  if jsonb_typeof(v_lines) <> 'array'
     or exists (select 1 from jsonb_array_elements(v_lines) x
                 where jsonb_typeof(x) <> 'object' or jsonb_typeof(x -> 'item_id') <> 'string'
                    or jsonb_typeof(x -> 'restock_qty') is distinct from 'number'
                    or jsonb_typeof(x -> 'writeoff_qty') is distinct from 'number') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"lines": "invalid"}}');
  end if;
  if exists (select 1 from jsonb_array_elements(v_lines) x
              where (x ->> 'restock_qty')::numeric < 0 or (x ->> 'writeoff_qty')::numeric < 0
                 or (x ->> 'restock_qty')::numeric <> trunc((x ->> 'restock_qty')::numeric)
                 or (x ->> 'writeoff_qty')::numeric <> trunc((x ->> 'writeoff_qty')::numeric)
                 or (x ->> 'restock_qty')::numeric > 999 or (x ->> 'writeoff_qty')::numeric > 999) then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"lines": "invalid"}}');
  end if;
  if char_length(coalesce(v_note, '')) > 300 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"note": "too_long"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'order_id', p_order_id,
                                                'version', p_expected_version, 'lines', v_lines, 'note', v_note));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'record_return', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  v_order := app.lock_order(p_store_id, p_order_id, p_expected_version);
  if v_order.status not in ('dispatched', 'delivery_failed') then
    perform app.invalid_transition(v_order, 'returned');
  end if;
  perform app.check_version(v_order, p_expected_version);
  -- Exactly one decision per line, and each adds up to the line quantity.
  if (select count(*) from jsonb_array_elements(v_lines)) <> (select count(*) from app.order_items where order_id = p_order_id)
     or (select count(distinct x ->> 'item_id') from jsonb_array_elements(v_lines) x)
        <> (select count(*) from app.order_items where order_id = p_order_id)
     or exists (select 1 from jsonb_array_elements(v_lines) x
                 where not exists (select 1 from app.order_items i
                                    where i.order_id = p_order_id and i.id::text = x ->> 'item_id'
                                      and i.quantity = (x ->> 'restock_qty')::integer + (x ->> 'writeoff_qty')::integer)) then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"lines": "every_line_decided"}}');
  end if;

  perform app.lock_variants(array(select variant_id from app.order_items where order_id = p_order_id));
  for v_item in select * from app.order_items where order_id = p_order_id order by variant_id loop
    select x into v_decision from jsonb_array_elements(v_lines) x where x ->> 'item_id' = v_item.id::text;
    v_restock := (v_decision ->> 'restock_qty')::integer;
    v_writeoff := (v_decision ->> 'writeoff_qty')::integer;
    insert into app.return_lines (store_id, order_id, order_item_id, restock_qty, writeoff_qty)
    values (p_store_id, p_order_id, v_item.id, v_restock, v_writeoff);
    v_back := least(v_restock, v_item.stock_deducted);
    if v_back > 0 then
      v_move := app.order_move_stock(p_store_id, p_order_id, v_item.variant_id, v_back, 'order_returned_restock');
      v_restocked := v_restocked || (jsonb_build_object('item_id', v_item.id, 'variant_id', v_item.variant_id,
        'name', v_item.name_snapshot, 'label', v_item.variant_label_snapshot, 'quantity', v_back) || v_move);
    end if;
    -- Written-off units stay out of stock: the line keeps holding them (the ledger agrees).
    update app.order_items set stock_deducted = stock_deducted - v_back where id = v_item.id;
  end loop;
  update app.orders set closed_note = v_note, cod_due = 0, version = version + 1 where id = p_order_id;
  perform app.order_set_status(p_order_id, 'returned', null, v_note);
  perform app.audit(p_store_id, 'order.return', 'order', p_order_id, jsonb_build_object('status', v_order.status),
                    jsonb_build_object('status', 'returned', 'lines', v_lines, 'restocked', v_restocked));

  v_result := app.ok(app.order_json(p_order_id) || jsonb_build_object('restocked', v_restocked));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'record_return', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('record_return', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.record_cod (OR-08 "Record cash"): cash collected after delivery, at most what is still due.
-- ---------------------------------------------------------------------------------------------
create function api.record_cod(p_store_id uuid, p_order_id uuid, p_amount bigint, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_order app.orders;
  v_hash text;
  v_result jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  if p_amount is null or p_amount <= 0 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"amount": "out_of_range"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'order_id', p_order_id, 'amount', p_amount));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'record_cod', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  v_order := app.lock_order(p_store_id, p_order_id, null);
  if v_order.status <> 'delivered' or v_order.payment_method <> 'cod' then
    perform app.invalid_transition(v_order, v_order.status);
  end if;
  if p_amount > v_order.cod_due - v_order.cod_collected then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', '{"amount": "exceeds_due"}'::jsonb,
                                                             'cod_outstanding', v_order.cod_due - v_order.cod_collected));
  end if;
  insert into app.cod_collections (store_id, order_id, amount, recorded_by) values (p_store_id, p_order_id, p_amount, v_uid);
  update app.orders set cod_collected = cod_collected + p_amount, version = version + 1, updated_at = now()
   where id = p_order_id;
  perform app.audit(p_store_id, 'order.cod', 'order', p_order_id, jsonb_build_object('cod_collected', v_order.cod_collected),
                    jsonb_build_object('cod_collected', v_order.cod_collected + p_amount, 'amount', p_amount));
  v_result := app.ok(app.order_json(p_order_id));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'record_cod', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('record_cod', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.mark_confirmation_sent (OR-10 "I sent this", BR-46): the seller says they sent the
-- confirmation themselves. Aisellia sends nothing. Approved and later, not cancelled/returned.
-- Repeating it is a no-op.
-- ---------------------------------------------------------------------------------------------
create function api.mark_confirmation_sent(p_store_id uuid, p_order_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_order app.orders;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  v_order := app.lock_order(p_store_id, p_order_id, null);
  if v_order.status not in ('approved', 'processing', 'dispatched', 'delivered', 'delivery_failed') then
    perform app.invalid_transition(v_order, v_order.status);
  end if;
  if v_order.confirmation_marked_sent_at is null then
    update app.orders set confirmation_marked_sent_at = now(), version = version + 1, updated_at = now()
     where id = p_order_id;
    perform app.audit(p_store_id, 'order.confirmation_marked_sent', 'order', p_order_id, null,
                      jsonb_build_object('marked_sent', true));
  end if;
  return app.ok(app.order_json(p_order_id));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('mark_confirmation_sent', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.update_order_note: the internal note stays editable in every status (BR-33).
-- ---------------------------------------------------------------------------------------------
create function api.update_order_note(p_store_id uuid, p_order_id uuid, p_expected_version integer, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_order app.orders;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.edit_draft');
  if char_length(coalesce(v_note, '')) > 500 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"internal_note": "too_long"}}');
  end if;
  v_order := app.lock_order(p_store_id, p_order_id, p_expected_version);
  if v_order.internal_note is not distinct from v_note then
    return app.ok(app.order_json(p_order_id));
  end if;
  perform app.check_version(v_order, p_expected_version);
  update app.orders set internal_note = v_note, version = version + 1, updated_at = now() where id = p_order_id;
  perform app.audit(p_store_id, 'order.note', 'order', p_order_id, jsonb_build_object('internal_note', v_order.internal_note),
                    jsonb_build_object('internal_note', v_note));
  return app.ok(app.order_json(p_order_id));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('update_order_note', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reads (members only).
-- Filters (OR-01): needs_approval, drafts, active (approved, processing, dispatched), delivered,
-- problems (delivery failed, or delivered with cash outstanding), closed (rejected, cancelled,
-- returned), test, all. Test orders appear only under Test.
-- ---------------------------------------------------------------------------------------------
create function app.order_matches_filter(p_order app.orders, p_filter text)
returns boolean language sql immutable
as $$
  select case p_filter
    when 'test' then p_order.is_test
    else not p_order.is_test and case p_filter
      when 'all' then true
      when 'needs_approval' then p_order.status = 'pending_approval'
      when 'drafts' then p_order.status = 'draft'
      when 'active' then p_order.status in ('approved', 'processing', 'dispatched')
      when 'delivered' then p_order.status = 'delivered'
      when 'problems' then p_order.status = 'delivery_failed'
                           or (p_order.status = 'delivered' and p_order.cod_collected < p_order.cod_due)
      when 'closed' then p_order.status in ('rejected', 'cancelled', 'returned')
      else false end
  end;
$$;

create function api.list_orders(
  p_store_id uuid,
  p_query text default null,
  p_filter text default 'all',
  p_limit integer default 30,
  p_offset integer default 0
)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_query text := app.search_normalize(p_query);
  v_digits text;
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 50);
  v_offset integer := least(greatest(coalesce(p_offset, 0), 0), 100000);
  v_items jsonb;
  v_count integer;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  if coalesce(p_filter, 'all') not in ('all', 'needs_approval', 'drafts', 'active', 'delivered', 'problems',
                                       'closed', 'test') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"filter": "invalid"}}');
  end if;
  v_digits := regexp_replace(v_query, '[^0-9]', '', 'g');
  v_query := replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_');

  with rows as (
    select o.*, row_number() over (order by o.created_at desc, o.number desc) as ord
      from app.orders o
     where o.store_id = p_store_id
       and app.order_matches_filter(o, coalesce(p_filter, 'all'))
       and (v_query = ''
            or o.search_text like '%' || v_query || '%'
            or (char_length(v_digits) >= 4 and o.phone_digits like '%' || v_digits || '%')
            or v_digits = o.number::text)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'number', r.number, 'status', r.status, 'origin', r.origin, 'is_test', r.is_test,
           'customer_name', r.customer_name, 'customer_phone', r.customer_phone,
           'total', r.total, 'currency', r.currency,
           'cod_outstanding', case when r.status in ('dispatched', 'delivered') then greatest(r.cod_due - r.cod_collected, 0) else 0 end,
           'item_count', (select count(*) from app.order_items l where l.order_id = r.id),
           'unit_count', (select coalesce(sum(l.quantity), 0) from app.order_items l where l.order_id = r.id),
           'first_item', (select jsonb_build_object('name', l.name_snapshot, 'variant_label', l.variant_label_snapshot,
                                                     'quantity', l.quantity)
                            from app.order_items l where l.order_id = r.id order by l.position, l.id limit 1),
           'issue_count', case when r.status = 'draft' then jsonb_array_length(app.order_issues(r.id)) else 0 end,
           'created_at', r.created_at, 'status_changed_at', r.status_changed_at, 'version', r.version)
           order by r.ord) filter (where r.ord > v_offset and r.ord <= v_offset + v_limit), '[]'::jsonb),
         count(*)::integer
    into v_items, v_count
    from rows r;

  return app.ok(jsonb_build_object('items', v_items, 'total', v_count, 'has_more', v_count > v_offset + v_limit));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_orders', v_state, v_code);
end;
$$;

-- Counts for the filter chips and Today (each equals its list's total; tested), plus the cash
-- outstanding on dispatched and delivered orders (BR-43). Test orders are excluded except `test`.
create function api.order_summary(p_store_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_result jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  select jsonb_build_object(
    'all', count(*) filter (where app.order_matches_filter(o, 'all')),
    'needs_approval', count(*) filter (where app.order_matches_filter(o, 'needs_approval')),
    'drafts', count(*) filter (where app.order_matches_filter(o, 'drafts')),
    'active', count(*) filter (where app.order_matches_filter(o, 'active')),
    'delivered', count(*) filter (where app.order_matches_filter(o, 'delivered')),
    'problems', count(*) filter (where app.order_matches_filter(o, 'problems')),
    'closed', count(*) filter (where app.order_matches_filter(o, 'closed')),
    'test', count(*) filter (where app.order_matches_filter(o, 'test')),
    'cod_outstanding', coalesce(sum(greatest(o.cod_due - o.cod_collected, 0))
                                filter (where not o.is_test and o.status in ('dispatched', 'delivered')), 0),
    'currency', (select currency from app.stores where id = p_store_id))
    into v_result
    from app.orders o where o.store_id = p_store_id;
  return app.ok(v_result);
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('order_summary', v_state, v_code);
end;
$$;

create function api.get_order(p_store_id uuid, p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  if not exists (select 1 from app.orders where id = p_order_id and store_id = p_store_id) then
    perform app.fail('NOT_FOUND');
  end if;
  return app.ok(app.order_json(p_order_id));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('get_order', v_state, v_code);
end;
$$;

-- Full history (OR-11): status events plus the edits, notes, cash and confirmation marks from
-- the audit, oldest first. Never empty: creation is always an event.
create function api.order_history(p_store_id uuid, p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_items jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  if not exists (select 1 from app.orders where id = p_order_id and store_id = p_store_id) then
    perform app.fail('NOT_FOUND');
  end if;
  -- Within one request an edit and the status change it causes share a timestamp: the edit first.
  select coalesce(jsonb_agg(h.j order by h.at, h.rank, h.seq), '[]'::jsonb) into v_items
    from (
      select e.created_at as at, 1 as rank, e.id as seq, jsonb_build_object(
               'kind', 'status', 'from', e.from_status, 'to', e.to_status,
               'actor', case when e.actor_system is not null then 'system' else app.actor_label(e.actor_user_id) end,
               'reason', e.reason, 'note', e.note, 'created_at', e.created_at) as j
        from app.order_status_events e where e.order_id = p_order_id and e.store_id = p_store_id
      union all
      select a.created_at, 0, a.id, jsonb_build_object(
               'kind', case a.action when 'order.update_draft' then 'edit' when 'order.edit' then 'edit'
                                     when 'order.note' then 'note' when 'order.cod' then 'cash'
                                     else 'confirmation' end,
               'actor', app.actor_label(a.actor_user_id), 'before', a.before, 'after', a.after,
               'created_at', a.created_at)
        from app.audit_events a
       where a.store_id = p_store_id and a.entity_type = 'order' and a.entity_id = p_order_id
         and a.action in ('order.update_draft', 'order.edit', 'order.note', 'order.cod', 'order.confirmation_marked_sent')
    ) h;
  return app.ok(jsonb_build_object('items', v_items));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('order_history', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Inventory history now names the order of an order movement (PR-06 "Order #1042").
-- ---------------------------------------------------------------------------------------------
create or replace function api.list_inventory_movements(
  p_store_id uuid,
  p_product_id uuid,
  p_variant_id uuid default null,
  p_limit integer default 50,
  p_before_id bigint default null
)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_items jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  if not exists (select 1 from app.products where id = p_product_id and store_id = p_store_id) then
    perform app.fail('NOT_FOUND');
  end if;
  select coalesce(jsonb_agg(m.j order by m.id desc), '[]'::jsonb) into v_items
    from (
      select mv.id, jsonb_build_object(
               'id', mv.id, 'variant_id', mv.variant_id, 'variant_label', v.label,
               'delta', mv.delta, 'resulting_qty', mv.resulting_qty, 'reason', mv.reason,
               'note', mv.note, 'created_at', mv.created_at,
               'order_id', mv.order_id, 'order_number', o.number,
               'actor', case when mv.actor_user_id is null then 'system'
                             when mv.actor_user_id = (select auth.uid()) then 'you'
                             else 'member' end) as j
        from app.inventory_movements mv
        join app.product_variants v on v.id = mv.variant_id
        left join app.orders o on o.id = mv.order_id
       where v.product_id = p_product_id and mv.store_id = p_store_id
         and (p_variant_id is null or mv.variant_id = p_variant_id)
         and (p_before_id is null or mv.id < p_before_id)
       order by mv.id desc
       limit v_limit + 1
    ) m;
  return app.ok(jsonb_build_object(
    'items', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                select x from jsonb_array_elements(v_items) with ordinality as e(x, o) where o <= v_limit) s),
    'has_more', jsonb_array_length(v_items) > v_limit));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_inventory_movements', v_state, v_code);
end;
$$;

-- Order consistency (reconciliation): units held by order lines equal the order movements.
create function internal.order_stock_mismatches()
returns table (order_id uuid, variant_id uuid, held bigint, ledger bigint)
language sql stable security definer set search_path = ''
as $$
  select coalesce(h.order_id, m.order_id), coalesce(h.variant_id, m.variant_id),
         coalesce(h.held, 0), coalesce(m.ledger, 0)
    from (select l.order_id, l.variant_id, sum(l.stock_deducted)::bigint as held
            from app.order_items l where l.variant_id is not null group by 1, 2) h
    full join (select mv.order_id, mv.variant_id, -sum(mv.delta)::bigint as ledger
                 from app.inventory_movements mv where mv.order_id is not null group by 1, 2) m
      on m.order_id = h.order_id and m.variant_id = h.variant_id
   where coalesce(h.held, 0) <> coalesce(m.ledger, 0);
$$;

create or replace function internal.check_inventory_reconciliation()
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_count integer;
  v_orders integer;
begin
  select count(*) into v_count from internal.inventory_mismatches();
  if v_count > 0 then
    raise warning 'inventory reconciliation: % variant(s) whose stock differs from the ledger', v_count;
  end if;
  select count(*) into v_orders from internal.order_stock_mismatches();
  if v_orders > 0 then
    raise warning 'inventory reconciliation: % order line(s) whose held stock differs from the ledger', v_orders;
  end if;
  return v_count + v_orders;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Account purge: orders and their history go before the catalog and the store.
-- ---------------------------------------------------------------------------------------------
create or replace function internal.purge_due_account_deletions()
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_request app.account_deletion_requests;
  v_count integer := 0;
begin
  perform set_config('aisellia.purge', 'on', true);
  for v_request in
    select * from app.account_deletion_requests
     where status = 'pending' and execute_after <= now()
     order by execute_after
     for update skip locked
  loop
    if v_request.store_id is not null then
      delete from app.cod_collections where store_id = v_request.store_id;
      delete from app.return_lines where store_id = v_request.store_id;
      delete from app.order_status_events where store_id = v_request.store_id;
      delete from app.inventory_movements where store_id = v_request.store_id;
      delete from app.order_items where store_id = v_request.store_id;
      delete from app.orders where store_id = v_request.store_id;
      delete from app.product_images where store_id = v_request.store_id;
      delete from app.product_variants where store_id = v_request.store_id;
      delete from app.products where store_id = v_request.store_id;
      delete from app.delivery_zones where store_id = v_request.store_id;
      delete from app.audit_events where store_id = v_request.store_id;
      delete from app.store_members where store_id = v_request.store_id;
      delete from app.stores where id = v_request.store_id;
    end if;
    delete from app.idempotency_keys where user_id = v_request.user_id;
    delete from auth.users where id = v_request.user_id;   -- profiles cascade
    update app.account_deletion_requests
       set status = 'done', executed_at = now()
     where id = v_request.id;
    v_count := v_count + 1;
  end loop;
  perform set_config('aisellia.purge', 'off', true);
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------
revoke all on function
  app.protect_history(), app.guard_order_status(), app.protect_ordered_variant(), app.actor_label(uuid),
  app.order_issues(uuid), app.order_json(uuid), app.order_audit_state(uuid), app.jsonb_changed(jsonb, jsonb, text),
  app.order_recompute(uuid, jsonb), app.order_field_errors(uuid, jsonb, uuid), app.order_write_header(uuid, jsonb),
  app.order_write_draft_lines(uuid, uuid, jsonb), app.order_set_status(uuid, text, text, text, boolean),
  app.order_reevaluate(uuid), app.order_move_stock(uuid, uuid, uuid, integer, text),
  app.lock_order(uuid, uuid, integer), app.check_version(app.orders, integer),
  app.invalid_transition(app.orders, text), app.lock_variants(uuid[]),
  app.order_matches_filter(app.orders, text),
  api.create_order(uuid, jsonb, uuid),
  api.update_draft(uuid, uuid, integer, jsonb, uuid),
  api.approve_order(uuid, uuid, integer, jsonb, uuid),
  api.reject_draft(uuid, uuid, integer, text, text, uuid),
  api.edit_approved_order(uuid, uuid, integer, jsonb, uuid),
  api.cancel_order(uuid, uuid, integer, text, text, uuid),
  api.transition_order(uuid, uuid, integer, text, jsonb, uuid),
  api.record_return(uuid, uuid, integer, jsonb, text, uuid),
  api.record_cod(uuid, uuid, bigint, uuid),
  api.mark_confirmation_sent(uuid, uuid),
  api.update_order_note(uuid, uuid, integer, text),
  api.list_orders(uuid, text, text, integer, integer),
  api.order_summary(uuid),
  api.get_order(uuid, uuid),
  api.order_history(uuid, uuid),
  internal.order_stock_mismatches()
from public, anon, authenticated;

grant execute on function
  api.create_order(uuid, jsonb, uuid),
  api.update_draft(uuid, uuid, integer, jsonb, uuid),
  api.approve_order(uuid, uuid, integer, jsonb, uuid),
  api.reject_draft(uuid, uuid, integer, text, text, uuid),
  api.edit_approved_order(uuid, uuid, integer, jsonb, uuid),
  api.cancel_order(uuid, uuid, integer, text, text, uuid),
  api.transition_order(uuid, uuid, integer, text, jsonb, uuid),
  api.record_return(uuid, uuid, integer, jsonb, text, uuid),
  api.record_cod(uuid, uuid, bigint, uuid),
  api.mark_confirmation_sent(uuid, uuid),
  api.update_order_note(uuid, uuid, integer, text),
  api.list_orders(uuid, text, text, integer, integer),
  api.order_summary(uuid),
  api.get_order(uuid, uuid),
  api.order_history(uuid, uuid)
to authenticated;
grant execute on function internal.order_stock_mismatches() to service_role;
