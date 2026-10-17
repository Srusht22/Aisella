-- Aisellia — Phase 8 hardening milestone: a narrowly scoped server-side path for AI-created drafts.
--
-- Contract: docs/implementation/phase-7/f-integration-contract.md §1. Rules enforced here:
--   * The AI runs as its own database role, `aisellia_ai` (NOLOGIN, NOINHERIT; PostgREST switches to
--     it for a JWT whose role claim is `aisellia_ai`). It is NOT a member of `authenticated` or
--     `service_role` and its ONLY privilege is EXECUTE on api.ai_upsert_draft. It can't read or write
--     any table, call any owner function, or approve, reject, cancel or fulfil anything.
--   * The AI never names a store. It presents an owner-issued draft grant (a random secret stored only
--     as a SHA-256 hash). The grant fixes the store, can be limited to one conversation reference,
--     expires and can be revoked. Seller isolation follows from the grant.
--   * The AI may create or update only Draft / Needs-approval orders it created (origin 'ai', one per
--     conversation reference). Prices, snapshots, fees and totals come from the catalog and zones; the
--     payload refuses status, totals, prices, fees, discounts, notes, approval and store fields.
--   * Seller edits win: every field the seller changed in update_draft is recorded in
--     orders.seller_edited and is never overwritten by the AI (reported as skipped_fields). An order
--     the seller approved, rejected or otherwise closed is refused (DRAFT_CLOSED).
--   * Quotas: calls per grant per minute and AI drafts per store per rolling day (app.ai_limits);
--     every call that presents a valid grant is logged in app.ai_requests (no payload, no PII).

-- ---------------------------------------------------------------------------------------------
-- The AI execution role.
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'aisellia_ai') then
    create role aisellia_ai nologin noinherit;
  end if;
end $$;
alter role aisellia_ai nologin noinherit nocreatedb nocreaterole nobypassrls;
grant aisellia_ai to authenticator;
grant usage on schema api to aisellia_ai;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------
create table app.ai_limits (
  name  text primary key,
  value integer not null check (value > 0)
);
insert into app.ai_limits (name, value) values
  ('calls_per_grant_per_minute', 20),
  ('drafts_per_store_per_day', 50),
  ('active_grants_per_store', 10),
  ('grant_max_hours', 168);

create table app.ai_draft_grants (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null references app.stores (id),
  secret_hash  text not null unique check (secret_hash ~ '^[0-9a-f]{64}$'),
  label        text check (label is null or (char_length(label) between 1 and 60 and label = btrim(label))),
  ai_ref       text check (ai_ref is null or (char_length(ai_ref) between 1 and 100 and ai_ref = btrim(ai_ref))),
  created_by   uuid not null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  revoked_at   timestamptz,
  last_used_at timestamptz,
  unique (store_id, id),
  constraint ai_draft_grants_expiry check (expires_at > created_at)
);
create index ai_draft_grants_store on app.ai_draft_grants (store_id, expires_at);

-- One row per AI call that presented a valid grant: what happened, never what was sent.
create table app.ai_requests (
  id         bigint generated always as identity primary key,
  grant_id   uuid not null,
  store_id   uuid not null,
  order_id   uuid,
  outcome    text not null check (char_length(outcome) between 1 and 40),
  created_at timestamptz not null default now(),
  foreign key (store_id, grant_id) references app.ai_draft_grants (store_id, id)
);
create index ai_requests_grant on app.ai_requests (grant_id, created_at);
create index ai_requests_created on app.ai_requests (created_at);

alter table app.orders
  add column ai_ref text check (ai_ref is null or (char_length(ai_ref) between 1 and 100 and ai_ref = btrim(ai_ref))),
  add column seller_edited text[] not null default '{}';
alter table app.orders add constraint orders_ai_ref_origin check ((origin = 'ai') = (ai_ref is not null));
-- One AI order per conversation reference, ever: a closed one is not resurrected.
create unique index orders_store_ai_ref on app.orders (store_id, ai_ref) where ai_ref is not null;

alter table app.order_status_events drop constraint order_status_events_actor_system_check;
alter table app.order_status_events
  add constraint order_status_events_actor_system_check check (actor_system in ('validation', 'ai'));

alter table app.ai_limits enable row level security;
alter table app.ai_draft_grants enable row level security;
alter table app.ai_requests enable row level security;
-- No policies and no grants: only the definer functions below read or write them.
revoke all on app.ai_limits, app.ai_draft_grants, app.ai_requests from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
create function app.ai_limit(p_name text)
returns integer language sql stable
as $$ select value from app.ai_limits where name = p_name $$;

