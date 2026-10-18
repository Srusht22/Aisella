-- Phase 9: hardening before any real webhook or WhatsApp customer data (security review O6, O2, O1).
-- Local only; nothing here is deployed.
--
-- O6  Cross-account ingest. Before: the ingest role stored NORMALISED events, so anyone holding its
--     database credential could inject messages or statuses for any provider account (the signature
--     was checked only in the Edge Function). Now the ingest role can only hand over the RAW body and
--     the signature headers: the database verifies the provider signature itself, with secrets that
--     only it can read (Vault), and normalises the body itself. A leaked ingest credential no longer
--     lets anyone forge an event; per-bot providers (Telegram, Viber) are verified against the secret
--     of the connection named in the URL, and every event is bound to that connection's account.
--     The previous api.channel_ingest becomes internal.channel_store_events (service role only).
-- O2  Phone numbers. Channel contacts keep the phone a provider identifies them by (WhatsApp), and
--     api.anonymize_customer now also anonymises those contacts, their messages, AI outputs and
--     stored webhook payloads. Anonymised contacts cannot be messaged.
-- O1  Echo matching. An unknown send is confirmed by an echo with the same text only when the
--     provider marks the echo as sent by our app (Meta: app_id); a seller typing the same text in the
--     native app no longer resolves it.

-- ---- Registry: how each provider authenticates and shapes its webhooks ---------------------------
alter table app.providers
  add column webhook_scheme text check (webhook_scheme in
    ('meta_sha256', 'telegram_token', 'viber_sha256', 'tiktok_sha256', 'stub_sha256')),
  add column payload_format text check (payload_format ~ '^[a-z][a-z0-9_]{1,40}$');
comment on column app.providers.webhook_scheme is
  'How the database verifies a webhook: meta_sha256 / stub_sha256 (HMAC of the raw body with the provider app secret), '
  'telegram_token (per-connection secret token header), viber_sha256 (HMAC with the connection''s bot token), '
  'tiktok_sha256 (HMAC of "t.body" with the client secret, 5-minute window).';

-- A second Vault secret per connection: the webhook secret a per-bot provider echoes back.
alter table app.connections add column webhook_secret_ref uuid;
alter table app.contacts add column anonymized_at timestamptz;

-- Rejected webhooks, counted per provider, reason and hour (no content, no addresses).
create table app.webhook_rejections (
  provider_id text not null references app.providers (id),
  reason      text not null check (char_length(reason) between 1 and 40),
  hour        timestamptz not null,
  count       integer not null default 0 check (count >= 0),
  primary key (provider_id, reason, hour)
);
alter table app.webhook_rejections enable row level security;
revoke all on app.webhook_rejections from public, anon, authenticated;

-- Provider-wide secrets live in Vault under aisellia/provider/<id>/<name> (app_secret, verify_token,
-- client_secret, app_id). Only SECURITY DEFINER functions owned by the database owner can read them.
create function app.provider_secret(p_provider text, p_name text)
returns text
language sql stable
as $$
  select decrypted_secret from vault.decrypted_secrets
   where name = 'aisellia/provider/' || p_provider || '/' || p_name
   order by created_at desc limit 1;
$$;

-- Equality that compares digests, so the time taken does not depend on where two values differ.
create function app.secure_equal(a text, b text)
returns boolean
language sql immutable
as $$
  select a is not null and b is not null
     and extensions.digest(convert_to(a, 'UTF8'), 'sha256') = extensions.digest(convert_to(b, 'UTF8'), 'sha256');
$$;

create function app.hmac_hex(p_data bytea, p_secret text)
returns text
language sql immutable
as $$ select encode(extensions.hmac(p_data, convert_to(p_secret, 'UTF8'), 'sha256'), 'hex') $$;

-- Null when the raw body is authentic, else a short reason. Never logs or returns secrets.
create function app.channel_verify(p_provider app.providers, p_conn app.connections, p_raw bytea, p_headers jsonb)
returns text
language plpgsql
as $$
declare
  v_secret text;
  v_sig text;
  v_t text;
  v_s text;
