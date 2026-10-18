-- Phase 10 (roadmap R8): fulfilment extensions (docs/implementation/phase-10/fulfilment-extensions.md).
--  * Couriers: a store's courier records (name, optional phone); an order dispatched with a courier
--    keeps it (orders.courier_id). The free-text courier note stays.
--  * Delivery lists: ready orders (approved, processing, delivery_failed) grouped into a numbered list
--    for one courier; "handed over" dispatches them all, or none (each must pass the same checks as
--    a single dispatch). An order is on at most one open list.
--  * Payments (record only): transfers and wallets recorded against orders paid "other"; the paid
--    total never exceeds the order total. Nothing moves money.
--  * Courier settlement: cash a courier hands over is spread over that courier's oldest delivered
--    COD orders through the existing cash collections (never more than what is owed).
-- Functions-only writes, as everywhere: tables are readable by members, written only by api.*.

create table app.couriers (
  id         uuid primary key default gen_random_uuid(),
  store_id   uuid not null references app.stores (id),
  name       text not null check (char_length(name) between 1 and 60 and name = btrim(name)),
  phone      text check (phone is null or phone ~ '^\+9647[0-9]{9}$'),
  active     boolean not null default true,
  version    integer not null default 1 check (version >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (store_id, id)
);
create unique index couriers_active_name on app.couriers (store_id, lower(name)) where active;

alter table app.orders add column courier_id uuid,
  add constraint orders_courier_fk foreign key (store_id, courier_id) references app.couriers (store_id, id);
create index orders_courier on app.orders (store_id, courier_id, status) where courier_id is not null;
alter table app.stores add column last_delivery_list_number integer not null default 0;

create table app.delivery_lists (
  id              uuid primary key default gen_random_uuid(),
  store_id        uuid not null references app.stores (id),
  number          integer not null check (number >= 1),
  courier_id      uuid,
  status          text not null default 'open' check (status in ('open', 'handed_over', 'cancelled')),
  created_by      uuid not null,
  handed_over_by  uuid,
  handed_over_at  timestamptz,
  version         integer not null default 1 check (version >= 1),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (store_id, id),
  unique (store_id, number),
  foreign key (store_id, courier_id) references app.couriers (store_id, id),
  constraint delivery_lists_handed_over check ((status = 'handed_over') = (handed_over_at is not null))
);

create table app.delivery_list_orders (
  store_id  uuid not null,
  list_id   uuid not null,
  order_id  uuid not null,
  position  integer not null check (position >= 0),
  primary key (list_id, order_id),
  foreign key (store_id, list_id) references app.delivery_lists (store_id, id),
  foreign key (store_id, order_id) references app.orders (store_id, id)
);
create index delivery_list_orders_order on app.delivery_list_orders (order_id);

create table app.order_payments (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null,
  order_id     uuid not null,
  method       text not null check (method in ('fib', 'fastpay', 'zaincash', 'asiahawala', 'bank_transfer', 'other')),
  amount       bigint not null check (amount between 1 and 1000000000000),
  reference    text check (reference is null or (char_length(reference) between 1 and 60 and reference = btrim(reference))),
  recorded_by  uuid not null,
  recorded_at  timestamptz not null default now(),
  foreign key (store_id, order_id) references app.orders (store_id, id)
);
create index order_payments_order on app.order_payments (order_id, recorded_at);
alter table app.orders add column paid_total bigint not null default 0 check (paid_total >= 0),
  add constraint orders_paid_le_total check (paid_total <= total);

create table app.courier_settlements (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null,
  courier_id   uuid not null,
  amount       bigint not null check (amount >= 1),
  recorded_by  uuid not null,
  recorded_at  timestamptz not null default now(),
  unique (store_id, id),
  foreign key (store_id, courier_id) references app.couriers (store_id, id)
);
alter table app.cod_collections add column settlement_id uuid references app.courier_settlements (id);

alter table app.couriers enable row level security;
alter table app.delivery_lists enable row level security;
alter table app.delivery_list_orders enable row level security;
alter table app.order_payments enable row level security;
alter table app.courier_settlements enable row level security;
create policy couriers_select_member on app.couriers for select to authenticated using (app.is_member(store_id));
create policy delivery_lists_select_member on app.delivery_lists for select to authenticated using (app.is_member(store_id));
create policy delivery_list_orders_select_member on app.delivery_list_orders for select to authenticated using (app.is_member(store_id));
create policy order_payments_select_member on app.order_payments for select to authenticated using (app.is_member(store_id));
create policy courier_settlements_select_member on app.courier_settlements for select to authenticated using (app.is_member(store_id));
revoke all on app.couriers, app.delivery_lists, app.delivery_list_orders, app.order_payments, app.courier_settlements
  from public, anon, authenticated;
grant select on app.couriers, app.delivery_lists, app.delivery_list_orders, app.order_payments, app.courier_settlements
  to authenticated;

-- ---- Helpers --------------------------------------------------------------------------------------------------------

create function app.courier_json(c app.couriers)
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'id', c.id, 'name', c.name, 'phone', c.phone, 'active', c.active, 'version', c.version,
    -- Delivered cash-on-delivery orders whose cash the courier still owes the store.
    'owed', coalesce((select sum(o.cod_due - o.cod_collected) from app.orders o
                       where o.store_id = c.store_id and o.courier_id = c.id and o.status = 'delivered'
                         and o.payment_method = 'cod' and o.cod_due > o.cod_collected), 0),
    'owed_orders', (select count(*) from app.orders o
                     where o.store_id = c.store_id and o.courier_id = c.id and o.status = 'delivered'
                       and o.payment_method = 'cod' and o.cod_due > o.cod_collected),
    -- Cash still to be collected on orders the courier is delivering.
    'carrying', coalesce((select sum(o.cod_due - o.cod_collected) from app.orders o
                           where o.store_id = c.store_id and o.courier_id = c.id and o.status = 'dispatched'
                             and o.payment_method = 'cod'), 0),
    'carrying_orders', (select count(*) from app.orders o
                         where o.store_id = c.store_id and o.courier_id = c.id and o.status = 'dispatched'));
