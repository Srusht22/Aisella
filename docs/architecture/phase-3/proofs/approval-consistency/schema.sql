-- THROWAWAY PROOF (Phase 3 design validation). NOT a migration. Not committed.
create extension if not exists pgcrypto;
create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth; create schema api; create schema app;
create function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create function auth.role() returns text language sql stable as
$$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon') $$;
create table auth.users(id uuid primary key, email_confirmed_at timestamptz);

create table app.stores(id uuid primary key default gen_random_uuid(), name text not null,
  last_order_number int not null default 1000);
create table app.store_members(store_id uuid references app.stores, user_id uuid references auth.users,
  role text not null check (role in ('owner','staff')), primary key(store_id,user_id));
create table app.product_variants(id uuid primary key default gen_random_uuid(),
  store_id uuid not null references app.stores, label text not null, price int not null check (price > 0),
  track_stock bool not null default true, stock_on_hand int not null default 0 check (stock_on_hand >= 0),
  status text not null default 'active');
create table app.inventory_movements(id bigint generated always as identity primary key,
  store_id uuid not null, variant_id uuid not null references app.product_variants, delta int not null,
  resulting_qty int not null, reason text not null, order_id uuid, actor uuid, created_at timestamptz default now());
create table app.orders(id uuid primary key default gen_random_uuid(), store_id uuid not null references app.stores,
  number int, status text not null check (status in ('draft','pending_approval','rejected','approved','processing',
  'dispatched','delivered','delivery_failed','returned','cancelled')), is_test bool not null default false,
  version int not null default 1, total int, approved_by uuid, approved_at timestamptz);
create table app.order_items(id uuid primary key default gen_random_uuid(), order_id uuid not null references app.orders,
  store_id uuid not null, variant_id uuid references app.product_variants, quantity int not null check (quantity between 1 and 999),
  quoted_unit_price int not null, approved_unit_price int);
create table app.idempotency_keys(user_id uuid not null, key uuid not null, operation text not null,
  request_hash text not null, response jsonb not null, created_at timestamptz default now(), primary key(user_id,key));

-- membership helper used by RLS and RPCs
create function app.is_member(p_store uuid) returns bool language sql stable security definer set search_path = '' as
$$ select exists(select 1 from app.store_members m where m.store_id = p_store and m.user_id = auth.uid()) $$;

alter table app.product_variants enable row level security;
alter table app.orders enable row level security;
alter table app.inventory_movements enable row level security;
create policy read_own on app.product_variants for select to authenticated using (app.is_member(store_id));
create policy read_own on app.orders for select to authenticated using (app.is_member(store_id));
create policy read_own on app.inventory_movements for select to authenticated using (app.is_member(store_id));
grant usage on schema app, api, auth to authenticated, service_role;
grant select on app.product_variants, app.orders, app.inventory_movements to authenticated;  -- SELECT only
grant execute on function auth.uid(), auth.role(), app.is_member(uuid) to authenticated, service_role;

create function api.approve_order(p_order uuid, p_expected_version int, p_key uuid, p_price_choices jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); o app.orders%rowtype; r record; v_total int := 0; v_short jsonb := '[]';
        v_changed jsonb := '[]'; v_hash text := md5(p_order::text || p_expected_version || p_price_choices::text);
        v_prev app.idempotency_keys%rowtype; v_res jsonb;
begin
  if v_uid is null or auth.role() <> 'authenticated' then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');            -- service_role / AI can never approve
  end if;
  select * into v_prev from app.idempotency_keys where user_id = v_uid and key = p_key;
  if found then
    if v_prev.request_hash <> v_hash then return jsonb_build_object('ok', false, 'error', 'IDEMPOTENCY_KEY_REUSED'); end if;
    return v_prev.response;                                                  -- replay: same answer, no side effects
  end if;
  select * into o from app.orders where id = p_order for update;            -- serialises concurrent approvals
  if not found or not exists (select 1 from app.store_members m where m.store_id = o.store_id
                              and m.user_id = v_uid and m.role = 'owner') then
    return jsonb_build_object('ok', false, 'error', 'NOT_FOUND');           -- no existence leak across tenants
  end if;
  if not exists (select 1 from auth.users u where u.id = v_uid and u.email_confirmed_at is not null) then
    return jsonb_build_object('ok', false, 'error', 'EMAIL_NOT_VERIFIED');
  end if;
  if o.status <> 'pending_approval' then
    return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'current_status', o.status, 'version', o.version);
  end if;
  if o.version <> p_expected_version then
    return jsonb_build_object('ok', false, 'error', 'CONFLICT_VERSION', 'version', o.version);
  end if;
  -- lock variants in a deterministic order (deadlock avoidance) and re-validate price + stock
  for r in select i.id item_id, i.quantity, i.quoted_unit_price, v.* from app.order_items i
           join app.product_variants v on v.id = i.variant_id where i.order_id = o.id order by v.id for update of v loop
    if r.status <> 'active' then v_short := v_short || jsonb_build_object('item', r.item_id, 'reason', 'UNAVAILABLE'); continue; end if;
    if r.price <> r.quoted_unit_price and not (p_price_choices ? r.item_id::text) then
      v_changed := v_changed || jsonb_build_object('item', r.item_id, 'quoted', r.quoted_unit_price, 'current', r.price);
    end if;
    if not o.is_test and r.track_stock and r.stock_on_hand < r.quantity then
      v_short := v_short || jsonb_build_object('item', r.item_id, 'requested', r.quantity, 'available', r.stock_on_hand);
    end if;
  end loop;
  if jsonb_array_length(v_changed) > 0 then return jsonb_build_object('ok', false, 'error', 'PRICE_CHANGED', 'items', v_changed); end if;
  if jsonb_array_length(v_short) > 0 then return jsonb_build_object('ok', false, 'error', 'INSUFFICIENT_STOCK', 'items', v_short); end if;
  for r in select i.*, v.track_stock from app.order_items i join app.product_variants v on v.id = i.variant_id
           where i.order_id = o.id order by v.id loop
    update app.order_items set approved_unit_price = case when p_price_choices->>(r.id::text) = 'current'
        then (select price from app.product_variants where id = r.variant_id) else r.quoted_unit_price end where id = r.id
      returning approved_unit_price into r.approved_unit_price;
    v_total := v_total + r.quantity * r.approved_unit_price;
    if not o.is_test and r.track_stock then
      with u as (update app.product_variants set stock_on_hand = stock_on_hand - r.quantity where id = r.variant_id returning stock_on_hand)
      insert into app.inventory_movements(store_id, variant_id, delta, resulting_qty, reason, order_id, actor)
        select o.store_id, r.variant_id, -r.quantity, u.stock_on_hand, 'order_approved', o.id, v_uid from u;
    end if;
  end loop;
  update app.orders set status = 'approved', version = version + 1, total = v_total, approved_by = v_uid, approved_at = now()
    where id = o.id;
  v_res := jsonb_build_object('ok', true, 'status', 'approved', 'version', o.version + 1, 'total', v_total);
  insert into app.idempotency_keys(user_id, key, operation, request_hash, response) values (v_uid, p_key, 'approve_order', v_hash, v_res);
  return v_res;
end $$;
revoke all on function api.approve_order(uuid,int,uuid,jsonb) from public;
grant execute on function api.approve_order(uuid,int,uuid,jsonb) to authenticated, service_role;
