-- Phase 9 MC-2: the provider-neutral channel foundation. A fixture-only `stub` provider (created in
-- this transaction, rolled back) plays a real one; no real provider is involved.
-- Covers: registry and capability rule, ingestion and both deduplication levels, forged routing,
-- tenant isolation, backoff / failure / replay, fair claiming, seller-only exact-text sending,
-- the sender's claim / complete / fail rules, unknown outcomes, delivery states, the AI gate,
-- retention and deletion.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(93);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;
grant usage on schema extensions to aisellia_channel_ingest, aisellia_channel_sender, aisellia_ai_worker, aisellia_ai;   -- pgTAP; rolled back
grant aisellia_channel_ingest, aisellia_channel_sender, aisellia_ai_worker to postgres with set true, inherit false;  -- rolled back
create function pg_temp.act_as_role(p_role text) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  execute format('set local role %I', p_role);
end $$;
create function pg_temp.ingest(p_provider text, p_event text, p_hint text, p_events jsonb) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as_role('aisellia_channel_ingest');
  v := api.channel_ingest(p_provider, p_event, p_hint, p_events, encode(sha256(convert_to(p_events::text, 'UTF8')), 'hex'));
  perform pg_temp.act_as_admin();
  return v;
end $$;
create function pg_temp.process() returns integer language plpgsql as $$
begin
  perform pg_temp.act_as_admin();
  return internal.channel_process_batch();