$$;

create function app.courier_of(p_store_id uuid, p_courier_id uuid, p_active_only boolean)
returns app.couriers
language plpgsql stable
as $$
declare
  v app.couriers;
begin
  select * into v from app.couriers where id = p_courier_id and store_id = p_store_id;
  if not found or (p_active_only and not v.active) then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"courier_id": "invalid"}}');
  end if;
  return v;
end;
$$;

-- The open list an order is on (at most one).
create function app.open_list_of(p_order_id uuid)
returns uuid language sql stable
as $$
  select l.id from app.delivery_list_orders lo join app.delivery_lists l on l.id = lo.list_id
   where lo.order_id = p_order_id and l.status = 'open' limit 1;
$$;

create function app.delivery_list_json(p_list_id uuid, p_with_stops boolean)
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'id', l.id, 'number', l.number, 'status', l.status, 'version', l.version,
    'courier', (select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone) from app.couriers c where c.id = l.courier_id),
    'created_at', l.created_at, 'handed_over_at', l.handed_over_at,
    'order_count', (select count(*) from app.delivery_list_orders lo where lo.list_id = l.id),
    'cod_total', coalesce((select sum(o.cod_due - o.cod_collected) from app.delivery_list_orders lo
                             join app.orders o on o.id = lo.order_id
                            where lo.list_id = l.id and o.payment_method = 'cod'), 0))
    || case when p_with_stops then jsonb_build_object('stops', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'order_id', o.id, 'number', o.number, 'status', o.status, 'version', o.version,
                  'customer_name', o.customer_name, 'phone', o.customer_phone, 'phone2', o.customer_phone2,
                  'zone', o.zone_name, 'city', o.city_text, 'area', o.area, 'landmark', o.landmark,
                  'address', o.address_details, 'customer_note', o.customer_note,
                  'payment_method', o.payment_method, 'currency', o.currency, 'total', o.total,
                  'cash_to_collect', case when o.payment_method = 'cod' then o.cod_due - o.cod_collected else 0 end,
                  'issues', app.order_issues(o.id),
                  'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.name_snapshot, 'variant', i.variant_label_snapshot,
                                                                         'quantity', i.quantity) order by i.position)
                                       from app.order_items i where i.order_id = o.id), '[]'::jsonb))
                order by lo.position)
           from app.delivery_list_orders lo join app.orders o on o.id = lo.order_id
          where lo.list_id = l.id), '[]'::jsonb))
       else '{}'::jsonb end
  from app.delivery_lists l where l.id = p_list_id;
$$;

-- ---- Couriers ---------------------------------------------------------------------------------------------------------

