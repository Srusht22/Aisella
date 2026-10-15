-- Aisellia — Phase 5: account deletion (Phase 1 US-004, Phase 2 ST-08, Phase 3 authorization §4).
--
-- * The seller asks from the app after re-entering the password (the JWT's `amr` must show a
--   password sign-in within the last 5 minutes) and, when a store exists, typing its name.
-- * Access ends immediately: the store is marked deleted, so app.is_member() is false and every
--   read (RLS) and mutation (require_permission) treats it as NOT_FOUND.
-- * After the 14-day grace period (Phase 1 D-13) internal.purge_due_account_deletions() removes
--   the store data and the auth user. It is scheduled daily with pg_cron where available.
-- * Not in Phase 5: the confirmation email (needs the production SMTP sender) and cancelling a
--   request from the app (support procedure). See docs/implementation/phase-5.

create table app.account_deletion_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null,
  store_id      uuid,
  requested_at  timestamptz not null default now(),
  execute_after timestamptz not null,
  status        text not null default 'pending' check (status in ('pending', 'done')),
  executed_at   timestamptz
);
create unique index account_deletion_one_pending_per_user
  on app.account_deletion_requests (user_id) where status = 'pending';
alter table app.account_deletion_requests enable row level security;  -- no policy: deny all
revoke all on app.account_deletion_requests from public, anon, authenticated;

-- Grace period before data is purged (Phase 1 D-13).
create function app.deletion_grace() returns interval language sql immutable
as $$ select interval '14 days' $$;

-- Re-authentication window for destructive account actions (Phase 3 §3.1).
create function app.recent_password_auth(p_within interval)
returns boolean
language sql stable
as $$
  select exists (
    select 1
    from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) as m
    where m ->> 'method' = 'password'
      and to_timestamp((m ->> 'timestamp')::double precision) > now() - p_within
  );
$$;

-- ---------------------------------------------------------------------------------------------
-- api.request_account_deletion
-- ---------------------------------------------------------------------------------------------
create function api.request_account_deletion(p_confirm_store_name text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_member app.store_members;
  v_store app.stores;
  v_request app.account_deletion_requests;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();

  select * into v_request from app.account_deletion_requests
   where user_id = v_uid and status = 'pending';
  if found then
    -- Repeating the request is harmless and returns the same schedule.
    return app.ok(jsonb_build_object('execute_after', v_request.execute_after));
  end if;

  if not app.recent_password_auth(interval '5 minutes') then
    perform app.fail('REAUTHENTICATION_REQUIRED');
  end if;

  select * into v_member from app.store_members where user_id = v_uid;
  if found then
    select * into v_store from app.stores where id = v_member.store_id for update;
    if v_member.role <> 'owner' then
      perform app.fail('FORBIDDEN');
    end if;
    if p_confirm_store_name is null or btrim(p_confirm_store_name) <> v_store.name then
      perform app.fail('VALIDATION_FAILED', '{"fields": {"confirm_store_name": "mismatch"}}');
    end if;
    update app.stores set deletion_requested_at = now(), updated_at = now(), version = version + 1
     where id = v_store.id;
    perform app.audit(v_store.id, 'account.deletion_requested', 'store', v_store.id, null,
                      jsonb_build_object('execute_after', now() + app.deletion_grace()));
  end if;

  insert into app.account_deletion_requests (user_id, store_id, execute_after)
  values (v_uid, v_store.id, now() + app.deletion_grace())
  returning * into v_request;

  return app.ok(jsonb_build_object('execute_after', v_request.execute_after));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('request_account_deletion', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- get_my_context: report a pending deletion (with its date) for sellers with or without a store.
-- ---------------------------------------------------------------------------------------------
create or replace function api.get_my_context()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_user auth.users;
  v_member app.store_members;
  v_store app.stores;
  v_request app.account_deletion_requests;
  v_pending boolean;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  select * into v_user from auth.users where id = v_uid;
  if not found then
    perform app.fail('UNAUTHENTICATED');
  end if;
  select * into v_request from app.account_deletion_requests
   where user_id = v_uid and status = 'pending';
  v_pending := found;
  select * into v_member from app.store_members where user_id = v_uid;
  if found then
    select * into v_store from app.stores where id = v_member.store_id;
  end if;
  return app.ok(jsonb_build_object(
    'user_id', v_uid,
    'email', v_user.email,
    'email_verified', v_user.email_confirmed_at is not null,
    'deletion_pending', v_pending,
    'deletion_execute_after', v_request.execute_after,
    'role', case when not v_pending and v_member.status = 'active' then v_member.role end,
    'store', case when v_store.id is not null and not v_pending and v_store.deletion_requested_at is null
                       and v_member.status = 'active'
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

-- A seller whose account is being deleted cannot create a new store meanwhile.
create or replace function app.require_no_pending_deletion(p_user uuid)
returns void
language plpgsql stable
as $$
begin
  if exists (select 1 from app.account_deletion_requests where user_id = p_user and status = 'pending') then
    perform app.fail('FORBIDDEN', '{"reason": "deletion_pending"}');
  end if;
end;
$$;

-- create_store as in the first migration, plus the pending-deletion check after authentication.
create or replace function api.create_store(
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
  perform app.require_no_pending_deletion(v_uid);
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
-- internal.purge_due_account_deletions: system job (service role / pg_cron only).
-- Deletes in dependency order, then the auth user (sessions and identities cascade).
-- ---------------------------------------------------------------------------------------------
create function internal.purge_due_account_deletions()
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_request app.account_deletion_requests;
  v_count integer := 0;
begin
  for v_request in
    select * from app.account_deletion_requests
     where status = 'pending' and execute_after <= now()
     order by execute_after
     for update skip locked
  loop
    if v_request.store_id is not null then
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
  return v_count;
end;
$$;

revoke all on function
  api.request_account_deletion(text),
  app.deletion_grace(),
  app.recent_password_auth(interval),
  app.require_no_pending_deletion(uuid),
  internal.purge_due_account_deletions()
from public, anon, authenticated;
revoke all on function api.get_my_context(), api.create_store(text, text, text, text, text, uuid) from public, anon;
grant execute on function
  api.get_my_context(),
  api.create_store(text, text, text, text, text, uuid),
  api.request_account_deletion(text)
to authenticated;
grant execute on function internal.purge_due_account_deletions() to service_role;

-- Daily purge where pg_cron exists (local stack and hosted Supabase both ship it).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('aisellia-purge-account-deletions', '17 3 * * *',
                          'select internal.purge_due_account_deletions()');
  end if;
end $$;