end $$;
create function pg_temp.msg(p_account text, p_user text, p_mid text, p_text text, p_extra jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_array(jsonb_build_object('kind', 'message', 'account_id', p_account, 'external_user_id', p_user,
                                              'external_message_id', p_mid, 'occurred_at', now(), 'text', p_text) || p_extra)
$$;
create function pg_temp.event(p_ext text) returns jsonb language sql security definer as $$
  select to_jsonb(e) - 'payload' from app.webhook_events e where external_event_id = p_ext
$$;
create function pg_temp.sender(p_fn text, p_args text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as_role('aisellia_channel_sender');
  execute format('select api.%I(%s)', p_fn, p_args) into v;
  perform pg_temp.act_as_admin();
  return v;
end $$;

-- ---- Fixtures: two stores, a stub provider with verified capabilities, one test connection each -------------
insert into ids values ('a', pg_temp.new_user('chan-a@example.test')), ('b', pg_temp.new_user('chan-b@example.test')),
                       ('staff', pg_temp.new_user('chan-staff@example.test'));
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'v_a', (api.upsert_product(pg_temp.id('store_a'), gen_random_uuid(), null,
  '{"name": "Abaya A", "base_price": 35000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 9}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;
insert into ids select 'zone_a', (api.upsert_zone(pg_temp.id('store_a'), null, null, 'Erbil', 5000, null, gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'imported', (api.create_conversation(pg_temp.id('store_a'), 'instagram', null,
  '[{"direction": "in", "body": "pasted text"}]', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Shop B', '+9647701234567', 'IQD', 'en', 'Duhok', gen_random_uuid()) #>> '{data,id}')::uuid;

select pg_temp.act_as_admin();
insert into app.store_members (store_id, user_id, role, permissions) values (pg_temp.id('store_a'), pg_temp.id('staff'), 'staff', '{}');
insert into app.providers (id, display_name, status) values ('stub', 'Stub (tests only)', 'in_development'),
                                                            ('stub_unres', 'Stub, unresolved capabilities', 'in_development');
insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('stub', 'outbound_text', 'true', 'verified', 'https://stub.invalid/docs', current_date),
  ('stub', 'reply_window_hours', '24', 'verified', 'https://stub.invalid/docs', current_date),
  ('stub', 'max_text_length', '1000', 'verified', 'https://stub.invalid/docs', current_date),
  ('stub_unres', 'outbound_text', 'true', 'unresolved', null, null),
  ('stub_unres', 'reply_window_hours', '24', 'unresolved', null, null);
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at)
  values (pg_temp.id('store_a'), 'stub', 'acct-A', 'connected', true, now()) returning id) insert into ids select 'conn_a', id from x;
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at)
  values (pg_temp.id('store_b'), 'stub', 'acct-B', 'connected', true, now()) returning id) insert into ids select 'conn_b', id from x;
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at)
  values (pg_temp.id('store_a'), 'stub_unres', 'acct-U', 'connected', true, now()) returning id) insert into ids select 'conn_u', id from x;

-- ---- Registry and the capability rule ----------------------------------------------------------------------
select is((select array_agg(id order by id) from app.providers where status = 'planned' and id !~ '^(stub|e2e_)'),
          array['instagram', 'messenger', 'telegram', 'tiktok', 'viber', 'whatsapp'],
          'the target platforms are registered as planned: no real provider is usable');
select is((select count(*)::integer from app.provider_capabilities
             where provider_id in ('instagram', 'messenger', 'telegram', 'tiktok', 'viber', 'whatsapp')), 0,
          '… and none has a capability yet');
select is(app.provider_capability('stub_unres', 'reply_window_hours'), null, 'an UNRESOLVED capability counts as absent');
select is(app.provider_capability('stub', 'reply_window_hours'), '24'::jsonb, 'a VERIFIED capability is used');
select throws_ok($$ insert into app.connections (store_id, provider_id, external_account_id, state)
                    values ((select v from ids where k = 'store_b'), 'stub', 'acct-A', 'connected') $$, '23505', null,
                 'one provider account can belong to only one store at a time');
select is(pg_temp.ingest('instagram', 'e-planned', null, pg_temp.msg('x', 'u', 'm', 'hi')) #>> '{error,code}', 'UNKNOWN_PROVIDER',
          'a planned provider cannot ingest anything');

-- ---- Ingestion and deduplication ------------------------------------------------------------------------------
select is(pg_temp.ingest('stub', 'e1', null, pg_temp.msg('acct-A', 'cust-1', 'm1', 'سڵاو، ئەم کراسە بە چەندە؟', '{"display_name": "Customer\u0001 One"}'))
            -> 'data', '{"stored": true, "duplicate": false}'::jsonb, 'a verified, normalised event is stored');
select is(pg_temp.ingest('stub', 'e1', null, pg_temp.msg('acct-A', 'cust-1', 'm1', 'سڵاو، ئەم کراسە بە چەندە؟')) -> 'data',
          '{"stored": false, "duplicate": true}'::jsonb, 'the same event id again is acknowledged as a duplicate');
select is(pg_temp.ingest('stub', 'e-bad', null, '{"not": "an array"}') #>> '{error,code}', 'VALIDATION_FAILED',
          'a malformed payload is refused');
select pg_temp.process();
select pg_temp.act_as_admin();
insert into ids select 'conv_a', id from app.conversations where contact_id = (select id from app.contacts where external_user_id = 'cust-1');
select is((select row(source, is_sandbox, store_id = pg_temp.id('store_a'), connection_id = pg_temp.id('conn_a'))::text
             from app.conversations where id = pg_temp.id('conv_a')),
          row('live', false, true, true)::text, 'the message created a live conversation in the account''s store');
select ok((select convert_to(body, 'UTF8') = convert_to('سڵاو، ئەم کراسە بە چەندە؟', 'UTF8') from app.messages
            where conversation_id = pg_temp.id('conv_a') and origin = 'channel_in'),
          'the Sorani customer text is stored byte for byte');
select is((select display_name from app.contacts where external_user_id = 'cust-1'), 'Customer  One',
          'control characters are removed from the untrusted display name');
select ok((select window_expires_at between now() + interval '23 hours 59 minutes' and now() + interval '24 hours 1 minute'
             from app.contacts where external_user_id = 'cust-1'),
          'the reply window opens for the provider''s verified 24 hours');
select pg_temp.ingest('stub', 'e2', null, pg_temp.msg('acct-A', 'cust-1', 'm1', 'سڵاو، ئەم کراسە بە چەندە؟'));
select pg_temp.process();
select is((pg_temp.event('e2') -> 'outcome'), '["duplicate_message"]'::jsonb,
          'the same provider message in a different event is deduplicated at message level');
select is((select count(*)::integer from app.messages where conversation_id = pg_temp.id('conv_a')), 1, '… one message only');

-- Forged and unknown routing.
select pg_temp.ingest('stub', 'e3', pg_temp.id('conn_a')::text, pg_temp.msg('acct-B', 'cust-x', 'm3', 'routed to A by URL'));
select pg_temp.ingest('stub', 'e4', null, pg_temp.msg('acct-nobody', 'cust-y', 'm4', 'unknown account'));
select pg_temp.ingest('stub', 'e5', null, pg_temp.msg('acct-B', 'cust-b', 'm5', 'hello B'));
select pg_temp.process();
select is(pg_temp.event('e3') ->> 'status', 'ignored', 'an event whose URL hint names another store''s connection is ignored');
select is(pg_temp.event('e3') -> 'outcome', '["hint_mismatch"]'::jsonb, '… as a hint mismatch');
select is((select count(*)::integer from app.messages where body = 'routed to A by URL'), 0, '… and lands in no store');
select is(pg_temp.event('e4') -> 'outcome', '["unknown_account"]'::jsonb, 'an unknown account is ignored');
select is((select c.store_id from app.messages m join app.conversations c on c.id = m.conversation_id where m.body = 'hello B'),
          pg_temp.id('store_b'), 'the store comes from the verified account id');
select pg_temp.ingest('stub', 'e6', null, pg_temp.msg('acct-A', 'cust-1', 'm6', 'old', jsonb_build_object('occurred_at', now() - interval '8 days')));
select pg_temp.ingest('stub', 'e7', null, pg_temp.msg('acct-A', 'cust-1', 'm7', '',
  '{"attachments": [{"kind": "voice", "ref": "media-123", "mime_type": "audio/ogg", "size_bytes": 2048}]}'));
select pg_temp.process();
select is(pg_temp.event('e6') -> 'outcome', '["stale"]'::jsonb, 'events older than 7 days are not turned into messages');
select is((select m.body || '|' || a.kind || '|' || a.provider_ref from app.messages m join app.message_attachments a on a.message_id = m.id
            where m.external_message_id = 'm7'), '[voice]|voice|media-123',
          'attachments are kept as references only, with a placeholder body');

-- Retries, failure and replay.
select pg_temp.ingest('stub', 'e8', null, '[{"kind": "message", "account_id": "acct-A", "external_message_id": "m8", "text": "no user"}]');
select pg_temp.process();
select is((select row(status, attempts, last_error_code, next_attempt_at > now())::text from app.webhook_events where external_event_id = 'e8'),
          row('received', 1, '22023', true)::text, 'a failing event is retried later with backoff');
update app.webhook_events set attempts = 7, next_attempt_at = now() - interval '1 second' where external_event_id = 'e8';
select pg_temp.process();
select is(pg_temp.event('e8') ->> 'status', 'failed', 'after the last attempt it is marked failed');
select is(internal.channel_replay(array[(pg_temp.event('e1') ->> 'id')::bigint, (pg_temp.event('e8') ->> 'id')::bigint]), 2,
          'an operator can replay stored events');
select pg_temp.process();
select is((select count(*)::integer from app.messages where external_message_id = 'm1'), 1, 'replaying creates no duplicates');

-- Fair claiming per account.
update app.ai_limits set value = 3 where name = 'channel_batch_per_account';
select pg_temp.ingest('stub', 'flood-' || g, null, pg_temp.msg('acct-A', 'cust-flood', 'mf' || g, 'flood ' || g)) from generate_series(1, 8) g;
select pg_temp.ingest('stub', 'quiet-1', null, pg_temp.msg('acct-B', 'cust-q', 'mq1', 'quiet one'));
select pg_temp.process();
select is((select count(*)::integer from app.webhook_events where external_event_id like 'flood-%' and status = 'processed'), 3,
          'a busy account gets at most its per-cycle share');
select is(pg_temp.event('quiet-1') ->> 'status', 'processed', '… and another account is not starved');
update app.ai_limits set value = 20 where name = 'channel_batch_per_account';

-- ---- Seller-authorized sending -------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'send_en', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'Hello! It is 35,000 IQD.', null, 'reply', null,
                                                   '00000000-0000-0000-0000-0000000000e1');
select is(pg_temp.r('send_en') #>> '{data,state}', 'queued', 'the seller authorizes a reply');
select is(pg_temp.r('send_en') #>> '{data,text_sha256}', encode(sha256(convert_to('Hello! It is 35,000 IQD.', 'UTF8')), 'hex'),
          '… and its SHA-256 is computed over the exact UTF-8 bytes');
insert into res select 'send_ckb', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), E'سڵاو! نرخی ئەمە ٣٥٠٠٠ دینارە‌.', null, null, null, gen_random_uuid());
insert into res select 'send_ar', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), E'مرحباً، السعر ٣٥ ألف دينار  \n', null, null, null, gen_random_uuid());
select pg_temp.act_as_admin();
select is((select array_agg(convert_to(m.body, 'UTF8') = convert_to(t, 'UTF8') order by o)
             from unnest(array['Hello! It is 35,000 IQD.', E'سڵاو! نرخی ئەمە ٣٥٠٠٠ دینارە‌.', E'مرحباً، السعر ٣٥ ألف دينار  \n'],
                         array[pg_temp.r('send_en') #>> '{data,message_id}', pg_temp.r('send_ckb') #>> '{data,message_id}',
                               pg_temp.r('send_ar') #>> '{data,message_id}']) with ordinality u(t, mid, o)
             join app.messages m on m.id = u.mid::uuid),
          array[true, true, true], 'English, Sorani (with a zero-width non-joiner) and Arabic (trailing spaces, newline) are stored unaltered');
select ok((select bool_and(s.text_sha256 = encode(sha256(convert_to(m.body, 'UTF8')), 'hex'))
             from app.send_requests s join app.messages m on m.id = s.message_id),
          'every send request carries the hash of its message''s exact bytes');
select is((select row(actor_user_id = pg_temp.id('a'), after ->> 'text_sha256' = pg_temp.r('send_en') #>> '{data,text_sha256}',
                      after::text like '%35,000%')::text
             from app.audit_events where action = 'message.send_authorized' and entity_id = (pg_temp.r('send_en') #>> '{data,send_request_id}')::uuid),
          row(true, true, false)::text, 'the authorization is audited with the person and the hash, never the text');
select is((select count(*)::integer from app.send_requests s where not exists (
             select 1 from app.audit_events a where a.action = 'message.send_authorized' and a.entity_id = s.id and a.actor_user_id is not null)),
          0, 'every send request has an audited human authorization');
select throws_ok(format('update app.messages set body = %L where id = %L', 'changed', pg_temp.r('send_en') #>> '{data,message_id}'), 'AS002', null,
                 'the authorized text can never be changed afterwards');

select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'Hello! It is 35,000 IQD.', null, 'reply', null,
                           '00000000-0000-0000-0000-0000000000e1') #>> '{data,send_request_id}',
          pg_temp.r('send_en') #>> '{data,send_request_id}', 'a retry with the same key returns the same send (no double send)');
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'Different text', null, 'reply', null,
                           '00000000-0000-0000-0000-0000000000e1') #>> '{error,code}',
          'IDEMPOTENCY_KEY_REUSED', 'the same key with a different text is refused');
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('imported'), 'hi', null, null, null, gen_random_uuid()) #>> '{error,code}',
          'NOT_A_LIVE_CONVERSATION', 'an imported conversation cannot send');
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), '   ', null, null, null, gen_random_uuid()) #>> '{error,code}',
          'VALIDATION_FAILED', 'whitespace-only text is refused');
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), repeat('x', 1001), null, null, null, gen_random_uuid()) #>> '{error,details,max_length}',
          '1000', 'text longer than the provider''s verified maximum is refused');