create function api.list_couriers(p_store_id uuid, p_include_inactive boolean)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  return app.ok(jsonb_build_object('items', coalesce((
    select jsonb_agg(app.courier_json(c) order by not c.active, lower(c.name))
      from app.couriers c where c.store_id = p_store_id and (c.active or coalesce(p_include_inactive, false))), '[]'::jsonb)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_couriers', v_state, v_code);
end;
$$;

-- Creates (p_courier_id null) or updates a courier; p_active false deactivates (history stays).
create function api.upsert_courier(p_store_id uuid, p_courier_id uuid, p_expected_version integer, p_name text,
                                   p_phone text, p_active boolean, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_hash text;
  v_result jsonb;
  v_name text := btrim(coalesce(p_name, ''));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_c app.couriers;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'settings.manage');
  if char_length(v_name) not between 1 and 60 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"name": "invalid"}}');
  end if;
  if v_phone is not null and v_phone !~ '^\+9647[0-9]{9}$' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"phone": "invalid"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'courier_id', p_courier_id, 'version', p_expected_version,
                                                'name', v_name, 'phone', v_phone, 'active', p_active));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'upsert_courier', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  if p_courier_id is null then
    if (select count(*) from app.couriers where store_id = p_store_id) >= 50 then
      perform app.fail('LIMIT_EXCEEDED', '{"limit": 50}');
    end if;
    insert into app.couriers (store_id, name, phone) values (p_store_id, v_name, v_phone) returning * into v_c;
    perform app.audit(p_store_id, 'courier.created', 'courier', v_c.id, null, jsonb_build_object('name', v_name));
  else
    select * into v_c from app.couriers where id = p_courier_id and store_id = p_store_id for update;
    if not found then
      perform app.fail('NOT_FOUND');
    end if;
    if p_expected_version is distinct from v_c.version then
      perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_c.version));
    end if;
    update app.couriers set name = v_name, phone = v_phone, active = coalesce(p_active, active),
                            version = version + 1, updated_at = now()
     where id = v_c.id returning * into v_c;
    perform app.audit(p_store_id, 'courier.updated', 'courier', v_c.id, null,
                      jsonb_build_object('name', v_name, 'active', v_c.active));
  end if;
  v_result := app.ok(app.courier_json(v_c));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'upsert_courier', v_hash, v_result);
  return v_result;
exception
  when unique_violation then
    return app.err('VALIDATION_FAILED', '{"fields": {"name": "duplicate"}}'::jsonb);
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('upsert_courier', v_state, v_code);
end;
$$;

-- ---- Delivery lists ---------------------------------------------------------------------------------------------------

create function api.list_delivery_lists(p_store_id uuid, p_status text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  if p_status is not null and p_status not in ('open', 'handed_over', 'cancelled') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"status": "invalid"}}');
  end if;
  return app.ok(jsonb_build_object('items', coalesce((
    select jsonb_agg(app.delivery_list_json(l.id, false) order by l.number desc)
      from (select id, number from app.delivery_lists
             where store_id = p_store_id and (p_status is null or status = p_status)
             order by number desc limit 100) l), '[]'::jsonb),
    -- Orders that can go on a new list: ready to leave and not on an open list.
    'ready', coalesce((
    select jsonb_agg(jsonb_build_object('order_id', o.id, 'number', o.number, 'status', o.status,
                                        'customer_name', o.customer_name, 'zone', o.zone_name, 'area', o.area,
                                        'total', o.total, 'currency', o.currency, 'payment_method', o.payment_method,
                                        'complete', app.order_issues(o.id) = '[]'::jsonb) order by o.number)
      from app.orders o
     where o.store_id = p_store_id and not o.is_test and o.status in ('approved', 'processing', 'delivery_failed')
       and app.open_list_of(o.id) is null), '[]'::jsonb)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_delivery_lists', v_state, v_code);
end;
$$;

create function api.get_delivery_list(p_store_id uuid, p_list_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  if not exists (select 1 from app.delivery_lists where id = p_list_id and store_id = p_store_id) then
    perform app.fail('NOT_FOUND');
  end if;
  return app.ok(app.delivery_list_json(p_list_id, true));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('get_delivery_list', v_state, v_code);
end;
$$;

-- Validates and locks the orders of a list (ready, real, not on another open list).
create function app.lock_list_orders(p_store_id uuid, p_order_ids uuid[], p_list_id uuid)
returns void
language plpgsql
as $$
declare
  v_id uuid;
  v_order app.orders;
  v_other uuid;
begin
  if p_order_ids is null or cardinality(p_order_ids) = 0 or cardinality(p_order_ids) > 60
     or cardinality(p_order_ids) <> (select count(distinct x) from unnest(p_order_ids) x) then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"order_ids": "invalid"}}');
  end if;
  -- Locked in id order, so two lists built at once cannot deadlock.
  for v_id in select x from unnest(p_order_ids) x order by x loop
    v_order := app.lock_order(p_store_id, v_id, null);
    if v_order.is_test or v_order.status not in ('approved', 'processing', 'delivery_failed') then
      perform app.fail('INVALID_TRANSITION', jsonb_build_object('order_number', v_order.number, 'current_status', v_order.status));
    end if;
    v_other := app.open_list_of(v_id);
    if v_other is not null and v_other is distinct from p_list_id then
      perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', '{"order_ids": "on_another_list"}'::jsonb,
                                                               'order_number', v_order.number));
    end if;
  end loop;
end;
$$;

