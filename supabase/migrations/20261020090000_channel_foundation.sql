-- Aisellia — Phase 9 MC-2: the provider-neutral multi-channel foundation (local only).
--
-- Design: docs/architecture/phase-9 L (multi-channel architecture), C–F (roles, security,
-- reliability, seller-controlled sending). No real provider is integrated: the registry lists the
-- target platforms as `planned` with no capabilities, so none of them can ingest or send.
--   * Provider registry with evidence-labelled capabilities. An UNRESOLVED capability is absent.
--   * Connections (one active owner store per provider account), contacts, live conversations,
--     attachments (references only), send authorizations, delivery events, webhook events.
--   * Two LOGIN roles without passwords, one function set each:
--       aisellia_channel_ingest  → api.channel_ingest (store a verified, normalised event; nothing else)
--       aisellia_channel_sender  → api.channel_claim_send / complete / fail / state
--     The AI roles get none of these (guard test 01).
--   * api.send_message: only a signed-in seller with messages.send authorizes an exact text; its
--     SHA-256 is stored and audited, and the sender must attest the same hash. An unknown outcome
--     is never claimed again; only a new seller authorization can send again.
--   * The processor resolves the store from the verified account id (never the URL hint), claims
--     events fairly per account, deduplicates events and messages, retries with backoff, fails
--     after a bounded number of attempts, and can replay.
--   * AI on live conversations stays off: request_ai_assist refuses them unless the store's
--     ai_live_enabled switch is on; it defaults to off and no API can turn it on yet.

-- ---------------------------------------------------------------------------------------------
-- Roles (LOGIN, no password: they cannot connect until an operator sets one, outside migrations)
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'aisellia_channel_ingest') then
    create role aisellia_channel_ingest login noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'aisellia_channel_sender') then
    create role aisellia_channel_sender login noinherit;
  end if;
end $$;
alter role aisellia_channel_ingest login noinherit nocreatedb nocreaterole nobypassrls noreplication connection limit 20;
alter role aisellia_channel_sender login noinherit nocreatedb nocreaterole nobypassrls noreplication connection limit 20;
alter role aisellia_channel_ingest set statement_timeout = '10s';
alter role aisellia_channel_sender set statement_timeout = '10s';
alter role aisellia_channel_ingest set idle_in_transaction_session_timeout = '30s';
alter role aisellia_channel_sender set idle_in_transaction_session_timeout = '30s';
grant usage on schema api to aisellia_channel_ingest, aisellia_channel_sender;

insert into app.ai_limits (name, value) values
  ('channel_batch_size', 100),
  ('channel_batch_per_account', 20),
  ('channel_event_max_attempts', 8),
  ('channel_event_lease_seconds', 60),
  ('channel_stale_event_days', 7),
  ('channel_send_claim_seconds', 60),
  ('channel_send_max_attempts', 3),
  ('channel_sends_per_store_per_minute', 60),
  ('channel_sends_per_store_per_day', 2000),
  ('channel_text_max_default', 1000);