begin
  case p_provider.webhook_scheme
    when 'meta_sha256', 'stub_sha256' then
      v_secret := app.provider_secret(p_provider.id, 'app_secret');
      v_sig := p_headers ->> case p_provider.webhook_scheme when 'meta_sha256' then 'x-hub-signature-256'
                                                                    else 'x-stub-signature' end;
      if v_secret is null then return 'not_configured'; end if;
      if v_sig is null then return 'missing_signature'; end if;
      return case when app.secure_equal(v_sig, 'sha256=' || app.hmac_hex(p_raw, v_secret)) then null else 'bad_signature' end;
    when 'telegram_token' then
      select decrypted_secret into v_secret from vault.decrypted_secrets where id = p_conn.webhook_secret_ref;
      v_sig := p_headers ->> 'x-telegram-bot-api-secret-token';
      if v_secret is null then return 'not_configured'; end if;
      if v_sig is null then return 'missing_signature'; end if;
      return case when app.secure_equal(v_sig, v_secret) then null else 'bad_signature' end;
    when 'viber_sha256' then
      select decrypted_secret into v_secret from vault.decrypted_secrets where id = p_conn.credential_ref;
      v_sig := p_headers ->> 'x-viber-content-signature';
      if v_secret is null then return 'not_configured'; end if;
      if v_sig is null then return 'missing_signature'; end if;
      return case when app.secure_equal(lower(v_sig), app.hmac_hex(p_raw, v_secret)) then null else 'bad_signature' end;
    when 'tiktok_sha256' then
      v_secret := app.provider_secret(p_provider.id, 'client_secret');
      v_sig := p_headers ->> 'tiktok-signature';
      if v_secret is null then return 'not_configured'; end if;
      v_t := substring(v_sig from '(?:^|,)t=([0-9]{1,12})(?:,|$)');
      v_s := substring(v_sig from '(?:^|,)s=([0-9a-f]{64})(?:,|$)');
      if v_t is null or v_s is null then return 'missing_signature'; end if;
      if abs(extract(epoch from now()) - v_t::bigint) > 300 then return 'stale_signature'; end if;
      return case when app.secure_equal(v_s, app.hmac_hex(convert_to(v_t || '.', 'UTF8') || p_raw, v_secret))
                  then null else 'bad_signature' end;
    else
      return 'not_configured';
  end case;
end;
$$;

-- The fixture-only stub's body: {"event_id": …, "entries": [{type, account, from|to, id, at, text, name, …}]}.
create function app.channel_normalize_aisellia_stub(p_provider app.providers, p_conn app.connections, p_body jsonb)
returns jsonb
language sql stable
as $$
  select jsonb_build_object('event_id', p_body ->> 'event_id', 'events', coalesce(jsonb_agg(
    case when coalesce(e ->> 'type', 'message') in ('message', 'echo') then jsonb_strip_nulls(jsonb_build_object(
           'kind', coalesce(e ->> 'type', 'message'), 'account_id', e ->> 'account',
           'external_user_id', case when e ->> 'type' = 'echo' then e ->> 'to' else e ->> 'from' end,
           'external_message_id', e ->> 'id', 'occurred_at', coalesce(e ->> 'at', now()::text),
           'text', e -> 'text', 'display_name', e -> 'name', 'phone', e -> 'phone',
           'attachments', e -> 'attachments', 'sent_by_app', e -> 'sent_by_app'))
         else jsonb_build_object('kind', e ->> 'type', 'account_id', e ->> 'account', 'provider_message_id', e ->> 'id',
                                 'provider_event_key', (e ->> 'type') || ':' || (e ->> 'id')) end
    order by o), '[]'::jsonb))
    from jsonb_array_elements(case when jsonb_typeof(p_body -> 'entries') = 'array' then p_body -> 'entries' else '[]' end)
         with ordinality x(e, o);
