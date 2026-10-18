-- Phase 9: hardening before real webhooks and WhatsApp customer data (security review O6, O2, O1).
--   O6 the ingest role hands in RAW bodies; the database verifies the signature with secrets only it
--      can read and normalises the body itself; per-bot webhooks are bound to their connection.
--   O2 api.anonymize_customer reaches channel contacts identified by the phone number.
--   O1 an unknown send is confirmed by text only from an echo the provider marks as sent by our app.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(42);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;
grant usage on schema extensions to aisellia_channel_ingest, aisellia_channel_sender;   -- pgTAP; rolled back
grant aisellia_channel_ingest, aisellia_channel_sender to postgres with set true, inherit false;  -- rolled back

-- The ingest role hands in raw bytes and the request's headers, nothing else.
create function pg_temp.raw_ingest(p_provider text, p_hint uuid, p_raw bytea, p_headers jsonb) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  set local role aisellia_channel_ingest;
  v := api.channel_ingest_raw(p_provider, p_hint::text, p_raw, p_headers);
  perform pg_temp.act_as_admin();
  return v;
end $$;
create function pg_temp.body(p_event text, p_entries jsonb) returns bytea language sql as $$
  select convert_to(jsonb_build_object('event_id', p_event, 'entries', p_entries)::text, 'UTF8')
$$;
create function pg_temp.sig(p_raw bytea, p_secret text) returns jsonb language sql as $$
  select jsonb_build_object('x-stub-signature', 'sha256=' || app.hmac_hex(p_raw, p_secret))
$$;
create function pg_temp.process() returns integer language plpgsql as $$
begin perform pg_temp.act_as_admin(); return internal.channel_process_batch(); end $$;
create function pg_temp.msgs(p_conn uuid) returns integer language sql as $$
  select count(*)::integer from app.messages where connection_id = p_conn
$$;

-- Fixtures: two stores; fixture providers using each authenticity scheme (stub body format).
insert into ids values ('a', pg_temp.new_user('ing-a@example.test')), ('b', pg_temp.new_user('ing-b@example.test'));
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Shop B', '+9647701234567', 'IQD', 'en', 'Duhok', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as_admin();
insert into app.providers (id, display_name, status, webhook_scheme, payload_format) values
  ('fx_app', 'App-signed fixture', 'in_development', 'stub_sha256', 'aisellia_stub'),
  ('fx_meta', 'Meta-scheme fixture', 'in_development', 'meta_sha256', 'aisellia_stub'),
  ('fx_bot', 'Per-bot token fixture', 'in_development', 'telegram_token', 'aisellia_stub'),
  ('fx_viber', 'Per-bot HMAC fixture', 'in_development', 'viber_sha256', 'aisellia_stub'),
  ('fx_tt', 'Timestamped fixture', 'in_development', 'tiktok_sha256', 'aisellia_stub'),
  ('fx_none', 'No secret configured', 'in_development', 'stub_sha256', 'aisellia_stub');
insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on)
select p, c, v::jsonb, 'verified', 'https://stub.invalid/docs', current_date
  from unnest(array['fx_app', 'fx_bot']) p, (values ('outbound_text', 'true'), ('reply_window_hours', '24')) x(c, v);
select vault.create_secret('app-secret-0123456789', 'aisellia/provider/fx_app/app_secret');
select vault.create_secret('meta-secret-0123456789', 'aisellia/provider/fx_meta/app_secret');
select vault.create_secret('verify-token-0123456789', 'aisellia/provider/fx_meta/verify_token');
select vault.create_secret('tiktok-secret-0123456789', 'aisellia/provider/fx_tt/client_secret');
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at)
           values (pg_temp.id('store_a'), 'fx_app', 'acct-A', 'connected', true, now()) returning id)
insert into ids select 'app_a', id from x;
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at)
           values (pg_temp.id('store_b'), 'fx_app', 'acct-B', 'connected', true, now()) returning id)
insert into ids select 'app_b', id from x;
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at, webhook_secret_ref)
           values (pg_temp.id('store_a'), 'fx_bot', 'bot-A', 'connected', true, now(), vault.create_secret('tg-secret-A-0123456789')) returning id)
