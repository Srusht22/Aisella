-- Aisellia — Phase 5: identity, stores, membership, delivery zones, onboarding.
--
-- Rules from docs/architecture/phase-3 (authorization-and-tenancy.md, backend-and-data-model.md,
-- api-and-service-contracts.md, ADR-002/003/005):
--   * Business tables live in `app`. PostgREST exposes only `api` (supabase/config.toml).
--   * `authenticated` may SELECT business tables (through `api` views), filtered by RLS.
--     It has NO insert/update/delete privilege on any table.
--   * Every mutation is an `api.*` SECURITY DEFINER function with `search_path = ''` that
--     authorizes explicitly, validates, writes an audit row in the same transaction and
--     returns the envelope {ok, data} / {ok:false, error:{code, details}}.
--   * Retryable mutations take an idempotency key (user_id, key) and replay the stored result.
--   * A store the caller is not a member of is reported as NOT_FOUND (no existence leak).

-- Functions created below must never be executable by PUBLIC by default.
alter default privileges in schema public revoke execute on functions from public;

create schema app;
create schema api;
create schema internal;

revoke all on schema app, api, internal from public;
grant usage on schema api to anon, authenticated;   -- PostgREST resolves the schema; nothing in it is granted to anon
grant usage on schema app to authenticated;         -- needed by security-invoker views and RLS helpers

alter default privileges in schema app revoke execute on functions from public;
alter default privileges in schema api revoke execute on functions from public;
alter default privileges in schema internal revoke execute on functions from public;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- Per-user record created at sign-up. Display preferences stay on the device in P0
-- (docs/implementation/phase-5); this row records consent to the terms.
create table app.profiles (
  user_id           uuid primary key references auth.users (id) on delete cascade,
  terms_version     text check (terms_version is null or char_length(terms_version) between 1 and 32),
  terms_accepted_at timestamptz,
  created_at        timestamptz not null default now()
);

create table app.stores (
  id                     uuid primary key default gen_random_uuid(),
  name                   text not null check (char_length(name) between 1 and 60 and name = btrim(name)),
  contact_phone          text not null check (contact_phone ~ '^\+9647[0-9]{9}$'),
  currency               text not null default 'IQD' check (currency in ('IQD', 'USD')),
  reply_locale           text not null default 'ckb' check (reply_locale in ('ckb', 'en')),
  business_city          text not null check (char_length(business_city) between 1 and 60 and business_city = btrim(business_city)),
  cod_enabled            boolean not null default true,
  other_payment_enabled  boolean not null default false,
  -- Onboarding progress (Phase 2 AU-07..09): the store exists after AU-07; the seller resumes
  -- at `onboarding_step` until it is 'done'.
  onboarding_step        text not null default 'zones' check (onboarding_step in ('zones', 'payments', 'done')),
  currency_locked_at     timestamptz,
  deletion_requested_at  timestamptz,
  version                integer not null default 1 check (version >= 1),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint stores_payment_method_required check (cod_enabled or other_payment_enabled)
);

create table app.store_members (
  store_id    uuid not null references app.stores (id),
  user_id     uuid not null references auth.users (id),
  role        text not null check (role in ('owner', 'staff')),
  status      text not null default 'active' check (status in ('active', 'disabled')),
  permissions jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  primary key (store_id, user_id)
);
-- Exactly one owner per store.
create unique index store_members_one_owner_per_store on app.store_members (store_id) where role = 'owner';
-- P0 (Phase 3 authorization §1): one store per user. A trusted constraint, so two concurrent
-- create_store calls cannot both succeed. Dropped when P1 staff / P2 multi-store arrive.
create unique index store_members_one_store_per_user_p0 on app.store_members (user_id);

