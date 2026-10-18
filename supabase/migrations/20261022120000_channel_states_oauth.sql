-- Phase 9: connection states for the app, and account connection through OAuth (Meta: Instagram and
-- Messenger via Facebook Login for Business, WhatsApp via Embedded Signup; TikTok via the TikTok
-- account authorization of the API for Business). Local only: no real account is connected.
--
-- States the app shows (api.list_connections ui_state; api.list_channel_providers):
--   disconnected            no connection (or ended)
--   awaiting_authorization  a connect flow is in progress (connection 'connecting')
--   connected               receiving, and sending is possible
--   error                   needs the seller's attention (token revoked, webhook failed …)
--   unavailable             the provider is not released, suspended, or its sending is not verified
-- OAuth flows reuse the nonce of api.begin_channel_connect as the OAuth "state" (single use, 10 min,
-- bound to the seller's store); the channel-oauth Edge Function exchanges the code SERVER TO SERVER,
-- discovers the accounts the seller granted, and registers each with the connector role
-- (api.channel_register_account). Access tokens and refresh tokens are kept only in Vault.
-- TikTok fix: the webhook normaliser used client_key (our app, identical for every store) as the
-- account; it now uses user_openid (the authorizing business account) and the conversation id as the
-- customer, so two stores' TikTok accounts can never collide.

alter table app.providers add column connect_method text
  check (connect_method in ('bot_token', 'meta_login', 'whatsapp_signup', 'tiktok_oauth'));
update app.providers set connect_method = case id
  when 'telegram' then 'bot_token' when 'viber' then 'bot_token'
  when 'instagram' then 'meta_login' when 'messenger' then 'meta_login'
  when 'whatsapp' then 'whatsapp_signup' when 'tiktok' then 'tiktok_oauth' end
 where id in ('telegram', 'viber', 'instagram', 'messenger', 'whatsapp', 'tiktok');

-- Non-secret account details the adapters need (WhatsApp business account id, Page id behind an
-- Instagram account, username); never a token.
alter table app.connections add column provider_meta jsonb not null default '{}'
  check (jsonb_typeof(provider_meta) = 'object' and octet_length(provider_meta::text) <= 2000),
  add column refresh_ref uuid;
alter table app.connect_requests add column connection_ids uuid[] not null default '{}';

-- The state a seller sees for one connection.
create function app.connection_ui_state(p_conn app.connections)
returns text
language sql stable
as $$
  select case
    when p_conn.state = 'disconnected' then 'disconnected'
    when p_conn.state = 'connecting' then 'awaiting_authorization'
    when p_conn.state = 'needs_attention' then 'error'
    when p.status in ('planned', 'suspended') or (p.status = 'in_development' and not p_conn.is_test)
         or app.provider_capability(p.id, 'outbound_text', true) is distinct from 'true'::jsonb then 'unavailable'
    else 'connected' end
  from app.providers p where p.id = p_conn.provider_id;
$$;

create or replace function api.list_connections(p_store_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  return app.ok(jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'provider', c.provider_id, 'provider_name', p.display_name,
                                        'provider_status', p.status, 'display_name', c.display_name, 'state', c.state,
                                        'ui_state', app.connection_ui_state(c),
                                        'can_send', app.connection_ui_state(c) = 'connected',
                                        'attention_reason', c.attention_reason, 'is_test', c.is_test,
                                        'username', c.provider_meta ->> 'username',
                                        'last_event_at', c.last_event_at, 'last_send_ok_at', c.last_send_ok_at,
                                        'expires_at', c.expires_at) order by c.created_at)
      from app.connections c join app.providers p on p.id = c.provider_id
     where c.store_id = p_store_id and c.state <> 'disconnected'), '[]'::jsonb)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_connections', v_state, v_code);
end;
$$;

-- Every provider with how to connect it and whether it can be connected now.
create function api.list_channel_providers(p_store_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  return app.ok(jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'provider', p.id, 'name', p.display_name, 'status', p.status, 'connect_method', p.connect_method,
             'can_connect', p.status in ('pilot', 'available') and p.connect_method is not null,
             'ui_state', coalesce((select app.connection_ui_state(c) from app.connections c
                                    where c.store_id = p_store_id and c.provider_id = p.id and c.state <> 'disconnected'
                                    order by c.created_at desc limit 1),
                                  case when p.status in ('pilot', 'available') then 'disconnected' else 'unavailable' end))
           order by p.display_name)
      from app.providers p where p.connect_method is not null), '[]'::jsonb)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_channel_providers', v_state, v_code);