create function app.secret_hash(p_secret text)
returns text language sql immutable
as $$ select encode(sha256(convert_to(p_secret, 'UTF8')), 'hex') $$;

-- The fields the AI may write, as they are now (used to detect seller edits).
create function app.order_ai_fields(p_order_id uuid)
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'customer_name', o.customer_name, 'customer_phone', o.customer_phone, 'customer_phone2', o.customer_phone2,
    'zone_id', o.zone_id, 'city_text', o.city_text, 'area', o.area, 'landmark', o.landmark,
    'address_details', o.address_details, 'payment_method', o.payment_method, 'customer_note', o.customer_note,
    'lines', coalesce((select jsonb_agg(jsonb_build_array(l.variant_id, l.quantity, l.quantity_basis)
                                        order by l.position, l.id)
                         from app.order_items l where l.order_id = o.id), '[]'::jsonb))
  from app.orders o where o.id = p_order_id;
$$;

-- Fields whose value differs; the delivery place (zone or other place) is one group.
create function app.ai_fields_changed(p_before jsonb, p_after jsonb)
returns text[] language sql immutable
as $$
  select coalesce(array_agg(distinct f order by f), '{}')
    from (
      select k as f from jsonb_object_keys(p_after) k where (p_before -> k) is distinct from (p_after -> k)
      union all
      select unnest(array['zone_id', 'city_text'])
       where (p_before -> 'zone_id') is distinct from (p_after -> 'zone_id')
          or (p_before -> 'city_text') is distinct from (p_after -> 'city_text')
    ) s;
$$;

-- The full editable state of an order, in the create_order payload shape.
create function app.order_payload(p_order_id uuid)
returns jsonb language sql stable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'customer_name', o.customer_name, 'customer_phone', o.customer_phone, 'customer_phone2', o.customer_phone2,
    'zone_id', o.zone_id, 'city_text', o.city_text, 'area', o.area, 'landmark', o.landmark,
    'address_details', o.address_details,
    'delivery_fee', case when o.delivery_fee_source = 'seller' then o.delivery_fee end,
    'payment_method', o.payment_method, 'payment_note', o.payment_note, 'discount', o.discount,
    'customer_note', o.customer_note, 'internal_note', o.internal_note))
    || jsonb_build_object('lines', coalesce((
         select jsonb_agg(jsonb_build_object('variant_id', l.variant_id, 'quantity', l.quantity)
                          order by l.position, l.id)
           from app.order_items l where l.order_id = o.id and l.variant_id is not null), '[]'::jsonb))
  from app.orders o where o.id = p_order_id;
$$;

-- What the AI gets back: no customer echo, no internal note, no approval data.
create function app.ai_draft_json(p_order_id uuid)
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'order_id', o.id, 'number', o.number, 'status', o.status, 'currency', o.currency,
    'issues', app.order_issues(o.id), 'subtotal', o.subtotal, 'delivery_fee', o.delivery_fee,
    'discount', o.discount, 'total', o.total, 'version', o.version,
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
                         'variant_id', l.variant_id, 'name', l.name_snapshot, 'variant_label', l.variant_label_snapshot,
                         'quantity', l.quantity, 'quantity_basis', l.quantity_basis,
                         'unit_price', coalesce(l.approved_unit_price, l.quoted_unit_price),
                         'line_total', l.quantity::bigint * coalesce(l.approved_unit_price, l.quoted_unit_price, 0))
                       order by l.position, l.id)
                       from app.order_items l where l.order_id = o.id), '[]'::jsonb))
  from app.orders o where o.id = p_order_id;
$$;

-- Status events and history name the AI as the actor.
create or replace function app.order_json(p_order_id uuid)
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
    'seller_edited', to_jsonb(o.seller_edited),
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
        'actor', case e.actor_system when 'ai' then 'ai' when 'validation' then 'system'
                      else app.actor_label(e.actor_user_id) end,
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