create table app.delivery_zones (
  id         uuid primary key default gen_random_uuid(),
  store_id   uuid not null references app.stores (id),
  name       text not null check (char_length(name) between 1 and 40 and name = btrim(name)),
  fee        integer not null check (fee between 0 and 10000000),
  time_text  text check (time_text is null or (char_length(time_text) between 1 and 40 and time_text = btrim(time_text))),
  active     boolean not null default true,
  sort       integer not null default 0,
  version    integer not null default 1 check (version >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (store_id, id)
);
-- Zone names are unique per store among active zones (a removed zone's name can be reused).
create unique index delivery_zones_active_name on app.delivery_zones (store_id, lower(name)) where active;

create table app.audit_events (
  id            bigint generated always as identity primary key,
  store_id      uuid not null references app.stores (id),
  actor_user_id uuid,
  action        text not null,
  entity_type   text not null,
  entity_id     uuid,
  before        jsonb,
  after         jsonb,
  created_at    timestamptz not null default now()
);
create index audit_events_entity on app.audit_events (store_id, entity_type, entity_id, created_at);

create table app.idempotency_keys (
  user_id      uuid not null,
  key          uuid not null,
  operation    text not null,
  request_hash text not null,
  response     jsonb not null,
  created_at   timestamptz not null default now(),
  primary key (user_id, key)
);

-- ---------------------------------------------------------------------------------------------
-- Helpers (app schema). Not exposed through PostgREST.
-- ---------------------------------------------------------------------------------------------

-- Membership test used by RLS. SECURITY DEFINER so policies on store_members do not recurse.
-- A store whose deletion was requested is no longer accessible (Phase 1 US-004).
create function app.is_member(p_store_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from app.store_members m
    join app.stores s on s.id = m.store_id
    where m.store_id = p_store_id
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and s.deletion_requested_at is null
  );
$$;

-- Business failure: caught by the api function and returned as an error envelope.
create function app.fail(p_code text, p_details jsonb default '{}'::jsonb)
returns void
language plpgsql
as $$
begin
  raise exception using errcode = 'AS001', message = p_code, detail = coalesce(p_details, '{}'::jsonb)::text;
end;
$$;

create function app.ok(p_data jsonb)
returns jsonb language sql immutable
as $$ select jsonb_build_object('ok', true, 'data', p_data) $$;

create function app.err(p_code text, p_details jsonb default '{}'::jsonb)
returns jsonb language sql immutable
as $$ select jsonb_build_object('ok', false, 'error', jsonb_build_object('code', p_code, 'details', coalesce(p_details, '{}'::jsonb))) $$;

-- Unexpected failure: log server-side with a reference; the client only sees INTERNAL + ref.
create function app.internal_error(p_operation text, p_state text, p_message text)
returns jsonb
language plpgsql
as $$
declare
  v_ref text := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
begin
  raise warning 'api.% failed ref=% sqlstate=% message=%', p_operation, v_ref, p_state, p_message;
  return app.err('INTERNAL', jsonb_build_object('ref', v_ref));
end;
$$;

-- Only a signed-in end user (never anon, never service_role) may call api mutations.
create function app.require_end_user()
returns uuid
language plpgsql stable
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    perform app.fail('UNAUTHENTICATED');
  end if;
  if coalesce(auth.role(), '') <> 'authenticated' then
    perform app.fail('FORBIDDEN');
  end if;
  return v_uid;
end;
$$;

-- Authorizes the caller for a permission in a store. Non-members get NOT_FOUND so the
-- store's existence is not revealed. P0 has owners only; owners hold every permission.
create function app.require_permission(p_store_id uuid, p_permission text)
returns app.store_members
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_member app.store_members;
begin
  if p_store_id is null or not app.is_member(p_store_id) then
    perform app.fail('NOT_FOUND');
  end if;
  select * into v_member from app.store_members
   where store_id = p_store_id and user_id = (select auth.uid());
  if v_member.role = 'owner' then
    return v_member;
  end if;
  if coalesce((v_member.permissions ->> p_permission)::boolean, false) then
    return v_member;
  end if;
  perform app.fail('FORBIDDEN');
end;
$$;

create function app.request_hash(p_payload jsonb)
returns text language sql immutable
as $$ select encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex') $$;

-- Returns the stored response for a replayed key, or null for a new key.
-- The same key with a different request is IDEMPOTENCY_KEY_REUSED (ADR-005).
create function app.idempotency_replay(p_user_id uuid, p_key uuid, p_operation text, p_hash text)
returns jsonb
language plpgsql
as $$
declare
  v_row app.idempotency_keys;
begin
  if p_key is null then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object('idempotency_key', 'required')));
  end if;
  select * into v_row from app.idempotency_keys where user_id = p_user_id and key = p_key;
  if not found then
    return null;
  end if;
  if v_row.operation <> p_operation or v_row.request_hash <> p_hash then
    perform app.fail('IDEMPOTENCY_KEY_REUSED');
  end if;
  return v_row.response;