-- ---------------------------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------------------------
create table app.providers (
  id             text primary key check (id ~ '^[a-z][a-z0-9_]{1,30}$'),
  display_name   text not null check (char_length(display_name) between 1 and 60),
  -- planned: no ingest, no send. in_development: test connections only. pilot / available: all.
  -- suspended: inbound is still stored and processed (nothing is lost), sending is paused.
  status         text not null default 'planned'
                 check (status in ('planned', 'in_development', 'pilot', 'available', 'suspended')),
  adapter_version text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
insert into app.providers (id, display_name) values
  ('instagram', 'Instagram'), ('whatsapp', 'WhatsApp'), ('messenger', 'Messenger'),
  ('telegram', 'Telegram'), ('viber', 'Viber'), ('tiktok', 'TikTok');

create table app.provider_capabilities (
  provider_id  text not null references app.providers (id),
  capability   text not null check (capability in (
                 'inbound_text', 'inbound_media_types', 'outbound_text', 'send_media', 'reply_window_hours',
                 'outside_window', 'delivery_receipts', 'read_receipts', 'echoes', 'status_lookup',
                 'per_recipient_min_interval_ms', 'account_rate_limit', 'max_text_length', 'connect_flow',
                 'credential_expiry', 'per_message_cost', 'requires_payment_method', 'requires_platform_review',
                 'region_restrictions')),
  value        jsonb not null,
  evidence     text not null check (evidence in ('verified', 'assumption', 'unresolved')),
  source_url   text check (source_url is null or source_url ~ '^https://'),
  checked_on   date,
  updated_at   timestamptz not null default now(),
  primary key (provider_id, capability),
  constraint provider_capabilities_verified_source check (evidence <> 'verified' or (source_url is not null and checked_on is not null))
);

-- A capability's value, or SQL null when it is missing or UNRESOLVED (UNRESOLVED counts as absent).
create function app.provider_capability(p_provider text, p_capability text, p_verified_only boolean default false)
returns jsonb language sql stable
as $$
  select value from app.provider_capabilities
   where provider_id = p_provider and capability = p_capability
     and (evidence = 'verified' or (evidence = 'assumption' and not p_verified_only));
$$;

create function app.sha256_hex(p_text text)
returns text language sql immutable
as $$ select encode(sha256(convert_to(p_text, 'UTF8')), 'hex') $$;

-- ---------------------------------------------------------------------------------------------
-- Connections, contacts, conversations, messages
-- ---------------------------------------------------------------------------------------------
create table app.connections (
  id                  uuid primary key default gen_random_uuid(),
  store_id            uuid not null references app.stores (id),
  provider_id         text not null references app.providers (id),
  external_account_id text not null check (char_length(external_account_id) between 1 and 200),
  display_name        text check (display_name is null or char_length(display_name) between 1 and 100),
  state               text not null default 'connecting'
                      check (state in ('connecting', 'connected', 'needs_attention', 'disconnected')),
  attention_reason    text,
  credential_ref      uuid,                    -- Supabase Vault secret id; the credential is never in a table
  credential_kind     text check (credential_kind is null or credential_kind in ('oauth', 'bot_token', 'partner_token', 'none')),
  expires_at          timestamptz,
  is_test             boolean not null default false,   -- team-owned test assets; cannot serve real customers
  connected_by        uuid,
  connected_at        timestamptz,
  last_event_at       timestamptz,
  last_send_ok_at     timestamptz,
  version             integer not null default 1 check (version >= 1),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (store_id, id)
);
-- One provider account belongs to at most one store at a time (tenant isolation, D §2).
create unique index connections_active_account on app.connections (provider_id, external_account_id)
  where state <> 'disconnected';
create index connections_store on app.connections (store_id);

create table app.contacts (
  id                uuid primary key default gen_random_uuid(),
  store_id          uuid not null,
  connection_id     uuid not null,
  external_user_id  text not null check (char_length(external_user_id) between 1 and 200),
  display_name      text check (display_name is null or char_length(display_name) between 1 and 100),  -- untrusted
  phone             text,                     -- only where the provider identifies users by phone
  window_expires_at timestamptz,
  blocked           boolean not null default false,
  last_inbound_at   timestamptz,
  created_at        timestamptz not null default now(),
  unique (store_id, id),
  unique (connection_id, external_user_id),
  foreign key (store_id, connection_id) references app.connections (store_id, id)
);

alter table app.stores add column ai_live_enabled boolean not null default false;

alter table app.conversations drop constraint conversations_source_check;
alter table app.conversations add constraint conversations_source_check
  check (source in ('instagram', 'whatsapp', 'messenger', 'telegram', 'phone', 'other', 'sandbox', 'live'));
alter table app.conversations
  add column connection_id uuid,
  add column contact_id uuid,
  add constraint conversations_connection_fk foreign key (store_id, connection_id) references app.connections (store_id, id),
  add constraint conversations_contact_fk foreign key (store_id, contact_id) references app.contacts (store_id, id),
  -- Live ⇔ connected to a provider account; a sandbox or imported conversation never is.
  add constraint conversations_live check ((source = 'live') = (connection_id is not null)
                                           and (connection_id is null) = (contact_id is null));
create unique index conversations_contact on app.conversations (contact_id) where contact_id is not null;

alter table app.messages drop constraint messages_origin_check;
alter table app.messages drop constraint messages_state_check;
alter table app.messages drop constraint messages_origin;
alter table app.messages
  add column connection_id uuid,
  add column external_message_id text check (external_message_id is null or char_length(external_message_id) between 1 and 200),
  add column delivery_state text check (delivery_state is null or delivery_state in
    ('queued', 'sending', 'sent', 'delivered', 'read', 'failed', 'unknown', 'cancelled')),
  add constraint messages_origin_check check (origin in ('imported', 'seller_written', 'ai_reply_copied',
                                                         'channel_in', 'seller_sent', 'seller_external')),
  add constraint messages_state_check check (state in ('imported', 'copied', 'marked_sent', 'live')),
  add constraint messages_connection_fk foreign key (store_id, connection_id) references app.connections (store_id, id),
  add constraint messages_origin check (
    (direction = 'in' and origin = 'imported' and state = 'imported' and connection_id is null)
    or (direction = 'out' and origin = 'imported' and state = 'imported' and connection_id is null)
    or (direction = 'out' and origin = 'seller_written' and state = 'marked_sent' and connection_id is null)
    or (direction = 'out' and origin = 'ai_reply_copied' and state in ('copied', 'marked_sent') and connection_id is null)
    or (direction = 'in' and origin = 'channel_in' and state = 'live' and connection_id is not null and delivery_state is null)
    or (direction = 'out' and origin = 'seller_sent' and state = 'live' and connection_id is not null and delivery_state is not null)
    or (direction = 'out' and origin = 'seller_external' and state = 'live' and connection_id is not null));
-- Second level of deduplication: one message per provider message id and connection.
create unique index messages_external on app.messages (connection_id, external_message_id)
  where external_message_id is not null;

-- The text a seller authorized can never be changed afterwards (only purged to null by retention
-- or anonymisation).
create function app.protect_sent_text()
returns trigger
language plpgsql
as $$
begin
  if old.origin = 'seller_sent' and new.body is distinct from old.body and new.body is not null then
    raise exception 'the text of an authorized send cannot change' using errcode = 'AS002';
  end if;
  return new;
end;
$$;
create trigger messages_sent_text_immutable
  before update on app.messages
  for each row execute function app.protect_sent_text();

create table app.message_attachments (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null,
  message_id   uuid not null,
  kind         text not null check (kind in ('image', 'video', 'audio', 'voice', 'file', 'sticker', 'location', 'contact', 'other')),
  provider_ref text check (provider_ref is null or char_length(provider_ref) between 1 and 500),
  mime_type    text check (mime_type is null or char_length(mime_type) between 1 and 100),
  size_bytes   bigint check (size_bytes is null or size_bytes >= 0),
  created_at   timestamptz not null default now(),
  foreign key (store_id, message_id) references app.messages (store_id, id)
);
create index message_attachments_message on app.message_attachments (message_id);

create table app.send_requests (
  id                  uuid primary key default gen_random_uuid(),
  store_id            uuid not null,
  message_id          uuid not null unique,
  conversation_id     uuid not null,
  connection_id       uuid not null,
  contact_id          uuid not null,
  authorized_by       uuid not null,            -- always a person (a signed-in seller)
  authorized_at       timestamptz not null default now(),
  text_sha256         text not null check (text_sha256 ~ '^[0-9a-f]{64}$'),
  suggestion_id       uuid,
  ai_originated       boolean not null,
  edited              boolean not null,
  kind                text not null check (kind in ('reply', 'order_confirmation')),
  order_id            uuid,
  state               text not null default 'queued'
                      check (state in ('queued', 'sending', 'sent', 'failed', 'unknown', 'cancelled')),
  attempts            integer not null default 0 check (attempts >= 0),
  next_attempt_at     timestamptz,
  claim_expires_at    timestamptz,
  provider_message_id text check (provider_message_id is null or char_length(provider_message_id) between 1 and 200),
  error_code          text,
  resend_of           uuid references app.send_requests (id),
  resolution          text check (resolution is null or resolution in ('seller_marked_sent', 'sent_again', 'evidence')),
  resolved_by         uuid,
  resolved_at         timestamptz,
  created_at          timestamptz not null default clock_timestamp(),
  updated_at          timestamptz not null default now(),
  unique (store_id, id),
  foreign key (store_id, message_id) references app.messages (store_id, id),
  foreign key (store_id, conversation_id) references app.conversations (store_id, id),
  foreign key (store_id, connection_id) references app.connections (store_id, id),
  foreign key (store_id, contact_id) references app.contacts (store_id, id),
  foreign key (store_id, order_id) references app.orders (store_id, id),
  constraint send_requests_confirmation check ((kind = 'order_confirmation') = (order_id is not null))
);
create index send_requests_store_time on app.send_requests (store_id, created_at);
create index send_requests_due on app.send_requests (state, next_attempt_at) where state in ('queued', 'sending');
create unique index send_requests_provider_id on app.send_requests (connection_id, provider_message_id)
  where provider_message_id is not null;

create table app.delivery_events (
  id                  bigint generated always as identity primary key,
  store_id            uuid not null,
  connection_id       uuid not null,
  provider_event_key  text not null check (char_length(provider_event_key) between 1 and 300),
  provider_message_id text not null check (char_length(provider_message_id) between 1 and 200),
  state               text not null check (state in ('sent', 'delivered', 'read', 'failed')),
  provider_status     text check (provider_status is null or char_length(provider_status) <= 100),
  occurred_at         timestamptz,
  received_at         timestamptz not null default now(),
  applied             boolean not null default false,
  unique (connection_id, provider_event_key),
  foreign key (store_id, connection_id) references app.connections (store_id, id)
);
create index delivery_events_message on app.delivery_events (connection_id, provider_message_id);

create table app.webhook_events (
  id                bigint generated always as identity primary key,
  provider_id       text not null references app.providers (id),
  external_event_id text not null check (char_length(external_event_id) between 1 and 200),
  connection_hint   text check (connection_hint is null or char_length(connection_hint) <= 100),  -- from the URL; never trusted
  account_key       text,                     -- first account id in the payload, for fair claiming
  raw_sha256        text not null check (raw_sha256 ~ '^[0-9a-f]{64}$'),
  payload           jsonb,                    -- normalised events; purged after 14 days
  payload_purged_at timestamptz,
  store_id          uuid references app.stores (id),   -- known only after processing
  status            text not null default 'received'
                    check (status in ('received', 'processing', 'processed', 'ignored', 'failed')),
  attempts          integer not null default 0,
  next_attempt_at   timestamptz,
  lease_until       timestamptz,
  last_error_code   text,
  outcome           jsonb,                    -- per-item results (reasons only, never content)
  received_at       timestamptz not null default now(),
  processed_at      timestamptz,
  unique (provider_id, external_event_id),
  constraint webhook_events_payload check ((payload is null) = (payload_purged_at is not null))
);
create index webhook_events_due on app.webhook_events (status, next_attempt_at) where status in ('received', 'processing');

alter table app.providers enable row level security;
alter table app.provider_capabilities enable row level security;
alter table app.connections enable row level security;
alter table app.contacts enable row level security;
alter table app.message_attachments enable row level security;
alter table app.send_requests enable row level security;
alter table app.delivery_events enable row level security;
alter table app.webhook_events enable row level security;
revoke all on app.providers, app.provider_capabilities, app.connections, app.contacts, app.message_attachments,
  app.send_requests, app.delivery_events, app.webhook_events from public, anon, authenticated;

-- Messages now report their delivery state (live conversations only).
create or replace function app.message_json(m app.messages)
returns jsonb language sql stable
as $$
  select jsonb_build_object('id', m.id, 'direction', m.direction, 'origin', m.origin, 'body', m.body,
                            'state', m.state, 'edited', m.edited, 'suggestion_id', m.suggestion_id,
                            'author', case when m.origin in ('imported', 'channel_in', 'seller_external') then null
                                           else app.actor_label(m.created_by) end,
                            'delivery_state', m.delivery_state,
                            'created_at', m.created_at, 'body_purged', m.body_purged_at is not null);
$$;

-- ---------------------------------------------------------------------------------------------
-- Ingest (role aisellia_channel_ingest): store one verified, normalised event. Nothing else.
-- The Edge Function verifies the provider signature on the raw bytes BEFORE calling this.
-- ---------------------------------------------------------------------------------------------
create function api.channel_ingest(p_provider text, p_external_event_id text, p_connection_hint text,
                                   p_events jsonb, p_raw_sha256 text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_status text;
  v_id bigint;
  v_code text;
  v_detail text;
  v_state text;
begin
  select status into v_status from app.providers where id = p_provider;
  if not found or v_status = 'planned' then
    perform app.fail('UNKNOWN_PROVIDER');
  end if;
  if p_external_event_id is null or char_length(p_external_event_id) not between 1 and 200
     or p_raw_sha256 is null or p_raw_sha256 !~ '^[0-9a-f]{64}$'
     or (p_connection_hint is not null and char_length(p_connection_hint) > 100)
     or jsonb_typeof(p_events) is distinct from 'array' or jsonb_array_length(p_events) not between 1 and 100
     or octet_length(p_events::text) > 262144 then
    perform app.fail('VALIDATION_FAILED');
  end if;
  insert into app.webhook_events (provider_id, external_event_id, connection_hint, account_key, raw_sha256, payload)
  values (p_provider, p_external_event_id, p_connection_hint, left(p_events -> 0 ->> 'account_id', 200), p_raw_sha256, p_events)
  on conflict (provider_id, external_event_id) do nothing
  returning id into v_id;
  return app.ok(jsonb_build_object('stored', v_id is not null, 'duplicate', v_id is null));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_ingest', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Processing (system job)
-- ---------------------------------------------------------------------------------------------
-- Customer-provided names are untrusted: control characters out, length capped.
create function app.channel_clean_name(p text)
returns text language sql immutable
as $$ select nullif(left(btrim(regexp_replace(coalesce(p, ''), '[[:cntrl:]]', ' ', 'g')), 100), '') $$;

create function app.channel_contact(p_conn app.connections, p_item jsonb)
returns app.contacts
language plpgsql
as $$
declare
  v_contact app.contacts;
begin
  if coalesce(p_item ->> 'external_user_id', '') = '' then
    raise exception 'missing external_user_id' using errcode = '22023';
  end if;
  insert into app.contacts (store_id, connection_id, external_user_id, display_name)
  values (p_conn.store_id, p_conn.id, left(p_item ->> 'external_user_id', 200), app.channel_clean_name(p_item ->> 'display_name'))
  on conflict (connection_id, external_user_id)
  do update set display_name = coalesce(excluded.display_name, app.contacts.display_name)
  returning * into v_contact;
  return v_contact;
end;
$$;

create function app.channel_conversation(p_conn app.connections, p_contact app.contacts)
returns app.conversations
language plpgsql
as $$
declare
  v_conv app.conversations;
begin
  select * into v_conv from app.conversations where contact_id = p_contact.id for update;
  if not found then
    insert into app.conversations (store_id, source, is_sandbox, connection_id, contact_id, customer_label, status)
    values (p_conn.store_id, 'live', false, p_conn.id, p_contact.id, nullif(btrim(left(p_contact.display_name, 60)), ''), 'needs_reply')
    returning * into v_conv;
  end if;
  return v_conv;
end;
$$;

-- Best known delivery state of a provider message, applied to its send and message (monotonic:
-- read > delivered > sent; failed only when nothing better is known).
create function app.channel_apply_delivery(p_connection_id uuid, p_provider_message_id text)
returns void
language plpgsql
as $$
declare
  v_best text;
begin
  select case when bool_or(state = 'read') then 'read' when bool_or(state = 'delivered') then 'delivered'
              when bool_or(state = 'sent') then 'sent' when bool_or(state = 'failed') then 'failed' end
    into v_best
    from app.delivery_events where connection_id = p_connection_id and provider_message_id = p_provider_message_id;
  if v_best is null then
    return;
  end if;
  if not exists (select 1 from app.send_requests where connection_id = p_connection_id
                   and provider_message_id = p_provider_message_id) then
    return;   -- unmatched for now: applied when the send completes
  end if;
  if v_best = 'failed' then
    update app.send_requests set state = 'failed', error_code = 'provider_reported_failed', updated_at = now()
     where connection_id = p_connection_id and provider_message_id = p_provider_message_id and state in ('sending', 'unknown', 'sent');
  else
    update app.send_requests
       set state = 'sent', resolution = case when state = 'unknown' then 'evidence' else resolution end,
           resolved_at = case when state = 'unknown' then now() else resolved_at end, updated_at = now()
     where connection_id = p_connection_id and provider_message_id = p_provider_message_id and state in ('sending', 'unknown');
  end if;
  update app.messages m set delivery_state = v_best
    from app.send_requests s
   where s.connection_id = p_connection_id and s.provider_message_id = p_provider_message_id and m.id = s.message_id
     and (case v_best when 'read' then 4 when 'delivered' then 3 when 'sent' then 2 else 1 end)
         > (case m.delivery_state when 'read' then 4 when 'delivered' then 3 when 'sent' then 2
                                  when 'failed' then 1 else 0 end);
  update app.delivery_events set applied = true
   where connection_id = p_connection_id and provider_message_id = p_provider_message_id and not applied;
end;
$$;

-- One normalised item. Returns null when applied, or the reason it was ignored.
create function app.channel_apply_item(p_event app.webhook_events, p_item jsonb)
returns text
language plpgsql
as $$
declare
  v_conn app.connections;
  v_provider app.providers;
  v_contact app.contacts;
  v_conv app.conversations;
  v_msg_id uuid;
  v_at timestamptz;
  v_window jsonb;
  v_text text;
  v_kinds text;
  v_send app.send_requests;
begin
  -- The store comes from the verified account id; the URL hint can only narrow, never redirect.
  select * into v_conn from app.connections
   where provider_id = p_event.provider_id and external_account_id = p_item ->> 'account_id'
     and state in ('connected', 'needs_attention');
  if not found then
    return 'unknown_account';
  end if;
  if p_event.connection_hint is not null and p_event.connection_hint <> v_conn.id::text then
    return 'hint_mismatch';
  end if;
  select * into v_provider from app.providers where id = v_conn.provider_id;
  if v_provider.status = 'planned' or (v_provider.status = 'in_development' and not v_conn.is_test) then
    return 'provider_not_released';
  end if;
  v_at := least(coalesce((p_item ->> 'occurred_at')::timestamptz, now()), now());
  update app.connections set last_event_at = now() where id = v_conn.id;

  if p_item ->> 'kind' = 'message' then
    if coalesce(p_item ->> 'external_message_id', '') = '' then
      return 'invalid_item';
    end if;
    if v_at < now() - make_interval(days => app.ai_limit('channel_stale_event_days')) then
      return 'stale';
    end if;
    v_contact := app.channel_contact(v_conn, p_item);
    v_conv := app.channel_conversation(v_conn, v_contact);
    select string_agg(distinct a ->> 'kind', ', ') into v_kinds from jsonb_array_elements(coalesce(p_item -> 'attachments', '[]')) a;
    v_text := left(coalesce(nullif(p_item ->> 'text', ''), '[' || coalesce(v_kinds, 'empty') || ']'), 4000);
    insert into app.messages (store_id, conversation_id, direction, origin, body, state, connection_id, external_message_id)
    values (v_conn.store_id, v_conv.id, 'in', 'channel_in', v_text, 'live', v_conn.id, left(p_item ->> 'external_message_id', 200))
    on conflict (connection_id, external_message_id) where external_message_id is not null do nothing
    returning id into v_msg_id;
    if v_msg_id is null then
      return 'duplicate_message';
    end if;
    insert into app.message_attachments (store_id, message_id, kind, provider_ref, mime_type, size_bytes)
    select v_conn.store_id, v_msg_id,
           case when a ->> 'kind' in ('image', 'video', 'audio', 'voice', 'file', 'sticker', 'location', 'contact')
                then a ->> 'kind' else 'other' end,
           left(a ->> 'ref', 500), left(a ->> 'mime_type', 100), (a ->> 'size_bytes')::bigint
      from jsonb_array_elements(coalesce(p_item -> 'attachments', '[]')) a;
    v_window := app.provider_capability(v_conn.provider_id, 'reply_window_hours');
    update app.contacts
       set last_inbound_at = greatest(coalesce(last_inbound_at, v_at), v_at),
           window_expires_at = case when jsonb_typeof(v_window) = 'number'
                                    then greatest(coalesce(window_expires_at, v_at),
                                                  v_at + make_interval(hours => (v_window #>> '{}')::integer))
                                    else window_expires_at end
     where id = v_contact.id;
    update app.conversations set status = case when status = 'needs_you' then status else 'needs_reply' end,
                                 last_activity_at = now(), updated_at = now(), version = version + 1
     where id = v_conv.id;
    return null;

  elsif p_item ->> 'kind' = 'echo' then
    -- A copy of a message the business sent: ours (match by provider id, or by recipient and exact
    -- text while the send is still in flight) or one the seller wrote in the provider's own app.
    if coalesce(p_item ->> 'external_message_id', '') = '' then
      return 'invalid_item';
    end if;
    v_contact := app.channel_contact(v_conn, p_item);
    select * into v_send from app.send_requests
     where connection_id = v_conn.id and provider_message_id = p_item ->> 'external_message_id';
    if not found and p_item ? 'text' then
      select * into v_send from app.send_requests
       where connection_id = v_conn.id and contact_id = v_contact.id and state in ('sending', 'unknown')
         and provider_message_id is null and text_sha256 = app.sha256_hex(p_item ->> 'text')
       order by created_at limit 1 for update;
    end if;
    if v_send.id is not null then
      update app.send_requests
         set provider_message_id = coalesce(provider_message_id, left(p_item ->> 'external_message_id', 200)),
             state = case when state in ('sending', 'unknown') then 'sent' else state end,
             resolution = case when state = 'unknown' then 'evidence' else resolution end,
             resolved_at = case when state = 'unknown' then now() else resolved_at end,
             claim_expires_at = null, updated_at = now()
       where id = v_send.id;
      update app.messages set external_message_id = coalesce(external_message_id, left(p_item ->> 'external_message_id', 200)),
                              delivery_state = case when delivery_state in ('queued', 'sending', 'unknown') then 'sent'
                                                    else delivery_state end
       where id = v_send.message_id;
      return null;
    end if;
    v_conv := app.channel_conversation(v_conn, v_contact);
    insert into app.messages (store_id, conversation_id, direction, origin, body, state, connection_id, external_message_id)
    values (v_conn.store_id, v_conv.id, 'out', 'seller_external', left(coalesce(nullif(p_item ->> 'text', ''), '[attachment]'), 4000),
            'live', v_conn.id, left(p_item ->> 'external_message_id', 200))
    on conflict (connection_id, external_message_id) where external_message_id is not null do nothing
    returning id into v_msg_id;
    return case when v_msg_id is null then 'duplicate_message' end;

  elsif p_item ->> 'kind' in ('delivery', 'read', 'failed') then
    if coalesce(p_item ->> 'provider_message_id', '') = '' then
      return 'invalid_item';
    end if;
    insert into app.delivery_events (store_id, connection_id, provider_event_key, provider_message_id, state, provider_status, occurred_at)
    values (v_conn.store_id, v_conn.id,
            left(coalesce(p_item ->> 'provider_event_key', (p_item ->> 'kind') || ':' || (p_item ->> 'provider_message_id')), 300),
            left(p_item ->> 'provider_message_id', 200),
            case p_item ->> 'kind' when 'delivery' then 'delivered' when 'read' then 'read' else 'failed' end,
            left(p_item ->> 'provider_status', 100), v_at)
    on conflict (connection_id, provider_event_key) do nothing;
    perform app.channel_apply_delivery(v_conn.id, p_item ->> 'provider_message_id');
    return null;

  elsif p_item ->> 'kind' = 'account' then
    if p_item ->> 'status' in ('revoked', 'deauthorized') then
      update app.connections set state = 'needs_attention', attention_reason = 'access_revoked', updated_at = now(),
                                 version = version + 1
       where id = v_conn.id;
      perform app.audit(v_conn.store_id, 'channel.needs_attention', 'connection', v_conn.id, null,
                        jsonb_build_object('reason', 'access_revoked', 'actor', 'system'));
      return null;
    end if;
    return 'unsupported_account_event';
  end if;
  return 'unsupported_kind';
end;
$$;

-- Claims due events fairly (at most N per account per cycle) and applies them. Each event is
-- isolated: a failure is retried with backoff and never blocks the others.
create function internal.channel_process_batch()
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_event app.webhook_events;
  v_item jsonb;
  v_reason text;
  v_outcome jsonb;
  v_applied boolean;
  v_store uuid;
  v_count integer := 0;
  v_state text;
begin
  for v_event in
    select e.* from app.webhook_events e
     where e.id in (
       select id from (
         select id, row_number() over (partition by provider_id, coalesce(account_key, '') order by id) as rn
           from app.webhook_events
          where (status = 'received' or (status = 'processing' and lease_until < now()))
            and coalesce(next_attempt_at, '-infinity') <= now() and payload is not null) due
        where rn <= app.ai_limit('channel_batch_per_account')
        order by id limit app.ai_limit('channel_batch_size'))
     order by e.id
     for update skip locked
  loop
    update app.webhook_events set status = 'processing', attempts = attempts + 1,
                                  lease_until = now() + make_interval(secs => app.ai_limit('channel_event_lease_seconds'))
     where id = v_event.id;
    v_event.attempts := v_event.attempts + 1;
    begin
      v_outcome := '[]'::jsonb;
      v_applied := false;
      v_store := null;
      for v_item in select * from jsonb_array_elements(v_event.payload) loop
        v_reason := app.channel_apply_item(v_event, v_item);
        v_outcome := v_outcome || jsonb_build_array(coalesce(v_reason, 'applied'));
        if v_reason is null then
          v_applied := true;
          v_store := coalesce(v_store, (select store_id from app.connections
                                         where provider_id = v_event.provider_id and external_account_id = v_item ->> 'account_id'
                                           and state <> 'disconnected'));
        end if;
      end loop;
      update app.webhook_events
         set status = case when v_applied then 'processed' else 'ignored' end, outcome = v_outcome,
             store_id = coalesce(v_store, store_id), processed_at = now(), lease_until = null, last_error_code = null
       where id = v_event.id;
      v_count := v_count + 1;
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      update app.webhook_events
         set status = case when v_event.attempts >= app.ai_limit('channel_event_max_attempts') then 'failed' else 'received' end,
             next_attempt_at = now() + (array['5 seconds', '30 seconds', '2 minutes', '10 minutes', '30 minutes',
                                              '1 hour', '1 hour', '1 hour']::interval[])[least(v_event.attempts, 8)],
             lease_until = null, last_error_code = v_state
       where id = v_event.id;
    end;
  end loop;
  return v_count;
end;
$$;

-- Operator replay of stored events after a fix (idempotent thanks to both deduplication levels).
create function internal.channel_replay(p_event_ids bigint[])
returns integer
language sql volatile security definer set search_path = ''
as $$
  with r as (
    update app.webhook_events set status = 'received', attempts = 0, next_attempt_at = null, lease_until = null,
                                  last_error_code = null
     where id = any (p_event_ids) and payload is not null and status in ('failed', 'ignored', 'processed')
    returning 1)
  select count(*)::integer from r;
$$;

-- A send whose claim expired mid-flight may or may not have reached the provider: unknown, never retried.
create function internal.channel_expire_send_claims()
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_count integer;
begin
  with x as (
    update app.send_requests set state = 'unknown', error_code = 'claim_expired', claim_expires_at = null, updated_at = now()
     where state = 'sending' and claim_expires_at < now()
    returning store_id, id, message_id)
  , m as (update app.messages set delivery_state = 'unknown' where id in (select message_id from x) returning 1)
  insert into app.audit_events (store_id, actor_user_id, action, entity_type, entity_id, before, after)
  select store_id, null, 'message.send_result', 'send_request', id, null,
         jsonb_build_object('state', 'unknown', 'error_code', 'claim_expired', 'actor', 'system')
    from x;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Seller-controlled sending
-- ---------------------------------------------------------------------------------------------
create function app.channel_authorize_send(p_store_id uuid, p_uid uuid, p_conv app.conversations, p_text text,
                                           p_suggestion_id uuid, p_kind text, p_order_id uuid, p_resend_of uuid)
returns jsonb
language plpgsql
as $$
declare
  v_conn app.connections;
  v_provider app.providers;
  v_contact app.contacts;
  v_window jsonb;
  v_max jsonb;
  v_limit integer;
  v_sugg app.reply_suggestions;
  v_order app.orders;
  v_msg_id uuid;
  v_req app.send_requests;
  v_count integer;
  v_hash text;
begin
  if p_conv.connection_id is null then
    perform app.fail('NOT_A_LIVE_CONVERSATION');
  end if;
  select * into v_conn from app.connections where id = p_conv.connection_id and store_id = p_store_id;
  if v_conn.state <> 'connected' then
    perform app.fail('CHANNEL_NOT_CONNECTED', jsonb_build_object('state', v_conn.state));
  end if;
  select * into v_provider from app.providers where id = v_conn.provider_id;
  if v_provider.status in ('planned', 'suspended') or (v_provider.status = 'in_development' and not v_conn.is_test) then
    perform app.fail('CHANNEL_UNAVAILABLE', jsonb_build_object('provider_status', v_provider.status));
  end if;
  select * into v_contact from app.contacts where id = p_conv.contact_id and store_id = p_store_id;
  if v_contact.blocked then
    perform app.fail('CONTACT_BLOCKED');
  end if;
  -- Capabilities: outbound text must be VERIFIED; the window must be resolved (a number of hours,
  -- or a verified JSON null meaning "no window"). Anything missing or UNRESOLVED blocks sending.
  if app.provider_capability(v_conn.provider_id, 'outbound_text', true) is distinct from 'true'::jsonb then
    perform app.fail('CHANNEL_CAPABILITY_MISSING', '{"capability": "outbound_text"}');
  end if;
  v_window := app.provider_capability(v_conn.provider_id, 'reply_window_hours');
  if v_window is null then
    perform app.fail('CHANNEL_CAPABILITY_MISSING', '{"capability": "reply_window_hours"}');
  end if;
  if jsonb_typeof(v_window) = 'number' and (v_contact.window_expires_at is null or v_contact.window_expires_at <= now()) then
    perform app.fail('REPLY_WINDOW_CLOSED', jsonb_build_object('closed_at', v_contact.window_expires_at));
  end if;
  v_max := app.provider_capability(v_conn.provider_id, 'max_text_length');
  v_limit := case when jsonb_typeof(v_max) = 'number' then (v_max #>> '{}')::integer else app.ai_limit('channel_text_max_default') end;
  -- The text is taken exactly as the seller wrote it: never trimmed, normalised or templated.
  if p_text is null or btrim(p_text) = '' or char_length(p_text) > least(v_limit, 4000) then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object('text', 'invalid'), 'max_length', least(v_limit, 4000)));
  end if;
  if coalesce(p_kind, 'reply') not in ('reply', 'order_confirmation') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"kind": "invalid"}}');
  end if;
  if coalesce(p_kind, 'reply') = 'order_confirmation' then
    -- Confirmations only for this conversation's order once approved (BR-04), sent by this action.
    select * into v_order from app.orders where id = p_order_id and store_id = p_store_id;
    if not found or p_conv.order_id is distinct from p_order_id then
      perform app.fail('NOT_FOUND');
    end if;
    if v_order.status not in ('approved', 'processing', 'dispatched', 'delivered') then
      perform app.fail('ORDER_NOT_APPROVED', jsonb_build_object('status', v_order.status));
    end if;
  elsif p_order_id is not null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"order_id": "only_for_confirmations"}}');
  end if;
  if p_suggestion_id is not null then
    select * into v_sugg from app.reply_suggestions where id = p_suggestion_id and store_id = p_store_id
       and conversation_id = p_conv.id and status in ('suggested', 'copied');
    if not found then
      perform app.fail('NOT_FOUND');
    end if;
  end if;
  select count(*) into v_count from app.send_requests where store_id = p_store_id and created_at > now() - interval '1 minute';
  if v_count >= app.ai_limit('channel_sends_per_store_per_minute') then
    perform app.fail('RATE_LIMITED', '{"scope": "send_minute", "retry_after_seconds": 60}');
  end if;
  select count(*) into v_count from app.send_requests where store_id = p_store_id and created_at > now() - interval '24 hours';
  if v_count >= app.ai_limit('channel_sends_per_store_per_day') then
    perform app.fail('RATE_LIMITED', '{"scope": "send_day", "retry_after_seconds": 3600}');
  end if;

  v_hash := app.sha256_hex(p_text);
  insert into app.messages (store_id, conversation_id, direction, origin, body, state, edited, suggestion_id, created_by,
                            connection_id, delivery_state)
  values (p_store_id, p_conv.id, 'out', 'seller_sent', p_text, 'live',
          v_sugg.id is not null and p_text is distinct from v_sugg.text_rendered, v_sugg.id, p_uid, v_conn.id, 'queued')
  returning id into v_msg_id;
  insert into app.send_requests (store_id, message_id, conversation_id, connection_id, contact_id, authorized_by, text_sha256,
                                 suggestion_id, ai_originated, edited, kind, order_id, resend_of)
  values (p_store_id, v_msg_id, p_conv.id, v_conn.id, v_contact.id, p_uid, v_hash, v_sugg.id, v_sugg.id is not null,
          v_sugg.id is not null and p_text is distinct from v_sugg.text_rendered, coalesce(p_kind, 'reply'), p_order_id, p_resend_of)
  returning * into v_req;
  update app.conversations set status = 'waiting', last_activity_at = now(), updated_at = now(), version = version + 1
   where id = p_conv.id and status <> 'needs_you';
  -- The audit names the person and the text's hash, never the text.
  perform app.audit(p_store_id, 'message.send_authorized', 'send_request', v_req.id, null,
                    jsonb_build_object('message_id', v_msg_id, 'conversation_id', p_conv.id, 'text_sha256', v_hash,
                                       'ai_originated', v_req.ai_originated, 'edited', v_req.edited, 'kind', v_req.kind,
                                       'order_id', p_order_id, 'suggestion_id', v_sugg.id, 'resend_of', p_resend_of));
  return jsonb_build_object('send_request_id', v_req.id, 'message_id', v_msg_id, 'state', v_req.state, 'text_sha256', v_hash);
