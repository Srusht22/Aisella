-- Phase 9: connecting and disconnecting per-bot channels (Telegram, Viber). Local only.
-- Meta (Instagram, Messenger, WhatsApp) and TikTok connect through OAuth / Embedded Signup, which needs
-- the platforms' app review first: not implemented (blocked), see docs/implementation/phase-9.
--
-- Flow (no party can attach a bot it does not control, or attach it to a store it does not manage):
--   1. The seller (settings.manage) asks for a one-time nonce: api.begin_channel_connect. Only its hash
--      is stored; it expires after 10 minutes.
--   2. The app gives the nonce and the bot token to the channel-connect Edge Function, which asks the
--      provider who the token belongs to (Telegram getMe, Viber get_account_info): the account id
--      comes from the provider, never from the seller.
--   3. The function, with its own LOGIN role aisellia_channel_connector (two functions, no tables),
--      redeems the nonce: api.channel_register_bot stores the token and a fresh webhook secret in Vault
--      and creates the connection in the nonce's store, state 'connecting'. A bot already connected to
--      another store is refused (no takeover).
--   4. It registers the webhook with the provider, then api.channel_finish_connect marks the connection
--      connected, or removes it and its secrets.
-- Connecting is refused while a provider is planned or in development (only pilot / available), so no
-- seller can connect a real account before the owner releases the provider.
-- api.disconnect_channel ends a connection: its Vault secrets are deleted, queued sends are cancelled,
-- and the bot's webhook URL refuses further deliveries.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'aisellia_channel_connector') then
    create role aisellia_channel_connector login noinherit;
  end if;
end $$;
alter role aisellia_channel_connector login noinherit nocreatedb nocreaterole nobypassrls noreplication connection limit 10;
alter role aisellia_channel_connector set statement_timeout = '10s';
alter role aisellia_channel_connector set idle_in_transaction_session_timeout = '30s';
grant usage on schema api to aisellia_channel_connector;

create table app.connect_requests (
  id            uuid primary key default gen_random_uuid(),
  store_id      uuid not null references app.stores (id),
  provider_id   text not null references app.providers (id),
  requested_by  uuid not null,
  nonce_sha256  text not null unique check (nonce_sha256 ~ '^[0-9a-f]{64}$'),
  connection_id uuid references app.connections (id),
  state         text not null default 'pending' check (state in ('pending', 'registered', 'completed', 'aborted')),
  expires_at    timestamptz not null,
  created_at    timestamptz not null default now()
);
create index connect_requests_store on app.connect_requests (store_id, created_at);
alter table app.connect_requests enable row level security;
revoke all on app.connect_requests from public, anon, authenticated;

insert into app.ai_limits (name, value) values ('channel_connects_per_store_per_hour', 10) on conflict (name) do nothing;

-- 1. The seller starts a connection and receives a one-time nonce.
create function api.begin_channel_connect(p_store_id uuid, p_provider text)
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
  if not found or v_provider.payload_format not in ('telegram_bot', 'viber_bot') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"provider": "no_bot_connect"}}');
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
  return app.ok(jsonb_build_object('nonce', v_nonce, 'provider', p_provider, 'expires_at', v_req.expires_at));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('begin_channel_connect', v_state, v_code);
end;
$$;

-- 3. The connector redeems the nonce with the account the PROVIDER reported for the token.
create function api.channel_register_bot(p_nonce text, p_provider text, p_account_id text, p_display_name text,
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
  if not found or v_req.state <> 'pending' or v_req.expires_at <= now() or v_req.provider_id is distinct from p_provider then
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
  update app.connect_requests set state = 'registered', connection_id = v_conn.id where id = v_req.id;
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

-- 4. After the provider accepted (or refused) the webhook registration.
create function api.channel_finish_connect(p_nonce text, p_ok boolean)
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
  select * into v_conn from app.connections where id = v_req.connection_id for update;
  if coalesce(p_ok, false) then
    update app.connections set state = 'connected', connected_at = now(), updated_at = now(), version = version + 1
     where id = v_conn.id;
    update app.connect_requests set state = 'completed' where id = v_req.id;
    perform app.audit(v_req.store_id, 'channel.connected', 'connection', v_conn.id, null,
                      jsonb_build_object('provider', v_req.provider_id, 'requested_by', v_req.requested_by));
  else
    delete from vault.secrets where id in (v_conn.credential_ref, v_conn.webhook_secret_ref);
    update app.connections set state = 'disconnected', credential_ref = null, webhook_secret_ref = null,
                               attention_reason = 'connect_failed', updated_at = now(), version = version + 1
     where id = v_conn.id;
    update app.connect_requests set state = 'aborted' where id = v_req.id;
  end if;
  return app.ok(jsonb_build_object('connection_id', v_conn.id, 'connected', coalesce(p_ok, false)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_finish_connect', v_state, v_code);
end;
$$;

-- The seller ends a connection (any provider).
create function api.disconnect_channel(p_store_id uuid, p_connection_id uuid)
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
  delete from vault.secrets where id in (v_conn.credential_ref, v_conn.webhook_secret_ref);
  update app.connections set state = 'disconnected', credential_ref = null, webhook_secret_ref = null, expires_at = null,
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

-- Account deletion also removes webhook secrets and connect requests (base: 20261020090000).
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
                                              where store_id = v_request.store_id and webhook_secret_ref is not null);
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

revoke all on function api.begin_channel_connect(uuid, text),
  api.channel_register_bot(text, text, text, text, text, text), api.channel_finish_connect(text, boolean),
  api.disconnect_channel(uuid, uuid)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender,
     aisellia_channel_connector;
grant execute on function api.begin_channel_connect(uuid, text), api.disconnect_channel(uuid, uuid) to authenticated;
grant execute on function api.channel_register_bot(text, text, text, text, text, text), api.channel_finish_connect(text, boolean)
  to aisellia_channel_connector;