end;
$$;

create function app.idempotency_save(p_user_id uuid, p_key uuid, p_operation text, p_hash text, p_response jsonb)
returns void
language sql
as $$
  insert into app.idempotency_keys (user_id, key, operation, request_hash, response)
  values (p_user_id, p_key, p_operation, p_hash, p_response);
$$;

create function app.audit(p_store_id uuid, p_action text, p_entity_type text, p_entity_id uuid, p_before jsonb, p_after jsonb)
returns void
language sql
as $$
  insert into app.audit_events (store_id, actor_user_id, action, entity_type, entity_id, before, after)
  values (p_store_id, auth.uid(), p_action, p_entity_type, p_entity_id, p_before, p_after);
$$;

-- Public shape of a store (the contract), shared by every function that returns one.
create function app.store_json(p_store app.stores)
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'id', p_store.id,
    'name', p_store.name,
    'contact_phone', p_store.contact_phone,
    'currency', p_store.currency,
    'reply_locale', p_store.reply_locale,
    'business_city', p_store.business_city,
    'cod_enabled', p_store.cod_enabled,
    'other_payment_enabled', p_store.other_payment_enabled,
    'onboarding_step', p_store.onboarding_step,
    'currency_locked', p_store.currency_locked_at is not null,
    'version', p_store.version,
    'created_at', p_store.created_at,
    'updated_at', p_store.updated_at
  );
$$;

create function app.zone_json(p_zone app.delivery_zones)
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'id', p_zone.id,
    'store_id', p_zone.store_id,
    'name', p_zone.name,
    'fee', p_zone.fee,
    'time_text', p_zone.time_text,
    'active', p_zone.active,
    'sort', p_zone.sort,
    'version', p_zone.version
  );
$$;