end;
$$;

create function api.send_message(p_store_id uuid, p_conversation_id uuid, p_text text, p_suggestion_id uuid,
                                 p_kind text, p_order_id uuid, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_hash text;
  v_result jsonb;
  v_conv app.conversations;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'messages.send');
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'conversation_id', p_conversation_id,
                                                'text_sha256', app.sha256_hex(coalesce(p_text, '')), 'suggestion_id', p_suggestion_id,
                                                'kind', coalesce(p_kind, 'reply'), 'order_id', p_order_id));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'send_message', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  v_conv := app.lock_conversation(p_store_id, p_conversation_id);
  v_result := app.ok(app.channel_authorize_send(p_store_id, v_uid, v_conv, p_text, p_suggestion_id, p_kind, p_order_id, null));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'send_message', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('send_message', v_state, v_code);
end;
$$;

create function api.cancel_send(p_store_id uuid, p_send_request_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_req app.send_requests;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'messages.send');
  select * into v_req from app.send_requests where id = p_send_request_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_req.state <> 'queued' then
    perform app.fail('SEND_NOT_CANCELLABLE', jsonb_build_object('state', v_req.state));
  end if;
  update app.send_requests set state = 'cancelled', updated_at = now() where id = v_req.id;
  update app.messages set delivery_state = 'cancelled' where id = v_req.message_id;
  perform app.audit(p_store_id, 'message.send_cancelled', 'send_request', v_req.id, null, '{}'::jsonb);
  return app.ok(jsonb_build_object('send_request_id', v_req.id, 'state', 'cancelled'));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('cancel_send', v_state, v_code);