create function api.create_delivery_list(p_store_id uuid, p_courier_id uuid, p_order_ids uuid[], p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_hash text;
  v_result jsonb;
  v_number integer;
  v_list app.delivery_lists;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'courier_id', p_courier_id, 'order_ids', to_jsonb(p_order_ids)));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'create_delivery_list', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  if p_courier_id is not null then
    perform app.courier_of(p_store_id, p_courier_id, true);
  end if;
  update app.stores set last_delivery_list_number = last_delivery_list_number + 1 where id = p_store_id
  returning last_delivery_list_number into v_number;
  perform app.lock_list_orders(p_store_id, p_order_ids, null);
  insert into app.delivery_lists (store_id, number, courier_id, created_by)
  values (p_store_id, v_number, p_courier_id, v_uid) returning * into v_list;
  insert into app.delivery_list_orders (store_id, list_id, order_id, position)
  select p_store_id, v_list.id, x, o - 1 from unnest(p_order_ids) with ordinality u(x, o);
  perform app.audit(p_store_id, 'delivery_list.created', 'delivery_list', v_list.id, null,
                    jsonb_build_object('number', v_number, 'orders', cardinality(p_order_ids)));
  v_result := app.ok(app.delivery_list_json(v_list.id, true));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'create_delivery_list', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('create_delivery_list', v_state, v_code);
end;
$$;

-- p_action: 'set_orders' (replace the orders and courier of an open list), 'hand_over' (dispatch
-- every order with the list's courier, all or nothing) or 'cancel' (an open list is dropped).
create function api.update_delivery_list(p_store_id uuid, p_list_id uuid, p_expected_version integer, p_action text,
                                         p_courier_id uuid, p_order_ids uuid[], p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_hash text;
  v_result jsonb;
  v_list app.delivery_lists;
  v_order app.orders;
  v_id uuid;
  v_issues jsonb;
  v_blocked jsonb := '[]'::jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  if p_action is null or p_action not in ('set_orders', 'hand_over', 'cancel') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"action": "invalid"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'list_id', p_list_id, 'version', p_expected_version,
                                                'action', p_action, 'courier_id', p_courier_id, 'order_ids', to_jsonb(p_order_ids)));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'update_delivery_list', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  select * into v_list from app.delivery_lists where id = p_list_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_list.status <> 'open' then
    perform app.fail('INVALID_TRANSITION', jsonb_build_object('current_status', v_list.status));
  end if;
  if p_expected_version is distinct from v_list.version then
    perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_list.version));
  end if;

  if p_action = 'set_orders' then
    if p_courier_id is not null then
      perform app.courier_of(p_store_id, p_courier_id, true);
    end if;
    perform app.lock_list_orders(p_store_id, p_order_ids, v_list.id);
    delete from app.delivery_list_orders where list_id = v_list.id;
    insert into app.delivery_list_orders (store_id, list_id, order_id, position)
    select p_store_id, v_list.id, x, o - 1 from unnest(p_order_ids) with ordinality u(x, o);
    update app.delivery_lists set courier_id = p_courier_id, version = version + 1, updated_at = now() where id = v_list.id;
  elsif p_action = 'cancel' then
    update app.delivery_lists set status = 'cancelled', version = version + 1, updated_at = now() where id = v_list.id;
  else
    -- Hand over: the courier must still be active; every order must still be ready and complete.
    if v_list.courier_id is null then
      perform app.fail('VALIDATION_FAILED', '{"fields": {"courier_id": "required"}}');
    end if;
    perform app.courier_of(p_store_id, v_list.courier_id, true);
    for v_id in select order_id from app.delivery_list_orders where list_id = v_list.id order by order_id loop
      v_order := app.lock_order(p_store_id, v_id, null);
      v_issues := app.order_issues(v_id);
      if v_order.status not in ('approved', 'processing', 'delivery_failed') or v_issues <> '[]'::jsonb then
        v_blocked := v_blocked || jsonb_build_object('order_number', v_order.number, 'status', v_order.status, 'issues', v_issues);
      end if;
    end loop;
    if v_blocked <> '[]'::jsonb then
      perform app.fail('INCOMPLETE_ORDER', jsonb_build_object('orders', v_blocked));
    end if;
    for v_id in select order_id from app.delivery_list_orders where list_id = v_list.id order by position loop
      update app.orders set courier_id = v_list.courier_id, failure_reason = null, version = version + 1 where id = v_id;
      perform app.order_set_status(v_id, 'dispatched', null, 'delivery list #' || v_list.number);
      perform app.audit(p_store_id, 'order.transition', 'order', v_id, null,
                        jsonb_build_object('status', 'dispatched', 'delivery_list', v_list.number));
    end loop;
    update app.delivery_lists set status = 'handed_over', handed_over_at = now(), handed_over_by = v_uid,
                                  version = version + 1, updated_at = now()
     where id = v_list.id;
  end if;
  perform app.audit(p_store_id, 'delivery_list.' || p_action, 'delivery_list', v_list.id, null,
                    jsonb_build_object('number', v_list.number));
  v_result := app.ok(app.delivery_list_json(v_list.id, true));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'update_delivery_list', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('update_delivery_list', v_state, v_code);