$$;

-- ---- Storage step (was api.channel_ingest) ----------------------------------------------------
drop function api.channel_ingest(text, text, text, jsonb, text);
-- Stores normalised events (after verification by api.channel_ingest_raw; operators and tests).
create function internal.channel_store_events(p_provider text, p_external_event_id text, p_connection_hint text,
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
     or jsonb_typeof(p_events) is distinct from 'array' or jsonb_array_length(p_events) not between 1 and 1000
     or octet_length(p_events::text) > 1048576 then
    perform app.fail('VALIDATION_FAILED');
  end if;
  insert into app.webhook_events (provider_id, external_event_id, connection_hint, account_key, raw_sha256, payload)
  values (p_provider, p_external_event_id, p_connection_hint, left(p_events -> 0 ->> 'account_id', 200), p_raw_sha256, p_events)
  on conflict (provider_id, (coalesce(account_key, '')), external_event_id) do nothing
  returning id into v_id;
  return app.ok(jsonb_build_object('stored', v_id is not null, 'duplicate', v_id is null));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_store_events', v_state, v_code);
end;
$$;

-- ---- Raw ingest: the ONLY function of the ingest role --------------------------------------------
create function api.channel_ingest_raw(p_provider text, p_connection_hint text, p_raw bytea, p_headers jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_provider app.providers;
  v_conn app.connections;
  v_reason text;
  v_body jsonb;
  v_norm jsonb;
  v_events jsonb;
  v_sha text;
  v_code text;
  v_detail text;
  v_state text;
begin
  select * into v_provider from app.providers where id = p_provider;
  if not found or v_provider.status = 'planned' or v_provider.webhook_scheme is null or v_provider.payload_format is null then
    perform app.fail('UNKNOWN_PROVIDER');
  end if;
  if p_raw is null or octet_length(p_raw) not between 2 and 262144
     or jsonb_typeof(p_headers) is distinct from 'object'
     or (select count(*) from jsonb_object_keys(p_headers)) > 20
     or (p_connection_hint is not null and p_connection_hint !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    perform app.fail('VALIDATION_FAILED');
  end if;
  -- Per-bot providers: the URL names the connection; its own secret decides.
  if v_provider.webhook_scheme in ('telegram_token', 'viber_sha256') then
    select * into v_conn from app.connections
     where id = p_connection_hint::uuid and provider_id = v_provider.id and state <> 'disconnected';
    v_reason := case when v_conn.id is null then 'unknown_connection' end;
  end if;
  v_reason := coalesce(v_reason, app.channel_verify(v_provider, v_conn, p_raw, p_headers));
  if v_reason is not null then
    insert into app.webhook_rejections (provider_id, reason, hour, count)
    values (v_provider.id, v_reason, date_trunc('hour', now()), 1)
    on conflict (provider_id, reason, hour) do update set count = app.webhook_rejections.count + 1;
    -- One answer for every authenticity failure (no oracle); a missing secret is our fault (retry).
    return app.err(case when v_reason = 'not_configured' then 'NOT_CONFIGURED' else 'SIGNATURE_INVALID' end, '{}');
  end if;
  begin
    v_body := convert_from(p_raw, 'UTF8')::jsonb;
  exception when others then
    perform app.fail('VALIDATION_FAILED');
  end;
  v_sha := encode(extensions.digest(p_raw, 'sha256'), 'hex');
  execute format('select app.%I($1, $2, $3)', 'channel_normalize_' || v_provider.payload_format)
    into v_norm using v_provider, v_conn, v_body;
  v_events := coalesce(v_norm -> 'events', '[]');
  if v_conn.id is not null then
    -- Bound to the verified connection: the payload cannot name another account.
    select coalesce(jsonb_agg(e || jsonb_build_object('account_id', v_conn.external_account_id) order by o), '[]')
      into v_events from jsonb_array_elements(v_events) with ordinality x(e, o);
  end if;
  if jsonb_array_length(v_events) = 0 then
    return app.ok(jsonb_build_object('stored', false, 'duplicate', false, 'items', 0));
  end if;
  return internal.channel_store_events(v_provider.id, coalesce(v_norm ->> 'event_id', v_sha), v_conn.id::text, v_events, v_sha);
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_ingest_raw', v_state, v_code);
end;
$$;

-- Meta's subscription handshake (GET hub.verify_token): true only for the provider's own token.
create function api.channel_webhook_challenge(p_provider text, p_verify_token text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if app.secure_equal(p_verify_token, app.provider_secret(p_provider, 'verify_token'))
     and exists (select 1 from app.providers where id = p_provider and status <> 'planned') then
    return app.ok('{}');
  end if;
  return app.err('SIGNATURE_INVALID', '{}');
end;
$$;

-- ---- O2: phone numbers -------------------------------------------------------------------------
create or replace function app.channel_contact(p_conn app.connections, p_item jsonb)
returns app.contacts
language plpgsql
as $$
declare
  v_contact app.contacts;
begin
  if coalesce(p_item ->> 'external_user_id', '') = '' then
    raise exception 'missing external_user_id' using errcode = '22023';
  end if;
  -- The phone is kept only when the provider identifies the user by it (WhatsApp), in E.164 form,
  -- so api.anonymize_customer can find the contact.
  insert into app.contacts (store_id, connection_id, external_user_id, display_name, phone)
  values (p_conn.store_id, p_conn.id, left(p_item ->> 'external_user_id', 200), app.channel_clean_name(p_item ->> 'display_name'),
          case when p_item ->> 'phone' ~ '^\+[1-9][0-9]{7,14}$'
               then coalesce(app.normalize_phone(p_item ->> 'phone'), p_item ->> 'phone') end)
  on conflict (connection_id, external_user_id)
  do update set display_name = coalesce(excluded.display_name, app.contacts.display_name),
                phone = coalesce(excluded.phone, app.contacts.phone)
  returning * into v_contact;
  return v_contact;
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
                        and e.note <> app.redact_contact_text(e.note, null, array[v_phone])));
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

create or replace function app.channel_authorize_send(p_store_id uuid, p_uid uuid, p_conv app.conversations, p_text text,
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
  if v_contact.anonymized_at is not null then
    perform app.fail('CONTACT_ANONYMIZED');
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
    -- The text must be exactly the server's rendering of the order as it is now, in one of the
    -- supported languages: a confirmation can never carry other amounts, items or promises.
    if not exists (select 1 from unnest(array['en', 'ckb', 'ar']) l where app.order_confirmation_text(v_order, l) = p_text) then
      perform app.fail('CONFIRMATION_TEXT_MISMATCH');
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

-- ---- O1: echo matching ------------------------------------------------------------------------
create or replace function app.channel_apply_item(p_event app.webhook_events, p_item jsonb)
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
    -- Text matching only for echoes the provider marks as sent by our app: a seller typing the
    -- same words in the native app must not resolve an unknown send (review O1).
    if not found and p_item ? 'text' and coalesce(p_item ->> 'sent_by_app', 'false') = 'true' then
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

revoke all on function api.channel_ingest_raw(text, text, bytea, jsonb), api.channel_webhook_challenge(text, text),
  internal.channel_store_events(text, text, text, jsonb, text), app.provider_secret(text, text),
  app.secure_equal(text, text), app.hmac_hex(bytea, text),
  app.channel_verify(app.providers, app.connections, bytea, jsonb),
  app.channel_normalize_aisellia_stub(app.providers, app.connections, jsonb)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender;
grant execute on function api.channel_ingest_raw(text, text, bytea, jsonb), api.channel_webhook_challenge(text, text)
  to aisellia_channel_ingest;
grant execute on function internal.channel_store_events(text, text, text, jsonb, text) to service_role;