-- Isolation and permission.
select pg_temp.act_as(pg_temp.id('b'));
select ok(not exists (select 1 from jsonb_each_text(jsonb_build_object(
    'send', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'hi', null, null, null, gen_random_uuid()) #>> '{error,code}',
    'send_own', api.send_message(pg_temp.id('store_b'), pg_temp.id('conv_a'), 'hi', null, null, null, gen_random_uuid()) #>> '{error,code}',
    'cancel', api.cancel_send(pg_temp.id('store_b'), (pg_temp.r('send_en') #>> '{data,send_request_id}')::uuid) #>> '{error,code}',
    'resolve', api.resolve_unknown_send(pg_temp.id('store_b'), (pg_temp.r('send_en') #>> '{data,send_request_id}')::uuid, 'mark_sent', gen_random_uuid()) #>> '{error,code}',
    'list', api.list_connections(pg_temp.id('store_a')) #>> '{error,code}')) e where e.value <> 'NOT_FOUND'),
  'seller B gets NOT_FOUND from every channel function on seller A''s data');
select is(jsonb_array_length(api.list_connections(pg_temp.id('store_b')) #> '{data,items}'), 1, 'seller B lists only its own connection');
select ok(api.list_connections(pg_temp.id('store_b'))::text not like '%credential%' and api.list_connections(pg_temp.id('store_b'))::text not like '%acct-B%',
          '… without credentials or account ids');
select pg_temp.act_as(pg_temp.id('staff'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'hi', null, null, null, gen_random_uuid()) #>> '{error,code}',
          'FORBIDDEN', 'staff without messages.send cannot send');

-- The AI and machine roles cannot authorize anything.
select pg_temp.act_as_role('aisellia_ai_worker');
select throws_ok(format('select api.send_message(%L, %L, ''hi'', null, null, null, gen_random_uuid())', pg_temp.id('store_a'), pg_temp.id('conv_a')),
                 '42501', null, 'the AI worker cannot send a message');
select throws_ok(format('select api.channel_claim_send(%L)', pg_temp.r('send_en') #>> '{data,send_request_id}'), '42501', null,
                 '… nor claim a send');
select throws_ok(format('select api.approve_order(%L, gen_random_uuid(), 1, ''{}'', gen_random_uuid())', pg_temp.id('store_a')), '42501', null,
                 '… nor approve an order');
select pg_temp.act_as_admin();
set local role aisellia_ai;
select throws_ok(format('select api.send_message(%L, %L, ''hi'', null, null, null, gen_random_uuid())', pg_temp.id('store_a'), pg_temp.id('conv_a')),
                 '42501', null, 'the PostgREST AI role cannot send either');
select pg_temp.act_as_role('aisellia_channel_ingest');
select throws_ok(format('select api.channel_claim_send(%L)', pg_temp.r('send_en') #>> '{data,send_request_id}'), '42501', null,
                 'the ingest role cannot claim sends');
select pg_temp.act_as_role('aisellia_channel_sender');
select throws_ok($$ select count(*) from app.send_requests $$, '42501', null, 'the sender cannot read tables');
select throws_ok(format('select api.send_message(%L, %L, ''hi'', null, null, null, gen_random_uuid())', pg_temp.id('store_a'), pg_temp.id('conv_a')),
                 '42501', null, '… nor authorize a send itself');

-- Window, blocked contact, capability and provider status.
select pg_temp.act_as_admin();
update app.contacts set window_expires_at = now() - interval '1 minute' where external_user_id = 'cust-1';
select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'hi', null, null, null, gen_random_uuid()) #>> '{error,code}',
          'REPLY_WINDOW_CLOSED', 'a closed reply window refuses the send');
select pg_temp.act_as_admin();
update app.contacts set window_expires_at = now() + interval '1 hour', blocked = true where external_user_id = 'cust-1';
select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'hi', null, null, null, gen_random_uuid()) #>> '{error,code}',
          'CONTACT_BLOCKED', 'a blocked contact cannot be messaged');
select pg_temp.act_as_admin();
update app.contacts set blocked = false where external_user_id = 'cust-1';
select pg_temp.ingest('stub_unres', 'u1', null, pg_temp.msg('acct-U', 'cust-u', 'mu1', 'hello'));
select pg_temp.process();
insert into ids select 'conv_u', id from app.conversations where connection_id = pg_temp.id('conn_u');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_u'),
                           'hi', null, null, null, gen_random_uuid()) #>> '{error,details,capability}',
          'outbound_text', 'a provider whose outbound capability is UNRESOLVED cannot send');
select pg_temp.act_as_admin();
update app.providers set status = 'suspended' where id = 'stub';
select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'hi', null, null, null, gen_random_uuid()) #>> '{error,code}',
          'CHANNEL_UNAVAILABLE', 'a suspended provider cannot send');
select pg_temp.act_as_admin();
update app.providers set status = 'in_development' where id = 'stub';
update app.connections set is_test = false where id = pg_temp.id('conn_a');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'hi', null, null, null, gen_random_uuid()) #>> '{error,code}',
          'CHANNEL_UNAVAILABLE', 'a provider still in development serves test connections only');