-- Field validation for store profile values. Returns {field: rule} for every failure.
-- Inputs are expected already trimmed and normalised by the client; the server re-checks.
create function app.store_field_errors(p_fields jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
  v_errors jsonb := '{}'::jsonb;
  v_text text;
begin
  if p_fields ? 'name' then
    v_text := p_fields ->> 'name';
    if v_text is null or char_length(btrim(v_text)) = 0 then
      v_errors := v_errors || '{"name": "required"}';
    elsif char_length(btrim(v_text)) > 60 then
      v_errors := v_errors || '{"name": "too_long"}';
    end if;
  end if;
  if p_fields ? 'contact_phone' then
    v_text := p_fields ->> 'contact_phone';
    if v_text is null or v_text = '' then
      v_errors := v_errors || '{"contact_phone": "required"}';
    elsif v_text !~ '^\+9647[0-9]{9}$' then
      v_errors := v_errors || '{"contact_phone": "invalid"}';
    end if;
  end if;
  if p_fields ? 'currency' and coalesce(p_fields ->> 'currency', '') not in ('IQD', 'USD') then
    v_errors := v_errors || '{"currency": "invalid"}';
  end if;
  if p_fields ? 'reply_locale' and coalesce(p_fields ->> 'reply_locale', '') not in ('ckb', 'en') then
    v_errors := v_errors || '{"reply_locale": "invalid"}';
  end if;
  if p_fields ? 'business_city' then
    v_text := p_fields ->> 'business_city';
    if v_text is null or char_length(btrim(v_text)) = 0 then
      v_errors := v_errors || '{"business_city": "required"}';
    elsif char_length(btrim(v_text)) > 60 then
      v_errors := v_errors || '{"business_city": "too_long"}';
    end if;
  end if;
  if p_fields ? 'cod_enabled' and jsonb_typeof(p_fields -> 'cod_enabled') <> 'boolean' then
    v_errors := v_errors || '{"cod_enabled": "invalid"}';
  end if;
  if p_fields ? 'other_payment_enabled' and jsonb_typeof(p_fields -> 'other_payment_enabled') <> 'boolean' then
    v_errors := v_errors || '{"other_payment_enabled": "invalid"}';
  end if;
  return v_errors;
end;
$$;

create function app.zone_field_errors(p_name text, p_fee integer, p_time_text text)
returns jsonb
language plpgsql immutable
as $$
declare
  v_errors jsonb := '{}'::jsonb;
begin
  if p_name is null or char_length(btrim(p_name)) = 0 then
    v_errors := v_errors || '{"name": "required"}';
  elsif char_length(btrim(p_name)) > 40 then
    v_errors := v_errors || '{"name": "too_long"}';
  end if;
  if p_fee is null then
    v_errors := v_errors || '{"fee": "required"}';
  elsif p_fee < 0 or p_fee > 10000000 then
    v_errors := v_errors || '{"fee": "out_of_range"}';
  end if;
  if p_time_text is not null and char_length(btrim(p_time_text)) > 40 then
    v_errors := v_errors || '{"time_text": "too_long"}';
  end if;
  return v_errors;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Sign-up hook: one profile per auth user, recording consent to the terms.
-- ---------------------------------------------------------------------------------------------
create function internal.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_terms text := nullif(left(new.raw_user_meta_data ->> 'terms_version', 32), '');
begin
  insert into app.profiles (user_id, terms_version, terms_accepted_at)
  values (new.id, v_terms, case when v_terms is null then null else now() end);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function internal.handle_new_user();

-- ---------------------------------------------------------------------------------------------
-- Row-level security. Every business table: RLS on; SELECT only for members; no write grants.
-- ---------------------------------------------------------------------------------------------
alter table app.profiles enable row level security;
alter table app.stores enable row level security;
alter table app.store_members enable row level security;
alter table app.delivery_zones enable row level security;
alter table app.audit_events enable row level security;
alter table app.idempotency_keys enable row level security;   -- no policy: deny all

create policy profiles_select_own on app.profiles
  for select to authenticated using (user_id = (select auth.uid()));
create policy stores_select_member on app.stores
  for select to authenticated using (app.is_member(id));
create policy store_members_select_member on app.store_members
  for select to authenticated using (app.is_member(store_id));
create policy delivery_zones_select_member on app.delivery_zones
  for select to authenticated using (app.is_member(store_id));
create policy audit_events_select_member on app.audit_events
  for select to authenticated using (app.is_member(store_id));

revoke all on all tables in schema app from public, anon, authenticated;
grant select on app.profiles, app.stores, app.store_members, app.delivery_zones, app.audit_events to authenticated;
grant execute on function app.is_member(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Read API: security-invoker views, so RLS applies to the caller.
-- ---------------------------------------------------------------------------------------------
create view api.stores with (security_invoker = true) as
  select id, name, contact_phone, currency, reply_locale, business_city, cod_enabled,
         other_payment_enabled, onboarding_step, currency_locked_at is not null as currency_locked,
         version, created_at, updated_at
  from app.stores;

create view api.delivery_zones with (security_invoker = true) as
  select id, store_id, name, fee, time_text, active, sort, version, created_at, updated_at
  from app.delivery_zones;

revoke all on api.stores, api.delivery_zones from public, anon, authenticated;
grant select on api.stores, api.delivery_zones to authenticated;

-- ---------------------------------------------------------------------------------------------
-- api.get_my_context(): everything the app needs to route a signed-in user.
-- ---------------------------------------------------------------------------------------------
create function api.get_my_context()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_user auth.users;
  v_member app.store_members;
  v_store app.stores;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  select * into v_user from auth.users where id = v_uid;
  if not found then
    perform app.fail('UNAUTHENTICATED');
  end if;
  select * into v_member from app.store_members where user_id = v_uid;
  if found then
    select * into v_store from app.stores where id = v_member.store_id;
  end if;
  return app.ok(jsonb_build_object(
    'user_id', v_uid,
    'email', v_user.email,
    'email_verified', v_user.email_confirmed_at is not null,
    'deletion_pending', v_store.deletion_requested_at is not null,
    'role', case when v_store.deletion_requested_at is null and v_member.status = 'active' then v_member.role end,
    'store', case when v_store.id is not null and v_store.deletion_requested_at is null and v_member.status = 'active'
                  then app.store_json(v_store) end
  ));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('get_my_context', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.create_store (Phase 1 US-005, Phase 2 AU-07). Creates the store and the owner
-- membership atomically. Retries with the same key replay the original result; a second
-- store for the same user is LIMIT_EXCEEDED (P0: one store per user), including under races.
-- ---------------------------------------------------------------------------------------------
create function api.create_store(
  p_name text,
  p_contact_phone text,
  p_currency text,
  p_reply_locale text,
  p_business_city text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_fields jsonb;
  v_errors jsonb;
  v_hash text;
  v_result jsonb;
  v_store app.stores;
  v_code text;
  v_detail text;
  v_state text;
  v_constraint text;
begin
  v_uid := app.require_end_user();
  v_fields := jsonb_build_object(
    'name', btrim(p_name),
    'contact_phone', p_contact_phone,
    'currency', p_currency,
    'reply_locale', p_reply_locale,
    'business_city', btrim(p_business_city)
  );
  v_errors := app.store_field_errors(v_fields);
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  v_hash := app.request_hash(v_fields);
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'create_store', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  if exists (select 1 from app.store_members where user_id = v_uid) then
    perform app.fail('LIMIT_EXCEEDED', '{"reason": "one_store_per_user"}');
  end if;

  insert into app.stores (name, contact_phone, currency, reply_locale, business_city)
  values (v_fields ->> 'name', v_fields ->> 'contact_phone', v_fields ->> 'currency',
          v_fields ->> 'reply_locale', v_fields ->> 'business_city')
  returning * into v_store;

  insert into app.store_members (store_id, user_id, role) values (v_store.id, v_uid, 'owner');

  perform app.audit(v_store.id, 'store.create', 'store', v_store.id, null, app.store_json(v_store));

  v_result := app.ok(app.store_json(v_store));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'create_store', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name, v_code = message_text;
    if v_constraint = 'store_members_one_store_per_user_p0' then
      return app.err('LIMIT_EXCEEDED', '{"reason": "one_store_per_user"}');
    end if;
    return app.internal_error('create_store', '23505', v_code);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('create_store', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.update_store (ST-02 profile, ST-04 payments). Partial update: `p_changes` holds only
-- the fields being changed. Optimistic concurrency on `version`; currency is locked once
-- set by the first approved order (CURRENCY_LOCKED); at least one payment method stays on.
-- ---------------------------------------------------------------------------------------------
create function api.update_store(
  p_store_id uuid,
  p_expected_version integer,
  p_changes jsonb,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_allowed text[] := array['name', 'contact_phone', 'currency', 'reply_locale', 'business_city',
                            'cod_enabled', 'other_payment_enabled'];
  v_changes jsonb;
  v_unknown text;
  v_errors jsonb;
  v_hash text;
  v_result jsonb;
  v_old app.stores;
  v_new app.stores;
  v_before jsonb;
  v_after jsonb;
  v_key text;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'settings.manage');

  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"changes": "required"}}');
  end if;
  if p_expected_version is null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"expected_version": "required"}}');
  end if;
  select k into v_unknown from jsonb_object_keys(p_changes) as k where not (k = any (v_allowed)) limit 1;
  if v_unknown is not null then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object(v_unknown, 'unknown')));
  end if;

  v_changes := p_changes;
  if v_changes ? 'name' then
    v_changes := jsonb_set(v_changes, '{name}', to_jsonb(btrim(v_changes ->> 'name')));
  end if;
  if v_changes ? 'business_city' then
    v_changes := jsonb_set(v_changes, '{business_city}', to_jsonb(btrim(v_changes ->> 'business_city')));
  end if;
  v_errors := app.store_field_errors(v_changes);
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'version', p_expected_version, 'changes', v_changes));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'update_store', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  select * into v_old from app.stores where id = p_store_id for update;
  if v_old.version <> p_expected_version then
    perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_old.version));
  end if;
  if v_changes ? 'currency' and v_changes ->> 'currency' <> v_old.currency and v_old.currency_locked_at is not null then
    perform app.fail('CURRENCY_LOCKED');
  end if;
  if not (coalesce((v_changes ->> 'cod_enabled')::boolean, v_old.cod_enabled)
          or coalesce((v_changes ->> 'other_payment_enabled')::boolean, v_old.other_payment_enabled)) then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"payment_methods": "at_least_one"}}');
  end if;

  update app.stores set
    name                  = coalesce(v_changes ->> 'name', name),
    contact_phone         = coalesce(v_changes ->> 'contact_phone', contact_phone),
    currency              = coalesce(v_changes ->> 'currency', currency),
    reply_locale          = coalesce(v_changes ->> 'reply_locale', reply_locale),
    business_city         = coalesce(v_changes ->> 'business_city', business_city),
    cod_enabled           = coalesce((v_changes ->> 'cod_enabled')::boolean, cod_enabled),
    other_payment_enabled = coalesce((v_changes ->> 'other_payment_enabled')::boolean, other_payment_enabled),
    version               = version + 1,
    updated_at            = now()
  where id = p_store_id
  returning * into v_new;

  v_before := '{}'::jsonb;
  v_after := '{}'::jsonb;
  for v_key in select jsonb_object_keys(v_changes) loop
    v_before := v_before || jsonb_build_object(v_key, to_jsonb(v_old) -> v_key);
    v_after := v_after || jsonb_build_object(v_key, to_jsonb(v_new) -> v_key);
  end loop;
  perform app.audit(p_store_id, 'store.update', 'store', p_store_id, v_before, v_after);

  v_result := app.ok(app.store_json(v_new));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'update_store', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('update_store', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.advance_onboarding (Phase 2 AU-08 → AU-09 → done). Moves forward only; repeating a
-- step is a no-op, so retries are safe without a key.
-- ---------------------------------------------------------------------------------------------
create function api.advance_onboarding(p_store_id uuid, p_step text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_order text[] := array['zones', 'payments', 'done'];
  v_store app.stores;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'settings.manage');
  if p_step is null or not (p_step = any (array['payments', 'done'])) then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"step": "invalid"}}');
  end if;

  select * into v_store from app.stores where id = p_store_id for update;
  if array_position(v_order, p_step) > array_position(v_order, v_store.onboarding_step) then
    update app.stores
       set onboarding_step = p_step, version = version + 1, updated_at = now()
     where id = p_store_id
    returning * into v_store;
    perform app.audit(p_store_id, 'store.onboarding', 'store', p_store_id, null,
                      jsonb_build_object('onboarding_step', p_step));
  end if;
  return app.ok(app.store_json(v_store));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('advance_onboarding', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Delivery zones (Phase 1 US-006, Phase 2 AU-08 / ST-03).
-- ---------------------------------------------------------------------------------------------
create function api.upsert_zone(
  p_store_id uuid,
  p_zone_id uuid,
  p_expected_version integer,
  p_name text,
  p_fee integer,
  p_time_text text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_name text := btrim(p_name);
  v_time text := nullif(btrim(p_time_text), '');
  v_errors jsonb;
  v_hash text;
  v_result jsonb;
  v_old app.delivery_zones;
  v_zone app.delivery_zones;
  v_count integer;
  v_code text;
  v_detail text;
  v_state text;
  v_constraint text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'settings.manage');

  v_errors := app.zone_field_errors(v_name, p_fee, v_time);
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'zone_id', p_zone_id,
    'version', p_expected_version, 'name', v_name, 'fee', p_fee, 'time_text', v_time));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'upsert_zone', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  if p_zone_id is null then
    -- Serialise zone creation per store so the limit and sort order are exact.
    perform 1 from app.stores where id = p_store_id for update;
    select count(*) into v_count from app.delivery_zones where store_id = p_store_id and active;
    if v_count >= 50 then
      perform app.fail('LIMIT_EXCEEDED', '{"max_zones": 50}');
    end if;
    insert into app.delivery_zones (store_id, name, fee, time_text, sort)
    values (p_store_id, v_name, p_fee, v_time,
            coalesce((select max(sort) from app.delivery_zones where store_id = p_store_id), 0) + 1)
    returning * into v_zone;
    perform app.audit(p_store_id, 'zone.create', 'delivery_zone', v_zone.id, null, app.zone_json(v_zone));
  else
    select * into v_old from app.delivery_zones
     where id = p_zone_id and store_id = p_store_id and active
       for update;
    if not found then
      perform app.fail('NOT_FOUND');
    end if;
    if p_expected_version is null or v_old.version <> p_expected_version then
      perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_old.version));
    end if;
    update app.delivery_zones
       set name = v_name, fee = p_fee, time_text = v_time, version = version + 1, updated_at = now()
     where id = p_zone_id
    returning * into v_zone;
    perform app.audit(p_store_id, 'zone.update', 'delivery_zone', v_zone.id, app.zone_json(v_old), app.zone_json(v_zone));
  end if;

  v_result := app.ok(app.zone_json(v_zone));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'upsert_zone', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name, v_code = message_text;
    if v_constraint = 'delivery_zones_active_name' then
      return app.err('VALIDATION_FAILED', '{"fields": {"name": "duplicate"}}');
    end if;
    return app.internal_error('upsert_zone', '23505', v_code);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('upsert_zone', v_state, v_code);