end;
$$;

-- ---- Payments (record only) -------------------------------------------------------------------------------------------

create function api.record_payment(p_store_id uuid, p_order_id uuid, p_method text, p_amount bigint, p_reference text,
                                   p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_hash text;
  v_result jsonb;
  v_order app.orders;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  if p_method is null or p_method not in ('fib', 'fastpay', 'zaincash', 'asiahawala', 'bank_transfer', 'other') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"method": "invalid"}}');
  end if;
  if p_amount is null or p_amount <= 0 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"amount": "out_of_range"}}');
  end if;
  if char_length(coalesce(v_ref, '')) > 60 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"reference": "too_long"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'order_id', p_order_id, 'method', p_method,
                                                'amount', p_amount, 'reference', v_ref));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'record_payment', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  v_order := app.lock_order(p_store_id, p_order_id, null);
  -- Transfers and wallets belong to orders paid "other"; cash on delivery has its own path.
  if v_order.payment_method is distinct from 'other'
     or v_order.status not in ('approved', 'processing', 'dispatched', 'delivered', 'delivery_failed') then
    perform app.invalid_transition(v_order, v_order.status);
  end if;
  if v_order.paid_total + p_amount > v_order.total then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', '{"amount": "exceeds_due"}'::jsonb,
                                                             'outstanding', v_order.total - v_order.paid_total));
  end if;
  insert into app.order_payments (store_id, order_id, method, amount, reference, recorded_by)
  values (p_store_id, p_order_id, p_method, p_amount, v_ref, v_uid);
  update app.orders set paid_total = paid_total + p_amount, version = version + 1, updated_at = now() where id = p_order_id;
  perform app.audit(p_store_id, 'order.payment', 'order', p_order_id, jsonb_build_object('paid_total', v_order.paid_total),
                    jsonb_build_object('paid_total', v_order.paid_total + p_amount, 'method', p_method, 'amount', p_amount));
  v_result := app.ok(app.order_json(p_order_id));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'record_payment', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('record_payment', v_state, v_code);
end;
$$;

-- ---- Courier settlement -----------------------------------------------------------------------------------------------

-- Cash a courier hands over, spread over the courier's delivered COD orders, oldest delivery first.
create function api.settle_courier(p_store_id uuid, p_courier_id uuid, p_amount bigint, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_hash text;
  v_result jsonb;
  v_courier app.couriers;
  v_owed bigint;
  v_left bigint := p_amount;
  v_take bigint;
  v_settlement uuid;
  v_alloc jsonb := '[]'::jsonb;
  v_o record;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'orders.fulfil');
  if p_amount is null or p_amount <= 0 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"amount": "out_of_range"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'courier_id', p_courier_id, 'amount', p_amount));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'settle_courier', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  -- The courier row serialises settlements of the same courier.
  select * into v_courier from app.couriers where id = p_courier_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  select coalesce(sum(cod_due - cod_collected), 0) into v_owed from app.orders
   where store_id = p_store_id and courier_id = p_courier_id and status = 'delivered' and payment_method = 'cod'
     and cod_due > cod_collected;
  if p_amount > v_owed then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', '{"amount": "exceeds_due"}'::jsonb, 'owed', v_owed));
  end if;
  insert into app.courier_settlements (store_id, courier_id, amount, recorded_by)
  values (p_store_id, p_courier_id, p_amount, v_uid) returning id into v_settlement;
  for v_o in select id, number, cod_due - cod_collected as due from app.orders
              where store_id = p_store_id and courier_id = p_courier_id and status = 'delivered' and payment_method = 'cod'
                and cod_due > cod_collected
              order by status_changed_at, number for update loop
    exit when v_left = 0;
    v_take := least(v_left, v_o.due);
    insert into app.cod_collections (store_id, order_id, amount, recorded_by, settlement_id)
    values (p_store_id, v_o.id, v_take, v_uid, v_settlement);
    update app.orders set cod_collected = cod_collected + v_take, version = version + 1, updated_at = now() where id = v_o.id;
    perform app.audit(p_store_id, 'order.cod', 'order', v_o.id, null,
                      jsonb_build_object('amount', v_take, 'settlement', v_settlement));
    v_alloc := v_alloc || jsonb_build_object('order_id', v_o.id, 'number', v_o.number, 'amount', v_take);
    v_left := v_left - v_take;
  end loop;
  perform app.audit(p_store_id, 'courier.settled', 'courier', p_courier_id, null,
                    jsonb_build_object('amount', p_amount, 'orders', jsonb_array_length(v_alloc)));
  select * into v_courier from app.couriers where id = p_courier_id;
  v_result := app.ok(jsonb_build_object('settlement_id', v_settlement, 'allocations', v_alloc,
                                        'courier', app.courier_json(v_courier)));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'settle_courier', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('settle_courier', v_state, v_code);