select pg_temp.act_as_admin();
update app.connections set is_test = true where id = pg_temp.id('conn_a');

-- Order confirmations: only for this conversation's approved order.
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'order', (api.create_order(pg_temp.id('store_a'), jsonb_build_object('customer_name', 'C', 'customer_phone', '+9647501112233',
  'zone_id', pg_temp.id('zone_a'), 'area', 'X', 'payment_method', 'cod',
  'lines', jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v_a'), 'quantity', 1))), gen_random_uuid()) #>> '{data,id}')::uuid;
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'Your order is confirmed.', null, 'order_confirmation', pg_temp.id('order'),
                           gen_random_uuid()) #>> '{error,code}', 'NOT_FOUND', 'a confirmation for an order not linked to the conversation is refused');
select pg_temp.act_as_admin();
update app.conversations set order_id = pg_temp.id('order') where id = pg_temp.id('conv_a');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'Your order is confirmed.', null, 'order_confirmation', pg_temp.id('order'),
                           gen_random_uuid()) #>> '{error,code}', 'ORDER_NOT_APPROVED', 'a confirmation before approval is refused');
select api.approve_order(pg_temp.id('store_a'), pg_temp.id('order'), (select version from app.orders where id = pg_temp.id('order')), '{}', gen_random_uuid());
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'Your order is confirmed.', null, 'order_confirmation', pg_temp.id('order'),
                           gen_random_uuid()) #>> '{data,state}', 'queued', 'after the seller approves, the seller can send the confirmation');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.send_requests where kind = 'order_confirmation'), 1,
          'no confirmation was created by the approval itself: only by the seller''s send');