end;
$$;

-- Removing a zone deactivates it (Phase 3: zones referenced by orders are never deleted).
-- Repeating the call on an already removed zone succeeds without changes.
create function api.deactivate_zone(p_store_id uuid, p_zone_id uuid, p_expected_version integer)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_old app.delivery_zones;
  v_zone app.delivery_zones;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'settings.manage');

  select * into v_old from app.delivery_zones where id = p_zone_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if not v_old.active then
    return app.ok(app.zone_json(v_old));
  end if;
  if p_expected_version is null or v_old.version <> p_expected_version then
    perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_old.version));
  end if;
  update app.delivery_zones
     set active = false, version = version + 1, updated_at = now()
   where id = p_zone_id
  returning * into v_zone;
  perform app.audit(p_store_id, 'zone.deactivate', 'delivery_zone', p_zone_id,
                    jsonb_build_object('active', true), jsonb_build_object('active', false));
  return app.ok(app.zone_json(v_zone));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('deactivate_zone', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Function privileges: only signed-in users may call the api; nothing for anon.
-- ---------------------------------------------------------------------------------------------
revoke all on all functions in schema api, app, internal from public, anon, authenticated;
grant execute on function app.is_member(uuid) to authenticated;
grant execute on function
  api.get_my_context(),
  api.create_store(text, text, text, text, text, uuid),
  api.update_store(uuid, integer, jsonb, uuid),
  api.advance_onboarding(uuid, text),
  api.upsert_zone(uuid, uuid, integer, text, integer, text, uuid),
  api.deactivate_zone(uuid, uuid, integer)
to authenticated;