end;
$$;

-- 3'. The connector registers one OAuth-granted account (a Page, an Instagram account, a WhatsApp
-- number, a TikTok business account) under the seller's nonce. Several accounts may follow one grant.
create function api.channel_register_account(p_nonce text, p_provider text, p_account_id text, p_display_name text,
                                             p_credential text, p_refresh_token text, p_expires_at timestamptz,
                                             p_meta jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_req app.connect_requests;
  v_conn app.connections;
  v_other uuid;
  v_code text;
  v_detail text;
  v_state text;
begin
  select * into v_req from app.connect_requests
   where nonce_sha256 = app.sha256_hex(coalesce(p_nonce, '')) for update;
  if not found or v_req.state not in ('pending', 'registered') or v_req.expires_at <= now()
     or v_req.provider_id is distinct from p_provider
     or (select connect_method from app.providers where id = p_provider) not in ('meta_login', 'whatsapp_signup', 'tiktok_oauth') then
    perform app.fail('NOT_FOUND');
  end if;
  if p_account_id is null or char_length(p_account_id) not between 1 and 200
     or p_credential is null or char_length(p_credential) not between 20 and 2000
     or (p_refresh_token is not null and char_length(p_refresh_token) not between 20 and 2000)
     or jsonb_typeof(coalesce(p_meta, '{}')) <> 'object' or octet_length(coalesce(p_meta, '{}')::text) > 2000
     or coalesce(cardinality(v_req.connection_ids), 0) >= 20 then
    perform app.fail('VALIDATION_FAILED');
  end if;
  select id into v_other from app.connections
   where provider_id = p_provider and external_account_id = p_account_id and state <> 'disconnected'
     and store_id <> v_req.store_id;
  if v_other is not null then
    return app.err('ACCOUNT_IN_USE', '{}');   -- the request stays usable for the seller's other accounts
  end if;
  select * into v_conn from app.connections
   where provider_id = p_provider and external_account_id = p_account_id and state <> 'disconnected'
     and store_id = v_req.store_id for update;
  if found then
    delete from vault.secrets where id in (v_conn.credential_ref, v_conn.webhook_secret_ref, v_conn.refresh_ref);
    update app.connections
       set credential_ref = vault.create_secret(p_credential),
           refresh_ref = case when p_refresh_token is not null then vault.create_secret(p_refresh_token) end,
           webhook_secret_ref = null, credential_kind = 'oauth', expires_at = p_expires_at,
           display_name = app.channel_clean_name(p_display_name), provider_meta = coalesce(p_meta, '{}'),
           state = 'connecting', attention_reason = null, updated_at = now(), version = version + 1
     where id = v_conn.id
    returning * into v_conn;
  else
    insert into app.connections (store_id, provider_id, external_account_id, display_name, state, credential_ref, refresh_ref,
                                 credential_kind, expires_at, provider_meta, connected_by, is_test)
    values (v_req.store_id, p_provider, p_account_id, app.channel_clean_name(p_display_name), 'connecting',
            vault.create_secret(p_credential),
            case when p_refresh_token is not null then vault.create_secret(p_refresh_token) end,
            'oauth', p_expires_at, coalesce(p_meta, '{}'), v_req.requested_by, false)
    returning * into v_conn;
  end if;
  update app.connect_requests
     set state = 'registered', connection_id = coalesce(connection_id, v_conn.id),
         connection_ids = array(select distinct x from unnest(connection_ids || v_conn.id) x)
   where id = v_req.id;
  return app.ok(jsonb_build_object('connection_id', v_conn.id));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_register_account', v_state, v_code);
end;
$$;

-- Token refresh (TikTok access tokens live one day): the worker asks which connections are due,
-- refreshes with the provider, and stores the new tokens. Sender role only.
create function api.channel_due_refreshes()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  return app.ok(jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object('connection_id', c.id, 'provider', c.provider_id,
                                        'refresh_token', (select decrypted_secret from vault.decrypted_secrets where id = c.refresh_ref)))
      from (select * from app.connections c
             where c.refresh_ref is not null and c.state in ('connected', 'needs_attention')
               and c.expires_at is not null and c.expires_at < now() + interval '2 hours'
             order by c.expires_at limit 20) c), '[]'::jsonb)));