-- Rate limit.
update app.ai_limits set value = (select count(*) from app.send_requests where store_id = pg_temp.id('store_a') and created_at > now() - interval '1 minute')
 where name = 'channel_sends_per_store_per_minute';
select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'hi', null, null, null, gen_random_uuid()) #>> '{error,details,scope}',
          'send_minute', 'the per-store send rate is enforced');
select pg_temp.act_as_admin();
update app.ai_limits set value = 60 where name = 'channel_sends_per_store_per_minute';

-- ---- The sender: claim, exact text, outcomes --------------------------------------------------------------
insert into res select 'claim_ckb', pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_ckb') #>> '{data,send_request_id}'));
select ok(convert_to(pg_temp.r('claim_ckb') #>> '{data,text}', 'UTF8') = convert_to(E'سڵاو! نرخی ئەمە ٣٥٠٠٠ دینارە‌.', 'UTF8')
          and pg_temp.r('claim_ckb') #>> '{data,text_sha256}' = pg_temp.r('send_ckb') #>> '{data,text_sha256}',
          'the sender receives exactly the authorized text and its hash');
select is(pg_temp.r('claim_ckb') #>> '{data,recipient}', 'cust-1', '… addressed to the conversation''s contact');
select is(pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_ckb') #>> '{data,send_request_id}')) #>> '{error,code}',
          'SEND_NOT_CLAIMABLE', 'a send is claimed once');
select is(pg_temp.sender('channel_complete_send', format('%L, %L, %L', pg_temp.r('send_ckb') #>> '{data,send_request_id}', 'pm-x',
                                                         encode(sha256(convert_to('something else', 'UTF8')), 'hex'))) #>> '{error,code}',
          'TEXT_INTEGRITY', 'completion with another text''s hash is refused');
select is((select state || ':' || error_code from app.send_requests where id = (pg_temp.r('send_ckb') #>> '{data,send_request_id}')::uuid),
          'unknown:text_integrity', '… and the send becomes unknown, never "sent"');
select is(pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_ckb') #>> '{data,send_request_id}')) #>> '{error,code}',
          'SEND_NOT_CLAIMABLE', 'an unknown send is never claimed again (no automatic resend)');

-- Retriable failures back off and give up; an unknown outcome is final until the seller decides.
select pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_ar') #>> '{data,send_request_id}'));
select is(pg_temp.sender('channel_fail_send', format('%L, ''retriable'', ''http_429'', 2000', pg_temp.r('send_ar') #>> '{data,send_request_id}')) #>> '{data,state}',
          'queued', 'a retriable failure returns the send to the queue');
select is(pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_ar') #>> '{data,send_request_id}')) #>> '{error,details,reason}',
          'backoff', '… not claimable before its backoff ends');
select pg_temp.act_as_admin();
update app.send_requests set next_attempt_at = null, attempts = 2 where id = (pg_temp.r('send_ar') #>> '{data,send_request_id}')::uuid;
select pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_ar') #>> '{data,send_request_id}'));
select is(pg_temp.sender('channel_fail_send', format('%L, ''retriable'', ''http_503'', null', pg_temp.r('send_ar') #>> '{data,send_request_id}')) #>> '{data,state}',
          'failed', 'after the last attempt it fails, visibly');
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'send_t', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'timeout case', null, null, null, gen_random_uuid());
select pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_t') #>> '{data,send_request_id}'));
select is(pg_temp.sender('channel_fail_send', format('%L, ''unknown'', ''timeout'', null', pg_temp.r('send_t') #>> '{data,send_request_id}')) #>> '{data,state}',
          'unknown', 'a timeout after the request left is unknown');
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'send_x', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'crash case', null, null, null, gen_random_uuid());
select pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_x') #>> '{data,send_request_id}'));
select pg_temp.act_as_admin();
update app.send_requests set claim_expires_at = now() - interval '1 second' where id = (pg_temp.r('send_x') #>> '{data,send_request_id}')::uuid;
select is(internal.channel_expire_send_claims(), 1, 'a claim that expired mid-send is detected');
select is((select state from app.send_requests where id = (pg_temp.r('send_x') #>> '{data,send_request_id}')::uuid), 'unknown',
          '… and becomes unknown, not retried');

-- The seller resolves unknown outcomes.
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'again', api.resolve_unknown_send(pg_temp.id('store_a'), (pg_temp.r('send_t') #>> '{data,send_request_id}')::uuid, 'send_again', gen_random_uuid());
select pg_temp.act_as_admin();
select is((select row(resend_of = (pg_temp.r('send_t') #>> '{data,send_request_id}')::uuid, authorized_by = pg_temp.id('a'),
                      text_sha256 = encode(sha256(convert_to('timeout case', 'UTF8')), 'hex'))::text
             from app.send_requests where id = (pg_temp.r('again') #>> '{data,send_request_id}')::uuid),
          row(true, true, true)::text, '"Send again" is a new, audited seller authorization of the same text');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.resolve_unknown_send(pg_temp.id('store_a'), (pg_temp.r('send_t') #>> '{data,send_request_id}')::uuid, 'mark_sent', gen_random_uuid()) #>> '{error,code}',
          'SEND_NOT_UNKNOWN', 'an unknown send is resolved once');
select is(api.resolve_unknown_send(pg_temp.id('store_a'), (pg_temp.r('send_x') #>> '{data,send_request_id}')::uuid, 'mark_sent', gen_random_uuid()) #>> '{data,state}',
          'sent', 'the seller can mark an unknown send as sent');

-- Success, delivery states, echoes.
insert into res select 'claim_en', pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_en') #>> '{data,send_request_id}'));
select is(pg_temp.sender('channel_complete_send', format('%L, %L, %L', pg_temp.r('send_en') #>> '{data,send_request_id}', 'pm-en',
                                                         pg_temp.r('claim_en') #>> '{data,text_sha256}')) #>> '{data,state}',
          'sent', 'completion with the authorized hash marks the send sent');
select is(pg_temp.sender('channel_complete_send', format('%L, %L, %L', pg_temp.r('send_en') #>> '{data,send_request_id}', 'pm-en',
                                                         pg_temp.r('claim_en') #>> '{data,text_sha256}')) #>> '{data,replayed}',
          'true', 'a repeated completion report is idempotent');
select pg_temp.ingest('stub', 'd1', null, '[{"kind": "delivery", "account_id": "acct-A", "provider_message_id": "pm-en"}]');
select pg_temp.ingest('stub', 'd2', null, '[{"kind": "read", "account_id": "acct-A", "provider_message_id": "pm-en"}]');
select pg_temp.ingest('stub', 'd3', null, '[{"kind": "failed", "account_id": "acct-A", "provider_message_id": "pm-en", "provider_event_key": "f1"}]');
select pg_temp.process();
select is((select delivery_state from app.messages where id = (pg_temp.r('send_en') #>> '{data,message_id}')::uuid), 'read',
          'delivery states advance to read and a later "failed" does not downgrade them');
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'send_echo', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'echo me', null, null, null, gen_random_uuid());
select pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_echo') #>> '{data,send_request_id}'));
select pg_temp.ingest('stub', 'x1', null, '[{"kind": "echo", "account_id": "acct-A", "external_user_id": "cust-1", "external_message_id": "pm-echo", "text": "echo me"}]');
select pg_temp.ingest('stub', 'x2', null, '[{"kind": "echo", "account_id": "acct-A", "external_user_id": "cust-1", "external_message_id": "pm-app", "text": "sent from the app"}]');
select pg_temp.process();
select is((select state || ':' || provider_message_id from app.send_requests where id = (pg_temp.r('send_echo') #>> '{data,send_request_id}')::uuid),
          'sent:pm-echo', 'an echo of an in-flight send (same recipient, same exact text) confirms it');
select is((select origin from app.messages where external_message_id = 'pm-app'), 'seller_external',
          'an echo of a reply written in the provider''s own app is recorded as such');

-- Vault-held credentials reach only the sender, for the connection being sent on.
select pg_temp.act_as_admin();
create temp table secret_value as select 'test-only-' || gen_random_uuid() as v;
grant select on secret_value to public;
update app.connections set credential_ref = vault.create_secret((select v from secret_value), 'mc2-test-' || gen_random_uuid())
 where id = pg_temp.id('conn_a');
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'send_c', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'with credential', null, null, null, gen_random_uuid());
select is(pg_temp.sender('channel_claim_send', quote_literal(pg_temp.r('send_c') #>> '{data,send_request_id}')) #>> '{data,credential}',
          (select v from secret_value), 'the sender receives the connection''s credential from Vault for this send');
select ok(api.list_connections(pg_temp.id('store_a'))::text not like '%' || (select v from secret_value) || '%',
          '… and the seller API never returns it');

-- ---- AI stays off for live conversations ------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.id('a'));
select is(api.request_ai_assist(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'reply', gen_random_uuid()) #>> '{error,details,reason}',
          'live_not_enabled', 'AI suggestions are refused on live conversations by default');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.stores where ai_live_enabled), 0, 'no store has live AI enabled');
select throws_ok(format('update app.conversations set connection_id = %L where id = %L', pg_temp.id('conn_a'), pg_temp.id('imported')),
                 '23514', null, 'an imported (or sandbox) conversation can never be attached to a connection');

-- ---- Retention and deletion ---------------------------------------------------------------------------------------
update app.webhook_events set received_at = now() - interval '15 days' where external_event_id = 'e1';
select ok(internal.purge_webhook_payloads() >= 1, 'webhook payloads older than 14 days are purged');
select is((select row(payload is null, payload_purged_at is not null, outcome is not null)::text from app.webhook_events where external_event_id = 'e1'),
          row(true, true, true)::text, '… the event row stays, with its outcome but without its content');
select is(internal.purge_webhook_payloads(interval '1 hour'), -1, 'a retention under one day is refused');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.delete_conversation(pg_temp.id('store_a'), pg_temp.id('conv_a')) #>> '{error,code}', 'SEND_IN_PROGRESS',
          'a conversation with a send in flight cannot be deleted');
select pg_temp.act_as_admin();
update app.send_requests set state = 'failed' where conversation_id = pg_temp.id('conv_a') and state in ('queued', 'sending');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.delete_conversation(pg_temp.id('store_a'), pg_temp.id('conv_a')) #>> '{data,deleted}', 'true',
          'otherwise the owner deletes it');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.send_requests where conversation_id = pg_temp.id('conv_a'))
          + (select count(*)::integer from app.messages where conversation_id = pg_temp.id('conv_a')), 0,
          '… with its messages and send records');
insert into app.account_deletion_requests (user_id, store_id, execute_after) values (pg_temp.id('b'), pg_temp.id('store_b'), now() - interval '1 minute');
select internal.purge_due_account_deletions();
select is((select count(*)::integer from app.connections where store_id = pg_temp.id('store_b'))
          + (select count(*)::integer from app.contacts where store_id = pg_temp.id('store_b'))
          + (select count(*)::integer from app.webhook_events where store_id = pg_temp.id('store_b')), 0,
          'account deletion removes the store''s connections, contacts and webhook events');

select * from finish();
rollback;