end;
$$;

-- The seller decides what happens to an unknown outcome: mark it sent, or send again (a NEW,
-- explicit authorization of the same text). Nothing resends on its own.
create function api.resolve_unknown_send(p_store_id uuid, p_send_request_id uuid, p_resolution text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_req app.send_requests;
  v_conv app.conversations;
  v_text text;
  v_hash text;
  v_result jsonb;
  v_new jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'messages.send');
  if p_resolution not in ('mark_sent', 'send_again') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"resolution": "invalid"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'send_request_id', p_send_request_id,
                                                'resolution', p_resolution));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'resolve_unknown_send', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  select * into v_req from app.send_requests where id = p_send_request_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_req.state <> 'unknown' or v_req.resolution is not null then
    perform app.fail('SEND_NOT_UNKNOWN', jsonb_build_object('state', v_req.state));
  end if;
  if p_resolution = 'mark_sent' then
    update app.send_requests set state = 'sent', resolution = 'seller_marked_sent', resolved_by = v_uid, resolved_at = now(),
                                 updated_at = now()
     where id = v_req.id;
    update app.messages set delivery_state = 'sent' where id = v_req.message_id;
    v_new := jsonb_build_object('send_request_id', v_req.id, 'state', 'sent');
  else
    v_conv := app.lock_conversation(p_store_id, v_req.conversation_id);
    select body into v_text from app.messages where id = v_req.message_id;
    if v_text is null or app.sha256_hex(v_text) <> v_req.text_sha256 then
      perform app.fail('TEXT_INTEGRITY');
    end if;
    v_new := app.channel_authorize_send(p_store_id, v_uid, v_conv, v_text, null, v_req.kind, v_req.order_id, v_req.id);
    update app.send_requests set resolution = 'sent_again', resolved_by = v_uid, resolved_at = now(), updated_at = now()
     where id = v_req.id;
  end if;
  perform app.audit(p_store_id, 'message.send_resolved', 'send_request', v_req.id, null,
                    jsonb_build_object('resolution', p_resolution, 'new_send_request_id', v_new ->> 'send_request_id'));
  v_result := app.ok(v_new);
  perform app.idempotency_save(v_uid, p_idempotency_key, 'resolve_unknown_send', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('resolve_unknown_send', v_state, v_code);
end;
$$;

-- Connections the seller can see (never credentials or account ids).
create function api.list_connections(p_store_id uuid)
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
                                        'attention_reason', c.attention_reason, 'is_test', c.is_test,
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

-- ---------------------------------------------------------------------------------------------
-- Sender (role aisellia_channel_sender): claim, report, reconcile. It cannot create a send or
-- change its text; it receives the stored text and must attest the same SHA-256 on completion.
-- ---------------------------------------------------------------------------------------------
create function api.channel_claim_send(p_send_request_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_req app.send_requests;
  v_conn app.connections;
  v_provider app.providers;
  v_contact app.contacts;
  v_text text;
  v_cred text;
  v_code text;
  v_detail text;
  v_state text;
begin
  select * into v_req from app.send_requests where id = p_send_request_id for update;
  -- Only queued sends are claimable: `sending` and `unknown` never are (no blind resend).
  if not found or v_req.state <> 'queued' then
    perform app.fail('SEND_NOT_CLAIMABLE', jsonb_build_object('state', v_req.state));
  end if;
  if v_req.next_attempt_at is not null and v_req.next_attempt_at > now() then
    perform app.fail('SEND_NOT_CLAIMABLE', jsonb_build_object('reason', 'backoff', 'retry_at', v_req.next_attempt_at));
  end if;
  select * into v_conn from app.connections where id = v_req.connection_id;
  select * into v_provider from app.providers where id = v_conn.provider_id;
  if v_provider.status = 'suspended' then
    perform app.fail('SEND_NOT_CLAIMABLE', '{"reason": "provider_suspended"}');
  end if;
  if v_conn.state <> 'connected' or v_provider.status = 'planned'
     or (v_provider.status = 'in_development' and not v_conn.is_test) then
    update app.send_requests set state = 'failed', error_code = 'channel_unavailable', updated_at = now() where id = v_req.id;
    update app.messages set delivery_state = 'failed' where id = v_req.message_id;
    return app.err('SEND_NOT_CLAIMABLE', '{"reason": "channel_unavailable"}');
  end if;
  select body into v_text from app.messages where id = v_req.message_id;
  if v_text is null or app.sha256_hex(v_text) <> v_req.text_sha256 then
    update app.send_requests set state = 'failed', error_code = 'text_integrity', updated_at = now() where id = v_req.id;
    update app.messages set delivery_state = 'failed' where id = v_req.message_id;
    return app.err('TEXT_INTEGRITY', '{}'::jsonb);
  end if;
  select * into v_contact from app.contacts where id = v_req.contact_id;
  if v_conn.credential_ref is not null then
    select decrypted_secret into v_cred from vault.decrypted_secrets where id = v_conn.credential_ref;
  end if;
  update app.send_requests set state = 'sending', attempts = attempts + 1, next_attempt_at = null,
                               claim_expires_at = now() + make_interval(secs => app.ai_limit('channel_send_claim_seconds')),
                               updated_at = now()
   where id = v_req.id;
  update app.messages set delivery_state = 'sending' where id = v_req.message_id;
  return app.ok(jsonb_build_object(
    'send_request_id', v_req.id, 'provider', v_conn.provider_id, 'account_id', v_conn.external_account_id,
    'recipient', v_contact.external_user_id, 'text', v_text, 'text_sha256', v_req.text_sha256,
    'credential', v_cred, 'attempt', v_req.attempts + 1));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_claim_send', v_state, v_code);
end;
$$;

create function api.channel_complete_send(p_send_request_id uuid, p_provider_message_id text, p_text_sha256 text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_req app.send_requests;
  v_code text;
  v_detail text;
  v_state text;
begin
  if coalesce(p_provider_message_id, '') = '' or char_length(p_provider_message_id) > 200 then
    perform app.fail('VALIDATION_FAILED');
  end if;
  select * into v_req from app.send_requests where id = p_send_request_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_req.state = 'sent' and v_req.provider_message_id = p_provider_message_id then
    return app.ok(jsonb_build_object('send_request_id', v_req.id, 'state', 'sent', 'replayed', true));
  end if;
  if v_req.state <> 'sending' then
    perform app.fail('SEND_NOT_RUNNING', jsonb_build_object('state', v_req.state));
  end if;
  -- The sender attests the hash of what it submitted. A mismatch means something other than the
  -- authorized text may have gone out: never "sent", always surfaced to the seller.
  if p_text_sha256 is distinct from v_req.text_sha256 then
    update app.send_requests set state = 'unknown', error_code = 'text_integrity', claim_expires_at = null, updated_at = now()
     where id = v_req.id;
    update app.messages set delivery_state = 'unknown' where id = v_req.message_id;
    insert into app.audit_events (store_id, actor_user_id, action, entity_type, entity_id, before, after)
    values (v_req.store_id, null, 'message.send_result', 'send_request', v_req.id, null,
            jsonb_build_object('state', 'unknown', 'error_code', 'text_integrity', 'actor', 'system'));
    return app.err('TEXT_INTEGRITY', '{}'::jsonb);
  end if;
  update app.send_requests set state = 'sent', provider_message_id = p_provider_message_id, claim_expires_at = null,
                               error_code = null, updated_at = now()
   where id = v_req.id;
  update app.messages set delivery_state = case when delivery_state in ('delivered', 'read') then delivery_state else 'sent' end,
                          external_message_id = p_provider_message_id
   where id = v_req.message_id;
  update app.connections set last_send_ok_at = now() where id = v_req.connection_id;
  perform app.channel_apply_delivery(v_req.connection_id, p_provider_message_id);
  insert into app.audit_events (store_id, actor_user_id, action, entity_type, entity_id, before, after)
  values (v_req.store_id, null, 'message.send_result', 'send_request', v_req.id, null,
          jsonb_build_object('state', 'sent', 'provider_message_id', p_provider_message_id, 'attempt', v_req.attempts,
                             'actor', 'system'));
  return app.ok(jsonb_build_object('send_request_id', v_req.id, 'state', 'sent'));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when unique_violation then
    return app.err('VALIDATION_FAILED', '{"reason": "provider_message_id_in_use"}');
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_complete_send', v_state, v_code);
end;
$$;

-- outcome: retriable (nothing accepted; retried with backoff), permanent, unknown (may have been
-- accepted; never retried), integrity (the sender refused to submit: hash mismatch before sending).
create function api.channel_fail_send(p_send_request_id uuid, p_outcome text, p_code text, p_retry_after_ms integer)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_req app.send_requests;
  v_to text;
  v_err text := case when p_code ~ '^[a-z0-9_]{1,64}$' then p_code else 'other' end;
  v_code text;
  v_detail text;
  v_state text;
begin
  if p_outcome not in ('retriable', 'permanent', 'unknown', 'integrity') then
    perform app.fail('VALIDATION_FAILED');
  end if;
  select * into v_req from app.send_requests where id = p_send_request_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_req.state <> 'sending' then
    perform app.fail('SEND_NOT_RUNNING', jsonb_build_object('state', v_req.state));
  end if;
  v_to := case p_outcome
            when 'retriable' then case when v_req.attempts < app.ai_limit('channel_send_max_attempts') then 'queued' else 'failed' end
            when 'unknown' then 'unknown'
            else 'failed' end;
  if p_outcome = 'retriable' and v_to = 'failed' then
    v_err := 'provider_unavailable';
  elsif p_outcome = 'integrity' then
    v_err := 'text_integrity';
  end if;
  update app.send_requests
     set state = v_to, error_code = v_err, claim_expires_at = null, updated_at = now(),
         next_attempt_at = case when v_to = 'queued'
                                then now() + greatest(make_interval(secs => least(greatest(coalesce(p_retry_after_ms, 0), 0), 600000) / 1000.0),
                                                      (array['5 seconds', '30 seconds', '2 minutes']::interval[])[least(v_req.attempts, 3)])
                           end
   where id = v_req.id;
  update app.messages set delivery_state = v_to where id = v_req.message_id;
  insert into app.audit_events (store_id, actor_user_id, action, entity_type, entity_id, before, after)
  values (v_req.store_id, null, 'message.send_result', 'send_request', v_req.id, null,
          jsonb_build_object('state', v_to, 'error_code', v_err, 'attempt', v_req.attempts, 'actor', 'system'));
  return app.ok(jsonb_build_object('send_request_id', v_req.id, 'state', v_to));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_fail_send', v_state, v_code);
end;
$$;

create function api.channel_send_state(p_send_request_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_req app.send_requests;
begin
  select * into v_req from app.send_requests where id = p_send_request_id;
  if not found then
    return app.err('NOT_FOUND', '{}'::jsonb);
  end if;
  return app.ok(jsonb_build_object('send_request_id', v_req.id, 'state', v_req.state, 'attempts', v_req.attempts,
                                   'provider_message_id', v_req.provider_message_id));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- AI stays off for live conversations unless the store opts in (no API sets it in MC-2).
-- (api.request_ai_assist from 20261019090000_ai_guard_hardening with one added check.)
-- ---------------------------------------------------------------------------------------------
create or replace function api.request_ai_assist(p_store_id uuid, p_conversation_id uuid, p_mode text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_store app.stores;
  v_conv app.conversations;
  v_run app.ai_runs;
  v_count integer;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  if coalesce(p_mode, 'reply') not in ('reply', 'draft') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"mode": "invalid"}}');
  end if;
  if p_idempotency_key is null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"idempotency_key": "required"}}');
  end if;
  -- A retry with the same key gets the same run (Phase 3 §6.4: "a retry replays").
  select * into v_run from app.ai_runs where requested_by = v_uid and idempotency_key = p_idempotency_key;
  if found then
    if v_run.store_id <> p_store_id or v_run.conversation_id <> p_conversation_id or v_run.mode <> coalesce(p_mode, 'reply') then
      perform app.fail('IDEMPOTENCY_KEY_REUSED');
    end if;
    return app.ok(jsonb_build_object('run_id', v_run.id, 'status', v_run.status, 'replayed', true));
  end if;

  select * into v_store from app.stores where id = p_store_id for update;   -- serialises the quota per store
  if not v_store.ai_enabled or v_store.deletion_requested_at is not null then
    perform app.fail('AI_DISABLED');
  end if;
  v_conv := app.lock_conversation(p_store_id, p_conversation_id);
  -- Live customer conversations get no AI until the store explicitly opts in (Phase 9 condition 2).
  if v_conv.connection_id is not null and not v_store.ai_live_enabled then
    perform app.fail('AI_DISABLED', '{"reason": "live_not_enabled"}');
  end if;
  if v_conv.ai_paused then
    perform app.fail('AI_PAUSED');
  end if;
  if not exists (select 1 from app.messages where conversation_id = v_conv.id and direction = 'in' and body is not null) then
    perform app.fail('NOTHING_TO_ANSWER');
  end if;
  -- One run at a time per conversation; a stuck one expires.
  update app.ai_runs set status = 'expired', finished_at = now(), pii_map = null, error_code = 'stale'
   where conversation_id = v_conv.id and status in ('queued', 'running')
     and created_at < now() - make_interval(secs => app.ai_limit('assist_run_seconds'));
  select * into v_run from app.ai_runs where conversation_id = v_conv.id and status in ('queued', 'running') limit 1;
  if found then
    perform app.fail('AI_BUSY', jsonb_build_object('run_id', v_run.id));
  end if;
  select count(*) into v_count from app.ai_runs where store_id = p_store_id and created_at > now() - interval '10 minutes';
  if v_count >= app.ai_limit('assist_calls_per_store_per_10min') then
    perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'store_10min', 'retry_after_seconds', 600,
                                                        'limit', app.ai_limit('assist_calls_per_store_per_10min')));
  end if;
  select count(*) into v_count from app.ai_runs where store_id = p_store_id and created_at > now() - interval '24 hours';
  if v_count >= app.ai_limit('assist_calls_per_store_per_day') then
    perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'store_day', 'retry_after_seconds', 3600,
                                                        'limit', app.ai_limit('assist_calls_per_store_per_day')));
  end if;

  -- Spending brakes (estimated cost of the last 24 hours, from the server-side price table).
  if (select coalesce(sum(cost_micro_usd), 0) from app.ai_runs
       where store_id = p_store_id and created_at > now() - interval '24 hours')
     >= app.ai_limit('assist_daily_cost_micro_usd_per_store') then
    perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'budget_store', 'retry_after_seconds', 3600));
  end if;
  if (select coalesce(sum(cost_micro_usd), 0) from app.ai_runs where created_at > now() - interval '24 hours')
     >= app.ai_limit('assist_daily_cost_micro_usd_total') then
    perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'budget_total', 'retry_after_seconds', 3600));
  end if;

  insert into app.ai_runs (store_id, conversation_id, requested_by, idempotency_key, mode, input_message_ids, last_message_seq)
  values (p_store_id, v_conv.id, v_uid, p_idempotency_key, coalesce(p_mode, 'reply'),
          coalesce((select array_agg(id) from (select id from app.messages where conversation_id = v_conv.id
                                                order by seq desc limit app.ai_limit('assist_context_messages')) m), '{}'),
          (select max(seq) from app.messages where conversation_id = v_conv.id))
  returning * into v_run;
  return app.ok(jsonb_build_object('run_id', v_run.id, 'status', v_run.status, 'replayed', false));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when unique_violation then
    return app.err('AI_BUSY', '{}'::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('request_ai_assist', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Deletion paths cover the new tables.
-- (api.delete_conversation and internal.purge_due_account_deletions from 20261018100000_ai_assist,
-- with the channel rows added.)
-- ---------------------------------------------------------------------------------------------
create or replace function api.delete_conversation(p_store_id uuid, p_conversation_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_member app.store_members;
  v_conv app.conversations;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  v_member := app.require_permission(p_store_id, 'customers.delete');
  if v_member.role <> 'owner' then
    perform app.fail('FORBIDDEN');
  end if;
  v_conv := app.lock_conversation(p_store_id, p_conversation_id);
  if exists (select 1 from app.ai_runs where conversation_id = v_conv.id and status in ('queued', 'running')
               and created_at > now() - make_interval(secs => app.ai_limit('assist_run_seconds'))) then
    perform app.fail('AI_BUSY');
  end if;
  if exists (select 1 from app.send_requests where conversation_id = v_conv.id and state in ('queued', 'sending')) then
    perform app.fail('SEND_IN_PROGRESS');
  end if;
  update app.messages set suggestion_id = null where conversation_id = v_conv.id;
  delete from app.send_requests where conversation_id = v_conv.id;
  delete from app.message_attachments a using app.messages m where m.id = a.message_id and m.conversation_id = v_conv.id;
  delete from app.messages where conversation_id = v_conv.id;
  delete from app.reply_suggestions where conversation_id = v_conv.id;
  delete from app.ai_runs where conversation_id = v_conv.id;
  delete from app.conversations where id = v_conv.id;
  perform app.audit(p_store_id, 'conversation.delete', 'conversation', v_conv.id, null,
                    jsonb_build_object('order_id', v_conv.order_id));
  return app.ok(jsonb_build_object('id', v_conv.id, 'deleted', true));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('delete_conversation', v_state, v_code);
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
      delete from vault.secrets where id in (select credential_ref from app.connections
                                              where store_id = v_request.store_id and credential_ref is not null);
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

-- ---------------------------------------------------------------------------------------------
-- Retention: webhook payloads after 14 days (AD-06); the event rows stay without content.
-- ---------------------------------------------------------------------------------------------
create function internal.purge_webhook_payloads(p_older_than interval default interval '14 days')
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_run bigint;
  v_count integer;
  v_state text;
begin
  if p_older_than is null or p_older_than < interval '1 day' then
    insert into app.job_runs (job, finished_at, status, affected, details)
    values ('purge_webhook_payloads', clock_timestamp(), 'failed', 0, jsonb_build_object('reason', 'retention_too_short'));
    raise warning 'job purge_webhook_payloads refused: retention % is shorter than 1 day', p_older_than;
    return -1;
  end if;
  insert into app.job_runs (job) values ('purge_webhook_payloads') returning id into v_run;
  update app.webhook_events set payload = null, payload_purged_at = now()
   where payload is not null and received_at < now() - p_older_than and status in ('processed', 'ignored', 'failed');
  get diagnostics v_count = row_count;
  update app.job_runs set finished_at = clock_timestamp(), status = 'ok', affected = v_count,
                          details = jsonb_build_object('retention', p_older_than::text)
   where id = v_run;
  return v_count;
exception
  when others then
    get stacked diagnostics v_state = returned_sqlstate;
    insert into app.job_runs (job, finished_at, status, details)
    values ('purge_webhook_payloads', clock_timestamp(), 'failed', jsonb_build_object('sqlstate', v_state));
    raise warning 'job purge_webhook_payloads failed: sqlstate %', v_state;
    return -1;
end;
$$;

create or replace function internal.job_health()
returns table (job text, last_started_at timestamptz, last_status text, last_affected integer,
               last_ok_at timestamptz, stale boolean)
language sql stable security definer set search_path = ''
as $$
  select j.job, l.started_at, l.status, l.affected, ok.finished_at,
         ok.finished_at is null or ok.finished_at < now() - interval '36 hours' or l.status = 'failed'
    from (values ('purge_idempotency_keys'), ('purge_ai_request_log'), ('purge_ai_run_outputs'),
                 ('purge_message_bodies'), ('purge_webhook_payloads')) j(job)
    left join lateral (select * from app.job_runs r where r.job = j.job order by r.id desc limit 1) l on true
    left join lateral (select * from app.job_runs r where r.job = j.job and r.status = 'ok'
                        order by r.id desc limit 1) ok on true;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('aisellia-channel-process', '10 seconds', 'select internal.channel_process_batch()');
    perform cron.schedule('aisellia-channel-expire-claims', '* * * * *', 'select internal.channel_expire_send_claims()');
    perform cron.schedule('aisellia-purge-webhook-payloads', '47 3 * * *', 'select internal.purge_webhook_payloads()');
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------
revoke all on function
  app.provider_capability(text, text, boolean), app.sha256_hex(text), app.protect_sent_text(),
  app.channel_clean_name(text), app.channel_contact(app.connections, jsonb),
  app.channel_conversation(app.connections, app.contacts), app.channel_apply_delivery(uuid, text),
  app.channel_apply_item(app.webhook_events, jsonb),
  app.channel_authorize_send(uuid, uuid, app.conversations, text, uuid, text, uuid, uuid),
  internal.channel_process_batch(), internal.channel_replay(bigint[]), internal.channel_expire_send_claims(),
  internal.purge_webhook_payloads(interval),
  api.channel_ingest(text, text, text, jsonb, text),
  api.send_message(uuid, uuid, text, uuid, text, uuid, uuid), api.cancel_send(uuid, uuid),
  api.resolve_unknown_send(uuid, uuid, text, uuid), api.list_connections(uuid),
  api.channel_claim_send(uuid), api.channel_complete_send(uuid, text, text),
  api.channel_fail_send(uuid, text, text, integer), api.channel_send_state(uuid)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender;

grant execute on function api.channel_ingest(text, text, text, jsonb, text) to aisellia_channel_ingest;
grant execute on function api.channel_claim_send(uuid), api.channel_complete_send(uuid, text, text),
  api.channel_fail_send(uuid, text, text, integer), api.channel_send_state(uuid) to aisellia_channel_sender;
grant execute on function api.send_message(uuid, uuid, text, uuid, text, uuid, uuid), api.cancel_send(uuid, uuid),
  api.resolve_unknown_send(uuid, uuid, text, uuid), api.list_connections(uuid) to authenticated;
grant execute on function internal.channel_process_batch(), internal.channel_replay(bigint[]),
  internal.channel_expire_send_claims(), internal.purge_webhook_payloads(interval) to service_role;