end;
$$;

create function api.channel_store_refresh(p_connection_id uuid, p_ok boolean, p_access_token text, p_refresh_token text,
                                          p_expires_at timestamptz)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_conn app.connections;
begin
  select * into v_conn from app.connections where id = p_connection_id and refresh_ref is not null for update;
  if not found then
    return app.err('NOT_FOUND', '{}');
  end if;
  if not coalesce(p_ok, false) then
    update app.connections set state = 'needs_attention', attention_reason = 'token_refresh_failed', updated_at = now(),
                               version = version + 1
     where id = v_conn.id;
    perform app.audit(v_conn.store_id, 'channel.needs_attention', 'connection', v_conn.id, null,
                      jsonb_build_object('reason', 'token_refresh_failed', 'actor', 'system'));
    return app.ok(jsonb_build_object('state', 'needs_attention'));
  end if;
  if p_access_token is null or char_length(p_access_token) not between 20 and 2000
     or (p_refresh_token is not null and char_length(p_refresh_token) not between 20 and 2000) or p_expires_at is null then
    return app.err('VALIDATION_FAILED', '{}');
  end if;
  delete from vault.secrets where id = v_conn.credential_ref
     or (p_refresh_token is not null and id = v_conn.refresh_ref);
  update app.connections
     set credential_ref = vault.create_secret(p_access_token),
         refresh_ref = case when p_refresh_token is not null then vault.create_secret(p_refresh_token) else refresh_ref end,
         expires_at = p_expires_at, state = case when state = 'needs_attention' and attention_reason = 'token_refresh_failed'
                                                 then 'connected' else state end,
         updated_at = now()
   where id = v_conn.id;
  return app.ok(jsonb_build_object('state', 'refreshed'));
end;
$$;

-- TikTok (assumed format, see 20261021160000): the account is the authorizing business (user_openid),
-- the customer is the conversation.
create or replace function app.channel_normalize_tiktok_bm(p_provider app.providers, p_conn app.connections, p_body jsonb)
returns jsonb
language plpgsql stable
as $$
declare
  v_content jsonb;
begin
  if jsonb_typeof(p_body) <> 'object' or p_body ->> 'event' is distinct from 'direct_message.receive'
     or coalesce(p_body ->> 'user_openid', '') = '' or jsonb_typeof(p_body -> 'content') <> 'string' then
    return jsonb_build_object('events', '[]'::jsonb);
  end if;
  begin
    v_content := (p_body ->> 'content')::jsonb;
  exception when others then
    return jsonb_build_object('events', '[]'::jsonb);
  end;
  if jsonb_typeof(v_content) <> 'object' or coalesce(v_content ->> 'message_id', '') = ''
     or coalesce(v_content ->> 'conversation_id', '') = '' then
    return jsonb_build_object('events', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'event_id', 'dm:' || (v_content ->> 'message_id'),
    'events', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'kind', 'message',
      'account_id', p_body ->> 'user_openid',
      'external_user_id', v_content ->> 'conversation_id',
      'external_message_id', v_content ->> 'message_id',
      'occurred_at', case when coalesce(v_content ->> 'create_time', p_body ->> 'create_time') ~ '^[0-9]{9,12}$'
                          then to_jsonb(to_timestamp(coalesce(v_content ->> 'create_time', p_body ->> 'create_time')::bigint)) end,
      'text', case when jsonb_typeof(v_content -> 'text') = 'string' then v_content -> 'text' end))));
end;
$$;