-- ---------------------------------------------------------------------------------------------
-- Seller edits are recorded so the AI never overwrites them (Phase 3 §6.1 "seller edits win").
-- update_draft is unchanged except for the two seller_edited lines.
-- ---------------------------------------------------------------------------------------------
create or replace function api.update_draft(p_store_id uuid, p_order_id uuid, p_expected_version integer, p_order jsonb,
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
  v_fields_before jsonb;
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
  v_fields_before := app.order_ai_fields(p_order_id);
  perform app.order_write_draft_lines(p_store_id, p_order_id, p_order -> 'lines');
  update app.orders set version = version + 1 where id = p_order_id;
  perform app.order_recompute(p_order_id, app.order_write_header(p_order_id, p_order));
  perform app.order_reevaluate(p_order_id);
  update app.orders o set seller_edited = (
      select coalesce(array_agg(distinct f order by f), '{}')
        from unnest(o.seller_edited || app.ai_fields_changed(v_fields_before, app.order_ai_fields(p_order_id))) f)
   where o.id = p_order_id;
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
-- Draft grants (owner side). The secret is returned once and stored only as a hash.
-- ---------------------------------------------------------------------------------------------
create function api.create_ai_draft_grant(p_store_id uuid, p_ai_ref text, p_label text, p_valid_hours integer)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_member app.store_members;
  v_hours integer := coalesce(p_valid_hours, 24);
  v_ref text := nullif(btrim(coalesce(p_ai_ref, '')), '');
  v_label text := nullif(btrim(coalesce(p_label, '')), '');
  v_secret text;
  v_grant app.ai_draft_grants;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  v_member := app.require_permission(p_store_id, 'ai.manage');
  if v_member.role <> 'owner' then
    perform app.fail('FORBIDDEN');
  end if;
  if v_hours not between 1 and app.ai_limit('grant_max_hours') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"valid_hours": "out_of_range"}}');
  end if;
  if char_length(coalesce(v_ref, '')) > 100 or char_length(coalesce(v_label, '')) > 60 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"ai_ref": "too_long"}}');
  end if;
  perform 1 from app.stores where id = p_store_id for update;
  if (select count(*) from app.ai_draft_grants
       where store_id = p_store_id and revoked_at is null and expires_at > now())
     >= app.ai_limit('active_grants_per_store') then
    perform app.fail('LIMIT_EXCEEDED', jsonb_build_object('limit', app.ai_limit('active_grants_per_store')));
  end if;
  -- 2 × 122 random bits from the server's CSPRNG.
  v_secret := 'aig_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into app.ai_draft_grants (store_id, secret_hash, label, ai_ref, created_by, expires_at)
  values (p_store_id, app.secret_hash(v_secret), v_label, v_ref, v_uid, now() + make_interval(hours => v_hours))
  returning * into v_grant;
  perform app.audit(p_store_id, 'ai_grant.create', 'ai_grant', v_grant.id, null,
                    jsonb_build_object('ai_ref', v_ref, 'expires_at', v_grant.expires_at));
  return app.ok(jsonb_build_object('grant_id', v_grant.id, 'secret', v_secret, 'ai_ref', v_ref,
                                   'expires_at', v_grant.expires_at));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('create_ai_draft_grant', v_state, v_code);
end;
$$;

create function api.revoke_ai_draft_grant(p_store_id uuid, p_grant_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_member app.store_members;
  v_grant app.ai_draft_grants;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  v_member := app.require_permission(p_store_id, 'ai.manage');
  if v_member.role <> 'owner' then
    perform app.fail('FORBIDDEN');
  end if;
  select * into v_grant from app.ai_draft_grants where id = p_grant_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_grant.revoked_at is null then
    update app.ai_draft_grants set revoked_at = now() where id = p_grant_id;
    perform app.audit(p_store_id, 'ai_grant.revoke', 'ai_grant', p_grant_id, null, null);
  end if;
  return app.ok(jsonb_build_object('grant_id', p_grant_id, 'revoked', true));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('revoke_ai_draft_grant', v_state, v_code);
end;
$$;

create function api.list_ai_draft_grants(p_store_id uuid)
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
  return app.ok(jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'grant_id', g.id, 'label', g.label, 'ai_ref', g.ai_ref, 'created_at', g.created_at,
             'expires_at', g.expires_at, 'revoked_at', g.revoked_at, 'last_used_at', g.last_used_at,
             'active', g.revoked_at is null and g.expires_at > now()) order by g.created_at desc)
      from app.ai_draft_grants g where g.store_id = p_store_id), '[]'::jsonb)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_ai_draft_grants', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.ai_upsert_draft: the AI's only operation.