insert into ids select 'bot_a', id from x;
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at, webhook_secret_ref)
           values (pg_temp.id('store_b'), 'fx_bot', 'bot-B', 'connected', true, now(), vault.create_secret('tg-secret-B-0123456789')) returning id)
insert into ids select 'bot_b', id from x;
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at, credential_ref)
           values (pg_temp.id('store_a'), 'fx_viber', 'viber-A', 'connected', true, now(), vault.create_secret('viber-token-A-0123456789')) returning id)
insert into ids select 'viber_a', id from x;

-- ---- O6: the ingest role cannot store normalised events ------------------------------------------------------
set local role aisellia_channel_ingest;
select throws_ok($$ select internal.channel_store_events('fx_app', 'e', null, '[{"kind": "message"}]', repeat('0', 64)) $$,
                 '42501', null, 'the ingest role cannot store normalised (unverified) events');
select pg_temp.act_as_admin();

-- App-wide HMAC scheme.
insert into res select 'raw1', to_jsonb(encode(pg_temp.body('ev-1', '[{"account": "acct-A", "from": "cust-1", "id": "m-1", "text": "سڵاو، ئەم کراسە چەندە؟", "name": "Shno"}]'), 'base64'));
create function pg_temp.raw(p text) returns bytea language sql as $$ select decode(pg_temp.r(p) #>> '{}', 'base64') $$;
select is(pg_temp.raw_ingest('fx_app', null, pg_temp.raw('raw1'), '{}') #>> '{error,code}', 'SIGNATURE_INVALID',
          'an unsigned body is refused');
select is(pg_temp.raw_ingest('fx_app', null, pg_temp.raw('raw1'), pg_temp.sig(pg_temp.raw('raw1'), 'wrong-secret-0123456789')) #>> '{error,code}',
          'SIGNATURE_INVALID', 'a body signed with another secret is refused');
select is(pg_temp.raw_ingest('fx_app', null, overlay(pg_temp.raw('raw1') placing '\x58'::bytea from 20 for 1),
                             pg_temp.sig(pg_temp.raw('raw1'), 'app-secret-0123456789')) #>> '{error,code}',
          'SIGNATURE_INVALID', 'a single changed byte is refused');
select is(pg_temp.raw_ingest('fx_app', null, convert_to(convert_from(pg_temp.raw('raw1'), 'UTF8')::jsonb::text || ' ', 'UTF8'),
                             pg_temp.sig(pg_temp.raw('raw1'), 'app-secret-0123456789')) #>> '{error,code}',
          'SIGNATURE_INVALID', 'verification is on the raw bytes: a re-serialised body does not verify');
select is((select count(*)::integer from app.webhook_events where provider_id = 'fx_app'), 0, 'nothing refused was stored');
select is((select sum(count)::integer from app.webhook_rejections where provider_id = 'fx_app'), 4,
          'refusals are counted per provider and reason (no content)');
select is(pg_temp.raw_ingest('fx_app', null, pg_temp.raw('raw1'), pg_temp.sig(pg_temp.raw('raw1'), 'app-secret-0123456789')) #>> '{data,stored}',
          'true', 'a correctly signed body is accepted');
select is(pg_temp.raw_ingest('fx_app', null, pg_temp.raw('raw1'), pg_temp.sig(pg_temp.raw('raw1'), 'app-secret-0123456789')) #>> '{data,duplicate}',
          'true', 'a redelivery is a duplicate');
select is((select payload -> 0 ->> 'external_user_id' from app.webhook_events where provider_id = 'fx_app'), 'cust-1',
          'the database normalised the body itself');
select pg_temp.process();
select is((select convert_to(body, 'UTF8') from app.messages where connection_id = pg_temp.id('app_a')),
          convert_to('سڵاو، ئەم کراسە چەندە؟', 'UTF8'), 'the Sorani text is stored byte for byte');
select is(pg_temp.raw_ingest('fx_app', null, '\xfffe7b7d'::bytea,
                             pg_temp.sig('\xfffe7b7d'::bytea, 'app-secret-0123456789')) #>> '{error,code}',
          'VALIDATION_FAILED', 'a signed body that is not UTF-8 JSON is refused');
select is(pg_temp.raw_ingest('fx_none', null, pg_temp.raw('raw1'), pg_temp.sig(pg_temp.raw('raw1'), 'anything-0123456789')) #>> '{error,code}',
          'NOT_CONFIGURED', 'without a configured secret nothing is accepted (and the platform retries later)');
select is(pg_temp.raw_ingest('instagram', null, pg_temp.raw('raw1'), '{}') #>> '{error,code}', 'UNKNOWN_PROVIDER',
          'a planned provider accepts nothing');

-- Meta scheme and its subscription handshake.
insert into res select 'raw_meta', to_jsonb(encode(pg_temp.body('ev-m', '[{"account": "acct-A", "from": "cust-2", "id": "m-meta", "text": "hi"}]'), 'base64'));
select is(pg_temp.raw_ingest('fx_meta', null, pg_temp.raw('raw_meta'),
            jsonb_build_object('x-hub-signature-256', 'sha256=' || app.hmac_hex(pg_temp.raw('raw_meta'), 'meta-secret-0123456789'))) ->> 'ok',
          'true', 'the Meta scheme verifies X-Hub-Signature-256 over the raw body');
select is(pg_temp.raw_ingest('fx_meta', null, pg_temp.raw('raw_meta'),
            jsonb_build_object('x-hub-signature-256', 'sha256=' || app.hmac_hex(pg_temp.raw('raw_meta'), 'app-secret-0123456789'))) #>> '{error,code}',
          'SIGNATURE_INVALID', '… and refuses another provider''s secret');
set local role aisellia_channel_ingest;
select is(api.channel_webhook_challenge('fx_meta', 'verify-token-0123456789') ->> 'ok', 'true', 'the handshake accepts the configured verify token');
select is(api.channel_webhook_challenge('fx_meta', 'guess') ->> 'ok', 'false', '… and nothing else');
select is(api.channel_webhook_challenge('fx_app', null) ->> 'ok', 'false', '… nor a provider without a token');
select pg_temp.act_as_admin();

-- ---- O6: per-bot webhooks are bound to the connection named in the URL ----------------------------------------
insert into res select 'raw_bot', to_jsonb(encode(pg_temp.body('update-7',
  '[{"account": "bot-B", "from": "cust-x", "id": "chat-x:1", "text": "forged into B?"}]'), 'base64'));
select is(pg_temp.raw_ingest('fx_bot', pg_temp.id('bot_b'), pg_temp.raw('raw_bot'),
                             '{"x-telegram-bot-api-secret-token": "tg-secret-A-0123456789"}') #>> '{error,code}',
          'SIGNATURE_INVALID', 'bot A''s secret cannot deliver into bot B''s connection');
select is(pg_temp.raw_ingest('fx_bot', null, pg_temp.raw('raw_bot'),
                             '{"x-telegram-bot-api-secret-token": "tg-secret-B-0123456789"}') #>> '{error,code}',
          'SIGNATURE_INVALID', 'without the connection in the URL nothing is accepted');
select is(pg_temp.raw_ingest('fx_bot', pg_temp.id('bot_a'), pg_temp.raw('raw_bot'),
                             '{"x-telegram-bot-api-secret-token": "tg-secret-A-0123456789"}') #>> '{data,stored}',
          'true', 'bot A''s own secret on bot A''s URL is accepted');
select pg_temp.process();
select is(array[pg_temp.msgs(pg_temp.id('bot_a')), pg_temp.msgs(pg_temp.id('bot_b'))], array[1, 0],
          'a body naming bot B''s account is bound to bot A: it lands in store A, never in B');
select is(pg_temp.raw_ingest('fx_bot', pg_temp.id('bot_b'), pg_temp.body('update-7', '[{"account": "bot-B", "from": "u", "id": "c:2", "text": "x"}]'),
                             '{"x-telegram-bot-api-secret-token": "tg-secret-B-0123456789"}') #>> '{data,stored}', 'true',
          'the same update id from another bot is a different event (ids are per account)');
insert into res select 'raw_viber', to_jsonb(encode(pg_temp.body('vb-1', '[{"account": "x", "from": "vu-1", "id": "tok-1", "text": "salam"}]'), 'base64'));
select is(pg_temp.raw_ingest('fx_viber', pg_temp.id('viber_a'), pg_temp.raw('raw_viber'),
            jsonb_build_object('x-viber-content-signature', app.hmac_hex(pg_temp.raw('raw_viber'), 'viber-token-A-0123456789'))) #>> '{data,stored}',
          'true', 'the per-bot HMAC scheme verifies with the connection''s own token');
select is(pg_temp.raw_ingest('fx_viber', pg_temp.id('viber_a'), pg_temp.raw('raw_viber'),
            jsonb_build_object('x-viber-content-signature', app.hmac_hex(pg_temp.raw('raw_viber'), 'viber-token-B-0123456789'))) #>> '{error,code}',
          'SIGNATURE_INVALID', '… and refuses any other token');

-- Timestamped scheme: the signed timestamp must be recent.
create function pg_temp.tt(p_raw bytea, p_at bigint) returns jsonb language sql as $$
  select jsonb_build_object('tiktok-signature', 't=' || p_at || ',s=' || app.hmac_hex(convert_to(p_at || '.', 'UTF8') || p_raw, 'tiktok-secret-0123456789'))
$$;
select is(pg_temp.raw_ingest('fx_tt', null, pg_temp.raw('raw_meta'), pg_temp.tt(pg_temp.raw('raw_meta'), extract(epoch from now())::bigint)) ->> 'ok',
          'true', 'a fresh timestamped signature is accepted');
select is(pg_temp.raw_ingest('fx_tt', null, pg_temp.raw('raw_meta'), pg_temp.tt(pg_temp.raw('raw_meta'), extract(epoch from now())::bigint - 3600)) #>> '{error,code}',
          'SIGNATURE_INVALID', 'a replayed signature older than five minutes is refused');

-- ---- O1: echo matching ------------------------------------------------------------------------------------------
insert into ids select 'conv_a', id from app.conversations where connection_id = pg_temp.id('app_a');
create function pg_temp.unknown_send(p_text text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.act_as(pg_temp.id('a'));
  v := (api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), p_text, null, null, null, gen_random_uuid()) #>> '{data,send_request_id}')::uuid;
  perform pg_temp.act_as_admin();
  update app.send_requests set state = 'unknown' where id = v;
  return v;
end $$;
insert into ids select 'u1', pg_temp.unknown_send('Your parcel leaves today');
select pg_temp.raw_ingest('fx_app', null, pg_temp.body('ev-e1', '[{"type": "echo", "account": "acct-A", "to": "cust-1", "id": "pm-native", "text": "Your parcel leaves today"}]'),
                          pg_temp.sig(pg_temp.body('ev-e1', '[{"type": "echo", "account": "acct-A", "to": "cust-1", "id": "pm-native", "text": "Your parcel leaves today"}]'), 'app-secret-0123456789'));
select pg_temp.process();
select is((select state from app.send_requests where id = pg_temp.id('u1')), 'unknown',
          'the same words typed in the native app do not resolve an unknown send');
select is((select origin from app.messages where external_message_id = 'pm-native'), 'seller_external',
          '… they are recorded as written outside Aisellia');
select pg_temp.raw_ingest('fx_app', null, pg_temp.body('ev-e2', '[{"type": "echo", "account": "acct-A", "to": "cust-1", "id": "pm-ours", "text": "Your parcel leaves today", "sent_by_app": true}]'),
                          pg_temp.sig(pg_temp.body('ev-e2', '[{"type": "echo", "account": "acct-A", "to": "cust-1", "id": "pm-ours", "text": "Your parcel leaves today", "sent_by_app": true}]'), 'app-secret-0123456789'));
select pg_temp.process();
select is((select state || ':' || resolution from app.send_requests where id = pg_temp.id('u1')), 'sent:evidence',
          'an echo the provider marks as sent by our app resolves it');

-- ---- O2: phone numbers -------------------------------------------------------------------------------------------
create function pg_temp.wa(p_conn text, p_event text, p_user text, p_phone text, p_mid text, p_text text) returns jsonb language plpgsql as $$
declare v_raw bytea;
begin
  v_raw := pg_temp.body(p_event, jsonb_build_array(jsonb_build_object('account', p_conn, 'from', p_user, 'phone', p_phone, 'id', p_mid,
                                                                      'text', p_text, 'name', 'Shno Ali')));
  return pg_temp.raw_ingest('fx_app', null, v_raw, pg_temp.sig(v_raw, 'app-secret-0123456789'));
end $$;
select pg_temp.wa('acct-A', 'wa-1', '9647501112233', '+9647501112233', 'wm-1', 'My number is 0750 111 2233, send it to Ankawa');
select pg_temp.wa('acct-A', 'wa-2', '9647709998877', '+9647709998877', 'wm-2', 'Another customer');
select pg_temp.wa('acct-B', 'wa-3', '9647501112233', '+9647501112233', 'wm-3', 'Same person, other shop');
select pg_temp.process();
select is((select phone from app.contacts where external_user_id = '9647501112233' and connection_id = pg_temp.id('app_a')), '+9647501112233',
          'a contact identified by phone keeps it in E.164 form');
insert into ids select 'busy', pg_temp.unknown_send('placeholder');
update app.send_requests set state = 'failed' where id = pg_temp.id('busy');
insert into ids select 'conv_wa', c.id from app.conversations c join app.contacts k on k.id = c.contact_id
 where k.external_user_id = '9647709998877';
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'q', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_wa'), 'still queued', null, null, null, gen_random_uuid());
insert into res select 'anon', api.anonymize_customer(pg_temp.id('store_a'), '+9647501112233', gen_random_uuid());
select is(pg_temp.r('anon') #>> '{data,contacts_anonymized}', '1', 'anonymising a number reaches the channel contact with that number');
select pg_temp.act_as_admin();
select is((select row(phone, display_name, external_user_id like 'anon:%', anonymized_at is not null)::text from app.contacts k
            join app.conversations c on c.contact_id = k.id where c.connection_id = pg_temp.id('app_a') and k.anonymized_at is not null),
          row(null::text, null::text, true, true)::text, 'the contact keeps no number, name or provider id');
select ok(not exists (select 1 from app.messages m join app.contacts k on k.id = (select contact_id from app.conversations where id = m.conversation_id)
                       where k.anonymized_at is not null and m.body is not null), 'its messages'' text is purged');
select ok(not exists (select 1 from app.webhook_events where provider_id = 'fx_app' and external_event_id = 'wa-1' and payload is not null),
          'the stored webhook payload about it is purged');
select is((select count(*)::integer from app.contacts where phone = '+9647501112233'), 1,
          'another store''s contact with the same number is untouched (tenant isolation)');
select is((select count(*)::integer from app.contacts where external_user_id = '9647709998877' and anonymized_at is null), 1,
          'other customers are untouched');
insert into ids select 'conv_anon', c.id from app.conversations c join app.contacts k on k.id = c.contact_id
 where k.anonymized_at is not null and c.store_id = pg_temp.id('store_a');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_anon'),
                           'hello again', null, null, null, gen_random_uuid()) #>> '{error,code}',
          'CONTACT_ANONYMIZED', 'an anonymised contact cannot be messaged');
select is(api.anonymize_customer(pg_temp.id('store_a'), '+9647709998877', gen_random_uuid()) #>> '{data,contacts_skipped_in_progress}', '1',
          'a contact with a send in flight is skipped, like an order still being handled');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.contacts where external_user_id = '9647709998877' and anonymized_at is null), 1, '… and kept');
select ok(not exists (select 1 from app.audit_events where action = 'customer.anonymize'
                       and (coalesce(before::text, '') || coalesce(after::text, '')) ~ '(750111|1112233|Shno)'),
          'the audit of the anonymisation holds counts, not the number or the name');

select * from finish();
rollback;