create or replace function api.begin_channel_connect(p_store_id uuid, p_provider text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_provider app.providers;
  v_nonce text;
  v_req app.connect_requests;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'settings.manage');
  select * into v_provider from app.providers where id = p_provider;
  if not found or v_provider.connect_method is null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"provider": "no_connect"}}');
  end if;
  if v_provider.status not in ('pilot', 'available') then
    perform app.fail('CHANNEL_UNAVAILABLE', jsonb_build_object('provider_status', v_provider.status));
  end if;
  if (select count(*) from app.connect_requests where store_id = p_store_id and created_at > now() - interval '1 hour')
     >= app.ai_limit('channel_connects_per_store_per_hour') then
    perform app.fail('RATE_LIMITED', '{"scope": "connect_hour", "retry_after_seconds": 3600}');
  end if;
  v_nonce := encode(extensions.gen_random_bytes(32), 'hex');
  insert into app.connect_requests (store_id, provider_id, requested_by, nonce_sha256, expires_at)
  values (p_store_id, p_provider, v_uid, app.sha256_hex(v_nonce), now() + interval '10 minutes')
  returning * into v_req;
  perform app.audit(p_store_id, 'channel.connect_started', 'connect_request', v_req.id, null,
                    jsonb_build_object('provider', p_provider));
  return app.ok(jsonb_build_object('nonce', v_nonce, 'provider', p_provider, 'connect_method', v_provider.connect_method,
                                   'expires_at', v_req.expires_at));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('begin_channel_connect', v_state, v_code);
end;
$$;