--   p_grant  the grant secret (store binding);
--   p_ref    the conversation reference (one AI order per reference, ever);
--   p_order  a PARTIAL payload: keys present and not null are the AI's proposal; absent or null keys
--            are left as they are. `lines`, when present, is the full list of the AI's lines.
-- ---------------------------------------------------------------------------------------------
create function api.ai_upsert_draft(p_grant text, p_ref text, p_order jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_allowed text[] := array['customer_name', 'customer_phone', 'customer_phone2', 'zone_id', 'city_text', 'area',
                            'landmark', 'address_details', 'payment_method', 'customer_note', 'lines'];
  v_grant app.ai_draft_grants;
  v_store app.stores;
  v_ref text := btrim(coalesce(p_ref, ''));
  v_order app.orders;
  v_exists boolean := false;
  v_order_id uuid;
  v_hash text;
  v_result jsonb;
  v_errors jsonb := '{}'::jsonb;
  v_line_errors jsonb := '{}'::jsonb;
  v_ai jsonb := '{}'::jsonb;
  v_skipped text[] := '{}';
  v_merged jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_key text;
  v_i integer := 0;
  v_variant app.product_variants;
  v_product app.products;
  v_qty integer;
  v_count integer;
  v_number integer;
  v_status text;
  v_before jsonb;
  v_after jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  -- 1. Caller: the AI role only (never an end user, anon or service_role).
  if coalesce(auth.role(), '') <> 'aisellia_ai' then
    perform app.fail('FORBIDDEN');
  end if;

  -- 2. Grant: store binding, expiry, revocation, scope. Locked, so calls of one grant serialise.
  if p_grant is null or p_grant !~ '^aig_[0-9a-f]{64}$' then
    perform app.fail('AI_GRANT_INVALID');
  end if;
  select * into v_grant from app.ai_draft_grants where secret_hash = app.secret_hash(p_grant) for update;
  if not found or v_grant.revoked_at is not null or v_grant.expires_at <= now() then
    v_grant := null;
    perform app.fail('AI_GRANT_INVALID');
  end if;
  select * into v_store from app.stores where id = v_grant.store_id;
  if v_store.deletion_requested_at is not null then
    perform app.fail('AI_GRANT_INVALID');
  end if;
  if char_length(v_ref) not between 1 and 100 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"ref": "invalid"}}');
  end if;
  if v_grant.ai_ref is not null and v_grant.ai_ref <> v_ref then
    perform app.fail('AI_GRANT_SCOPE');
  end if;

  -- 3. Payload shape: only the AI fields; never status, prices, totals, fees, discounts or notes.
  --    Unknown keys are refused at once; value errors are reported together in step 7.
  if p_order is null or jsonb_typeof(p_order) <> 'object' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"order": "required"}}');
  end if;
  for v_key in select k from jsonb_object_keys(p_order) k where not (k = any (v_allowed)) loop
    v_errors := v_errors || jsonb_build_object(v_key, 'unknown');
  end loop;
  if p_order ? 'lines' and jsonb_typeof(p_order -> 'lines') = 'array' then
    for v_line in select * from jsonb_array_elements(p_order -> 'lines') loop
      if jsonb_typeof(v_line) = 'object' then
        for v_key in select k from jsonb_object_keys(v_line) k
                      where k not in ('variant_id', 'quantity', 'quantity_basis') loop
          v_errors := v_errors || jsonb_build_object('lines.' || v_i || '.' || v_key, 'unknown');
        end loop;
        if coalesce(v_line ->> 'quantity_basis', 'stated') not in ('stated', 'inferred') then
          v_line_errors := v_line_errors || jsonb_build_object('lines.' || v_i || '.quantity_basis', 'invalid');
        end if;
        v_lines := v_lines || jsonb_build_object('variant_id', v_line -> 'variant_id', 'quantity', v_line -> 'quantity');
      else
        v_lines := v_lines || v_line;
      end if;
      v_i := v_i + 1;
    end loop;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  -- 4. Idempotency, per grant.
  v_hash := app.request_hash(jsonb_build_object('ref', v_ref, 'order', p_order));
  v_result := app.idempotency_replay(v_grant.id, p_idempotency_key, 'ai_upsert_draft', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  -- 5. Call rate per grant (every logged call counts, refused ones too).
  select count(*) into v_count from app.ai_requests
   where grant_id = v_grant.id and created_at > now() - interval '1 minute';
  if v_count >= app.ai_limit('calls_per_grant_per_minute') then
    perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'grant', 'retry_after_seconds', 60,
                                                        'limit', app.ai_limit('calls_per_grant_per_minute')));
  end if;

  -- 6. The AI's order for this reference, if any.
  select * into v_order from app.orders where store_id = v_grant.store_id and ai_ref = v_ref for update;
  v_exists := found;
  if v_exists then
    if v_order.status not in ('draft', 'pending_approval') then
      -- The seller approved, rejected or otherwise closed it: the AI cannot touch it again.
      perform app.fail('DRAFT_CLOSED', jsonb_build_object('order_id', v_order.id, 'current_status', v_order.status));
    end if;
  else
    -- New AI drafts per store per rolling day; serialised per store.
    perform pg_advisory_xact_lock(hashtextextended('ai_drafts:' || v_grant.store_id::text, 0));
    select count(*) into v_count from app.orders
     where store_id = v_grant.store_id and origin = 'ai' and created_at > now() - interval '24 hours';
    if v_count >= app.ai_limit('drafts_per_store_per_day') then
      perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'store', 'retry_after_seconds', 3600,
                                                          'limit', app.ai_limit('drafts_per_store_per_day')));
    end if;
  end if;

  -- 7. The AI's proposal minus what the seller has edited (seller edits win).
  for v_key in select k from jsonb_object_keys(p_order) k where jsonb_typeof(p_order -> k) <> 'null' loop
    if v_exists and v_key = any (v_order.seller_edited) then
      v_skipped := v_skipped || v_key;
    elsif v_key = 'lines' then
      v_ai := v_ai || jsonb_build_object('lines', v_lines);
    else
      v_ai := v_ai || jsonb_build_object(v_key, p_order -> v_key);
    end if;
  end loop;
  -- A zone and another place exclude each other.
  if v_ai ? 'zone_id' and not v_ai ? 'city_text' then
    v_ai := v_ai || '{"city_text": null}';
  elsif v_ai ? 'city_text' and not v_ai ? 'zone_id' then
    v_ai := v_ai || '{"zone_id": null}';
  end if;
  v_merged := case when v_exists then app.order_payload(v_order.id) else '{"lines": []}'::jsonb end || v_ai;
  v_merged := jsonb_strip_nulls(v_merged - 'lines') || jsonb_build_object('lines', v_merged -> 'lines');

  v_errors := v_line_errors || app.order_field_errors(v_grant.store_id, v_merged, v_order.zone_id);
  -- New lines must be sellable now and not exceed the stock (the AI must not promise what is gone).
  if v_ai ? 'lines' and not exists (select 1 from jsonb_object_keys(v_errors) k where k like 'lines%') then
    v_i := 0;
    for v_line in select * from jsonb_array_elements(v_ai -> 'lines') loop
      select * into v_variant from app.product_variants where id = (v_line ->> 'variant_id')::uuid;
      select * into v_product from app.products where id = v_variant.product_id;
      v_qty := (v_line ->> 'quantity')::integer;
      if v_product.status <> 'active' or v_variant.status <> 'active'
         or (not v_product.track_stock and not v_variant.available) then
        v_errors := v_errors || jsonb_build_object('lines.' || v_i || '.variant_id', 'unavailable');
      elsif v_product.track_stock and v_variant.stock_on_hand < v_qty then
        v_errors := v_errors || jsonb_build_object('lines.' || v_i || '.quantity', 'exceeds_stock');
      end if;
      v_i := v_i + 1;
    end loop;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  -- 8. Write.
  if not v_exists then
    update app.stores set last_order_number = last_order_number + 1 where id = v_grant.store_id
      returning last_order_number into v_number;
    insert into app.orders (store_id, number, status, origin, ai_ref, currency)
    values (v_grant.store_id, v_number, 'draft', 'ai', v_ref, v_store.currency)
    returning id into v_order_id;
  else
    v_order_id := v_order.id;
    v_before := app.order_audit_state(v_order_id);
  end if;
  if v_ai ? 'lines' then
    perform app.order_write_draft_lines(v_grant.store_id, v_order_id, v_merged -> 'lines');
    update app.order_items l set quantity_basis = coalesce(x ->> 'quantity_basis', 'stated')
      from jsonb_array_elements(p_order -> 'lines') x
     where l.order_id = v_order_id and l.variant_id = (x ->> 'variant_id')::uuid;
  end if;
  perform app.order_recompute(v_order_id, app.order_write_header(v_order_id, v_merged));
  if not v_exists then
    v_status := case when app.order_issues(v_order_id) = '[]'::jsonb then 'pending_approval' else 'draft' end;
    update app.orders set status = v_status where id = v_order_id;
    insert into app.order_status_events (store_id, order_id, from_status, to_status, actor_system)
    values (v_grant.store_id, v_order_id, null, v_status, 'ai');
    perform app.audit(v_grant.store_id, 'order.ai_create', 'order', v_order_id, null,
                      app.order_audit_state(v_order_id) || jsonb_build_object('actor', 'ai', 'grant_id', v_grant.id));
  else
    update app.orders set version = version + 1 where id = v_order_id;
    perform app.order_reevaluate(v_order_id);
    v_after := app.order_audit_state(v_order_id);
    if v_after <> v_before then
      perform app.audit(v_grant.store_id, 'order.ai_update', 'order', v_order_id,
                        app.jsonb_changed(v_before, v_after, 'before'),
                        app.jsonb_changed(v_before, v_after, 'after')
                          || jsonb_build_object('actor', 'ai', 'grant_id', v_grant.id));
    end if;
  end if;

  insert into app.ai_requests (grant_id, store_id, order_id, outcome)
  values (v_grant.id, v_grant.store_id, v_order_id, case when v_exists then 'updated' else 'created' end);
  update app.ai_draft_grants set last_used_at = now() where id = v_grant.id;

  v_result := app.ok(app.ai_draft_json(v_order_id) || jsonb_build_object(
    'created', not v_exists, 'skipped_fields', to_jsonb(array(select unnest(v_skipped) order by 1))));
  perform app.idempotency_save(v_grant.id, p_idempotency_key, 'ai_upsert_draft', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    -- Refusals are logged (and count towards the call rate) once a valid grant was presented.
    if v_grant.id is not null then
      insert into app.ai_requests (grant_id, store_id, order_id, outcome)
      values (v_grant.id, v_grant.store_id, v_order.id, v_code);
    end if;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('ai_upsert_draft', v_state, v_code);
end;
$$;

-- History lists AI edits and names the AI.
create or replace function api.order_history(p_store_id uuid, p_order_id uuid)
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
               'actor', case e.actor_system when 'ai' then 'ai' when 'validation' then 'system'
                             else app.actor_label(e.actor_user_id) end,
               'reason', e.reason, 'note', e.note, 'created_at', e.created_at) as j
        from app.order_status_events e where e.order_id = p_order_id and e.store_id = p_store_id
      union all
      select a.created_at, 0, a.id, jsonb_build_object(
               'kind', case a.action when 'order.update_draft' then 'edit' when 'order.edit' then 'edit'
                                     when 'order.ai_update' then 'edit'
                                     when 'order.note' then 'note' when 'order.cod' then 'cash'
                                     else 'confirmation' end,
               'actor', case when a.after ->> 'actor' = 'ai' then 'ai' else app.actor_label(a.actor_user_id) end,
               'before', a.before, 'after', a.after - 'actor' - 'grant_id',
               'created_at', a.created_at)
        from app.audit_events a
       where a.store_id = p_store_id and a.entity_type = 'order' and a.entity_id = p_order_id
         and a.action in ('order.update_draft', 'order.edit', 'order.ai_update', 'order.note', 'order.cod',
                          'order.confirmation_marked_sent')
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
-- Account purge: grants and the AI request log go with the store.
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
      delete from app.ai_requests where store_id = v_request.store_id;
      delete from app.ai_draft_grants where store_id = v_request.store_id;
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
-- Privileges: the AI role gets exactly one function; owners manage grants.
-- ---------------------------------------------------------------------------------------------
revoke all on function
  app.ai_limit(text), app.secret_hash(text), app.order_ai_fields(uuid), app.ai_fields_changed(jsonb, jsonb),
  app.order_payload(uuid), app.ai_draft_json(uuid),
  api.create_ai_draft_grant(uuid, text, text, integer),
  api.revoke_ai_draft_grant(uuid, uuid),
  api.list_ai_draft_grants(uuid),
  api.ai_upsert_draft(text, text, jsonb, uuid)
from public, anon, authenticated, aisellia_ai;

grant execute on function
  api.create_ai_draft_grant(uuid, text, text, integer),
  api.revoke_ai_draft_grant(uuid, uuid),
  api.list_ai_draft_grants(uuid)
to authenticated;
grant execute on function api.ai_upsert_draft(text, text, jsonb, uuid) to aisellia_ai;