end;
$$;

-- The order as the app sees it, now with its courier, payments and delivery list.
alter function app.order_json(uuid) rename to order_json_core;
create function app.order_json(p_order_id uuid)
returns jsonb language sql stable
as $$
  select b || jsonb_build_object(
    'courier', (select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'active', c.active)
                  from app.orders o join app.couriers c on c.id = o.courier_id where o.id = p_order_id),
    'paid_total', (select paid_total from app.orders where id = p_order_id),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'method', p.method, 'amount', p.amount,
                                                              'reference', p.reference, 'recorded_at', p.recorded_at,
                                                              'by', app.actor_label(p.recorded_by)) order by p.recorded_at)
                            from app.order_payments p where p.order_id = p_order_id), '[]'::jsonb),
    'delivery_list', (select jsonb_build_object('id', l.id, 'number', l.number, 'status', l.status)
                        from app.delivery_list_orders lo join app.delivery_lists l on l.id = lo.list_id
                       where lo.order_id = p_order_id and l.status <> 'cancelled'
                       order by l.created_at desc limit 1))
  from (select app.order_json_core(p_order_id) as b) x
  where b is not null;
$$;
revoke all on function app.order_json(uuid) from public, anon, authenticated;

create or replace function api.transition_order(p_store_id uuid, p_order_id uuid, p_expected_version integer, p_to text,
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
                where k not in ('courier_note', 'cod_collected', 'reason', 'note', 'courier_id') loop
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

  -- Phase 10: a dispatch may name one of the store's active couriers.
  if v_payload ? 'courier_id' and jsonb_typeof(v_payload -> 'courier_id') <> 'null' then
    if p_to <> 'dispatched' or jsonb_typeof(v_payload -> 'courier_id') <> 'string'
       or (v_payload ->> 'courier_id') !~ '^[0-9a-f-]{36}$' then
      perform app.fail('VALIDATION_FAILED', '{"fields": {"courier_id": "invalid"}}');
    end if;
    perform app.courier_of(p_store_id, (v_payload ->> 'courier_id')::uuid, true);
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
    update app.orders set courier_note = coalesce(v_note, courier_note), failure_reason = null,
                          courier_id = coalesce((v_payload ->> 'courier_id')::uuid, courier_id)
     where id = p_order_id;
    -- Dispatched on its own: it leaves any open delivery list.
    delete from app.delivery_list_orders lo using app.delivery_lists l
     where lo.list_id = l.id and l.status = 'open' and lo.order_id = p_order_id;
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
      -- Both Vault secrets of every connection (credential and webhook secret), then connect requests.
      delete from vault.secrets where id in (select credential_ref from app.connections
                                              where store_id = v_request.store_id and credential_ref is not null
                                             union all
                                             select webhook_secret_ref from app.connections
                                              where store_id = v_request.store_id and webhook_secret_ref is not null
                                             union all
                                             select refresh_ref from app.connections
                                              where store_id = v_request.store_id and refresh_ref is not null);
      delete from app.connect_requests where store_id = v_request.store_id;
      delete from app.delivery_events where store_id = v_request.store_id;
      delete from app.send_requests where store_id = v_request.store_id;
      delete from app.message_attachments where store_id = v_request.store_id;
      update app.messages set suggestion_id = null where store_id = v_request.store_id;
      delete from app.messages where store_id = v_request.store_id;
      delete from app.reply_suggestions where store_id = v_request.store_id;
      delete from app.ai_runs where store_id = v_request.store_id;
      delete from app.conversations where store_id = v_request.store_id;
      delete from app.contacts where store_id = v_request.store_id;
      delete from app.webhook_events where store_id = v_request.store_id;
      delete from app.connections where store_id = v_request.store_id;
      delete from app.store_policies where store_id = v_request.store_id;
      delete from app.ai_requests where store_id = v_request.store_id;
      delete from app.ai_draft_grants where store_id = v_request.store_id;
      delete from app.delivery_list_orders where store_id = v_request.store_id;
      delete from app.delivery_lists where store_id = v_request.store_id;
      delete from app.order_payments where store_id = v_request.store_id;
      delete from app.cod_collections where store_id = v_request.store_id;
      delete from app.courier_settlements where store_id = v_request.store_id;
      delete from app.return_lines where store_id = v_request.store_id;
      delete from app.order_status_events where store_id = v_request.store_id;
      delete from app.inventory_movements where store_id = v_request.store_id;
      delete from app.order_items where store_id = v_request.store_id;
      delete from app.orders where store_id = v_request.store_id;
      delete from app.couriers where store_id = v_request.store_id;
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

create or replace function api.anonymize_customer(p_store_id uuid, p_phone text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_member app.store_members;
  v_phone text := btrim(coalesce(p_phone, ''));
  v_hash text;
  v_result jsonb;
  v_done uuid[];
  v_prior uuid[];
  v_targets uuid[];
  v_skipped integer;
  v_notes integer;
  v_id uuid;
  v_contact app.contacts;
  v_conn app.connections;
  v_contacts integer := 0;
  v_contacts_skipped integer := 0;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  v_member := app.require_permission(p_store_id, 'customers.delete');
  if v_member.role <> 'owner' then
    perform app.fail('FORBIDDEN');
  end if;
  if v_phone !~ '^\+9647[0-9]{9}$' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"phone": "invalid"}}');
  end if;
  -- The request names the customer, so only its hash is kept with the key.
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'phone_hash', app.secret_hash(v_phone)));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'anonymize_customer', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  -- Orders still being handled keep their contact data until they are delivered or closed.
  select count(*) into v_skipped from app.orders
   where store_id = p_store_id and customer_anonymized_at is null
     and (customer_phone = v_phone or customer_phone2 = v_phone)
     and status not in ('delivered', 'rejected', 'cancelled', 'returned');

  select coalesce(array_agg(id order by number), '{}') into v_done from (
    select id, number from app.orders
     where store_id = p_store_id and customer_anonymized_at is null
       and (customer_phone = v_phone or customer_phone2 = v_phone)
       and status in ('delivered', 'rejected', 'cancelled', 'returned')
     order by id for update) s;

  -- Orders anonymised before whose notes still carry this number (their names are already gone).
  select coalesce(array_agg(o.id order by o.number), '{}') into v_prior
    from app.orders o
   where o.store_id = p_store_id and o.customer_anonymized_at is not null
     and (concat_ws(' ', o.internal_note, o.closed_note, o.courier_note, o.payment_note)
            <> app.redact_contact_text(concat_ws(' ', o.internal_note, o.closed_note, o.courier_note, o.payment_note), null, array[v_phone])
          or exists (select 1 from app.order_status_events e where e.order_id = o.id and e.note is not null
                        and e.note <> app.redact_contact_text(e.note, null, array[v_phone]))
          or exists (select 1 from app.order_payments p where p.order_id = o.id and p.reference is not null
                        and p.reference <> app.redact_contact_text(p.reference, null, array[v_phone])));
  v_targets := v_done || v_prior;

  -- Notes first, while the name and numbers are still on the order.
  perform set_config('aisellia.redact', 'on', true);
  update app.order_status_events e
     set note = app.redact_contact_text(e.note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone])
    from app.orders o
   where o.id = e.order_id and o.id = any (v_targets) and e.note is not null
     and e.note <> app.redact_contact_text(e.note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]);
  update app.audit_events a
     set before = app.redact_customer(app.redact_contact_json(a.before, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone])),
         after = app.redact_customer(app.redact_contact_json(a.after, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]))
    from app.orders o
   where a.store_id = p_store_id and a.entity_type = 'order' and a.entity_id = o.id and o.id = any (v_targets);
  perform set_config('aisellia.redact', 'off', true);
  -- Payment references (Phase 10) may hold a wallet's phone number: redacted like the notes.
  update app.order_payments p
     set reference = app.redact_contact_text(p.reference, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone])
    from app.orders o
   where o.id = p.order_id and o.id = any (v_targets) and p.reference is not null
     and p.reference <> app.redact_contact_text(p.reference, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]);

  update app.orders o
     set internal_note = app.redact_contact_text(o.internal_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
         closed_note = app.redact_contact_text(o.closed_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
         courier_note = app.redact_contact_text(o.courier_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
         payment_note = app.redact_contact_text(o.payment_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
         version = version + 1, updated_at = now()
   where o.id = any (v_targets)
     and row(o.internal_note, o.closed_note, o.courier_note, o.payment_note) is distinct from row(
           app.redact_contact_text(o.internal_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
           app.redact_contact_text(o.closed_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
           app.redact_contact_text(o.courier_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
           app.redact_contact_text(o.payment_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]));
  get diagnostics v_notes = row_count;

  update app.orders set customer_name = null, customer_phone = null, customer_phone2 = null, area = null,
                        landmark = null, address_details = null, customer_note = null,
                        customer_anonymized_at = now(), version = version + 1, updated_at = now()
   where id = any (v_done);
  foreach v_id in array v_done loop
    perform app.order_recompute(v_id);   -- search fields no longer hold the name or phone
  end loop;

  -- Conversations that led to these orders hold the same contact data: their text goes too
  -- (metadata stays, so the order keeps its link).
  update app.messages m set body = null, body_purged_at = now()
    from app.conversations c
   where c.id = m.conversation_id and c.store_id = p_store_id and c.order_id = any (v_done) and m.body is not null;
  update app.reply_suggestions s set text_rendered = null, facts_used = '[]', conflicts = '[]'
    from app.conversations c
   where c.id = s.conversation_id and c.store_id = p_store_id and c.order_id = any (v_done);
  update app.ai_runs r set output_json = null, validation_errors = null, pii_map = null
    from app.conversations c
   where c.id = r.conversation_id and c.store_id = p_store_id and c.order_id = any (v_done);
  update app.conversations set customer_label = null where store_id = p_store_id and order_id = any (v_done);

  -- Stored answers of earlier requests repeat the contact data: they go too.
  delete from app.idempotency_keys
   where response -> 'data' ->> 'id' = any (array(select x::text from unnest(v_targets) x))
      or response -> 'data' ->> 'order_id' = any (array(select x::text from unnest(v_targets) x));

  -- Channel contacts identified by this number (WhatsApp; review O2): their conversations' text, AI
  -- outputs and stored webhook payloads go, and the contact keeps no name, number or provider id.
  -- Contacts with a send in flight or an order still being handled are skipped, like such orders.
  for v_contact in
    select * from app.contacts k where k.store_id = p_store_id and k.phone = v_phone and k.anonymized_at is null
     order by k.id for update
  loop
    if exists (select 1 from app.send_requests where contact_id = v_contact.id and state in ('queued', 'sending'))
       or exists (select 1 from app.conversations c join app.orders o on o.id = c.order_id
                   where c.contact_id = v_contact.id and o.status not in ('delivered', 'rejected', 'cancelled', 'returned')) then
      v_contacts_skipped := v_contacts_skipped + 1;
      continue;
    end if;
    select * into v_conn from app.connections where id = v_contact.connection_id;
    update app.webhook_events w set payload = null, payload_purged_at = now()
     where w.provider_id = v_conn.provider_id and w.payload is not null and w.status in ('processed', 'ignored', 'failed')
       and exists (select 1 from jsonb_array_elements(w.payload) i
                    where i ->> 'account_id' = v_conn.external_account_id and i ->> 'external_user_id' = v_contact.external_user_id);
    update app.messages m set body = null, body_purged_at = now()
      from app.conversations c where c.contact_id = v_contact.id and m.conversation_id = c.id and m.body is not null;
    update app.reply_suggestions s set text_rendered = null, facts_used = '[]', conflicts = '[]'
      from app.conversations c where c.contact_id = v_contact.id and s.conversation_id = c.id;
    update app.ai_runs r set output_json = null, validation_errors = null, pii_map = null
      from app.conversations c where c.contact_id = v_contact.id and r.conversation_id = c.id;
    update app.conversations set customer_label = null where contact_id = v_contact.id;
    update app.contacts set external_user_id = 'anon:' || gen_random_uuid(), display_name = null, phone = null,
                            window_expires_at = null, anonymized_at = now()
     where id = v_contact.id;
    v_contacts := v_contacts + 1;
  end loop;

  perform app.audit(p_store_id, 'customer.anonymize', 'store', p_store_id, null,
                    jsonb_build_object('orders', cardinality(v_done), 'skipped_in_progress', v_skipped,
                                       'notes_redacted', v_notes, 'contacts', v_contacts,
                                       'contacts_skipped_in_progress', v_contacts_skipped));

  v_result := app.ok(jsonb_build_object('anonymized', cardinality(v_done), 'skipped_in_progress', v_skipped,
                                        'notes_redacted', v_notes, 'order_ids', to_jsonb(v_done),
                                        'contacts_anonymized', v_contacts,
                                        'contacts_skipped_in_progress', v_contacts_skipped));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'anonymize_customer', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('anonymize_customer', v_state, v_code);
end;
$$;

revoke all on function app.courier_json(app.couriers), app.courier_of(uuid, uuid, boolean), app.open_list_of(uuid),
  app.delivery_list_json(uuid, boolean), app.lock_list_orders(uuid, uuid[], uuid),
  api.list_couriers(uuid, boolean), api.upsert_courier(uuid, uuid, integer, text, text, boolean, uuid),
  api.list_delivery_lists(uuid, text), api.get_delivery_list(uuid, uuid),
  api.create_delivery_list(uuid, uuid, uuid[], uuid),
  api.update_delivery_list(uuid, uuid, integer, text, uuid, uuid[], uuid),
  api.record_payment(uuid, uuid, text, bigint, text, uuid), api.settle_courier(uuid, uuid, bigint, uuid)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender,
     aisellia_channel_connector;
grant execute on function api.list_couriers(uuid, boolean), api.upsert_courier(uuid, uuid, integer, text, text, boolean, uuid),
  api.list_delivery_lists(uuid, text), api.get_delivery_list(uuid, uuid),
  api.create_delivery_list(uuid, uuid, uuid[], uuid),
  api.update_delivery_list(uuid, uuid, integer, text, uuid, uuid[], uuid),
  api.record_payment(uuid, uuid, text, bigint, text, uuid), api.settle_courier(uuid, uuid, bigint, uuid)
to authenticated;