create or replace function api.channel_register_bot(p_nonce text, p_provider text, p_account_id text, p_display_name text,
                                         p_credential text, p_webhook_secret text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_req app.connect_requests;
  v_conn app.connections;
  v_other uuid;
  v_code text;
  v_detail text;
  v_state text;
begin
  select * into v_req from app.connect_requests
   where nonce_sha256 = app.sha256_hex(coalesce(p_nonce, '')) for update;
  if not found or v_req.state <> 'pending' or v_req.expires_at <= now() or v_req.provider_id is distinct from p_provider
     or (select connect_method from app.providers where id = p_provider) is distinct from 'bot_token' then
    perform app.fail('NOT_FOUND');
  end if;
  if p_account_id is null or char_length(p_account_id) not between 1 and 200
     or p_credential is null or char_length(p_credential) not between 20 and 500
     or p_webhook_secret is null or char_length(p_webhook_secret) not between 32 and 256
     or p_webhook_secret !~ '^[A-Za-z0-9_-]+$' then
    perform app.fail('VALIDATION_FAILED');
  end if;
  -- One provider account belongs to one store: never taken over by another store.
  select id into v_other from app.connections
   where provider_id = p_provider and external_account_id = p_account_id and state <> 'disconnected'
     and store_id <> v_req.store_id;
  if v_other is not null then
    update app.connect_requests set state = 'aborted' where id = v_req.id;
    return app.err('ACCOUNT_IN_USE', '{}');
  end if;
  select * into v_conn from app.connections
   where provider_id = p_provider and external_account_id = p_account_id and state <> 'disconnected'
     and store_id = v_req.store_id for update;
  if found then
    -- Reconnecting the same bot (token rotation): the old secrets are replaced, not kept.
    delete from vault.secrets where id in (v_conn.credential_ref, v_conn.webhook_secret_ref);
    update app.connections
       set credential_ref = vault.create_secret(p_credential), webhook_secret_ref = vault.create_secret(p_webhook_secret),
           credential_kind = 'bot_token', display_name = app.channel_clean_name(p_display_name), state = 'connecting',
           attention_reason = null, updated_at = now(), version = version + 1
     where id = v_conn.id
    returning * into v_conn;
  else
    insert into app.connections (store_id, provider_id, external_account_id, display_name, state, credential_ref,
                                 webhook_secret_ref, credential_kind, connected_by, is_test)
    values (v_req.store_id, p_provider, p_account_id, app.channel_clean_name(p_display_name), 'connecting',
            vault.create_secret(p_credential), vault.create_secret(p_webhook_secret), 'bot_token', v_req.requested_by, false)
    returning * into v_conn;
  end if;
  update app.connect_requests set state = 'registered', connection_id = v_conn.id, connection_ids = array[v_conn.id]
   where id = v_req.id;
  return app.ok(jsonb_build_object('connection_id', v_conn.id));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_register_bot', v_state, v_code);
end;
$$;

create or replace function api.channel_finish_connect(p_nonce text, p_ok boolean)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_req app.connect_requests;
  v_conn app.connections;
  v_code text;
  v_detail text;
  v_state text;
begin
  select * into v_req from app.connect_requests
   where nonce_sha256 = app.sha256_hex(coalesce(p_nonce, '')) for update;
  if not found or v_req.state <> 'registered' or v_req.expires_at <= now() - interval '5 minutes' then
    perform app.fail('NOT_FOUND');
  end if;
  -- Every account registered under this nonce (one bot, or the Pages / numbers an OAuth grant gave).
  for v_conn in select * from app.connections
                 where id = any (case when cardinality(v_req.connection_ids) > 0 then v_req.connection_ids
                                      else array[v_req.connection_id] end) for update
  loop
    if coalesce(p_ok, false) then
      update app.connections set state = 'connected', connected_at = now(), updated_at = now(), version = version + 1
       where id = v_conn.id;
      perform app.audit(v_req.store_id, 'channel.connected', 'connection', v_conn.id, null,
                        jsonb_build_object('provider', v_req.provider_id, 'requested_by', v_req.requested_by));
    else
      delete from vault.secrets where id in (v_conn.credential_ref, v_conn.webhook_secret_ref, v_conn.refresh_ref);
      update app.connections set state = 'disconnected', credential_ref = null, webhook_secret_ref = null, refresh_ref = null,
                                 attention_reason = 'connect_failed', updated_at = now(), version = version + 1
       where id = v_conn.id;
    end if;
  end loop;
  update app.connect_requests set state = case when coalesce(p_ok, false) then 'completed' else 'aborted' end where id = v_req.id;
  return app.ok(jsonb_build_object('connection_id', v_req.connection_id, 'connection_ids', to_jsonb(v_req.connection_ids),
                                   'connected', coalesce(p_ok, false)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_finish_connect', v_state, v_code);
end;
$$;

create or replace function api.disconnect_channel(p_store_id uuid, p_connection_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_conn app.connections;
  v_cancelled integer;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'settings.manage');
  select * into v_conn from app.connections where id = p_connection_id and store_id = p_store_id for update;
  if not found or v_conn.state = 'disconnected' then
    perform app.fail('NOT_FOUND');
  end if;
  if exists (select 1 from app.send_requests where connection_id = v_conn.id and state = 'sending') then
    perform app.fail('SEND_IN_PROGRESS');
  end if;
  update app.send_requests set state = 'cancelled', error_code = 'disconnected', updated_at = now()
   where connection_id = v_conn.id and state = 'queued';
  get diagnostics v_cancelled = row_count;
  update app.messages m set delivery_state = 'cancelled'
    from app.send_requests s where s.message_id = m.id and s.connection_id = v_conn.id and s.error_code = 'disconnected'
     and m.delivery_state = 'queued';
  delete from vault.secrets where id in (v_conn.credential_ref, v_conn.webhook_secret_ref, v_conn.refresh_ref);
  update app.connections set state = 'disconnected', credential_ref = null, webhook_secret_ref = null, refresh_ref = null, expires_at = null,
                             updated_at = now(), version = version + 1
   where id = v_conn.id;
  perform app.audit(p_store_id, 'channel.disconnected', 'connection', v_conn.id, null,
                    jsonb_build_object('provider', v_conn.provider_id, 'sends_cancelled', v_cancelled));
  return app.ok(jsonb_build_object('id', v_conn.id, 'disconnected', true, 'sends_cancelled', v_cancelled));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('disconnect_channel', v_state, v_code);
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

revoke all on function app.connection_ui_state(app.connections), api.list_channel_providers(uuid),
  api.channel_register_account(text, text, text, text, text, text, timestamptz, jsonb),
  api.channel_due_refreshes(), api.channel_store_refresh(uuid, boolean, text, text, timestamptz)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender,
     aisellia_channel_connector;
grant execute on function api.list_channel_providers(uuid) to authenticated;
grant execute on function api.channel_register_account(text, text, text, text, text, text, timestamptz, jsonb)
  to aisellia_channel_connector;
grant execute on function api.channel_due_refreshes(), api.channel_store_refresh(uuid, boolean, text, text, timestamptz)
  to aisellia_channel_sender;
