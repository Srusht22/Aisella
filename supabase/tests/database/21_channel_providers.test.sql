-- Phase 9: provider webhook normalisers (run in the database since the security review, O6) and the
-- registry gates of the real providers. Bodies follow each provider's public webhook reference;
-- see the migrations' EVIDENCE notes (assumption until the official pages are verified).
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(19);

create temp table ids (k text primary key, v uuid);
grant all on ids to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.norm(p_provider text, p_body jsonb, p_conn app.connections default null) returns jsonb
language plpgsql as $$
declare v jsonb; p app.providers;
begin
  select * into p from app.providers where id = p_provider;
  execute format('select app.%I($1, $2, $3)', 'channel_normalize_' || p.payload_format) into v using p, p_conn, p_body;
  return v -> 'events';
end $$;

-- ---- Instagram -------------------------------------------------------------------------------------------------
select is((select row(webhook_scheme, payload_format, status)::text from app.providers where id = 'instagram'),
          row('meta_sha256', 'meta_instagram', 'in_development')::text, 'Instagram: Meta signature, Instagram body, test connections only');
create function pg_temp.ig(p_messaging jsonb, p_object text default 'instagram') returns jsonb language sql as $$
  select pg_temp.norm('instagram', jsonb_build_object('object', p_object, 'entry',
           jsonb_build_array(jsonb_build_object('id', '17841400000000001', 'time', 1760781600, 'messaging', p_messaging))))
$$;
select is(pg_temp.ig('[{"sender": {"id": "620314"}, "recipient": {"id": "17841400000000001"}, "timestamp": 1760781600000,
                        "message": {"mid": "aWdf1", "text": "ئەم کراسە چەندە؟"}}]'),
          '[{"kind": "message", "account_id": "17841400000000001", "external_user_id": "620314", "external_message_id": "aWdf1",
             "occurred_at": "2025-10-18T10:00:00+00:00", "text": "ئەم کراسە چەندە؟"}]'::jsonb,
          'Instagram: a text message (account = IG account, user = IGSID, id = mid, time from ms)');
select is(pg_temp.ig('[{"sender": {"id": "17841400000000001"}, "recipient": {"id": "620314"}, "timestamp": 1760781600000,
                        "message": {"mid": "aWdf2", "text": "sent natively", "is_echo": true, "app_id": 999}}]') -> 0,
          '{"kind": "echo", "account_id": "17841400000000001", "external_user_id": "620314", "external_message_id": "aWdf2",
            "occurred_at": "2025-10-18T10:00:00+00:00", "text": "sent natively", "sent_by_app": false}'::jsonb,
          'Instagram: an echo addressed to the customer, not marked as ours when another app sent it');
select vault.create_secret('424242', 'aisellia/provider/instagram/app_id');
select is(pg_temp.ig('[{"sender": {"id": "17841400000000001"}, "recipient": {"id": "620314"},
                        "message": {"mid": "aWdf3", "text": "from Aisellia", "is_echo": true, "app_id": 424242}}]') #>> '{0,sent_by_app}',
          'true', 'Instagram: an echo carrying our app id is marked as ours');
select is(pg_temp.ig('[{"sender": {"id": "620314"}, "recipient": {"id": "1"}, "message": {"mid": "aWdf4",
                        "attachments": [{"type": "image", "payload": {"url": "https://cdn.invalid/x.jpg"}}, {"type": "ig_reel"}]}}]') -> 0,
          '{"kind": "message", "account_id": "17841400000000001", "external_user_id": "620314", "external_message_id": "aWdf4",
            "attachments": [{"kind": "image"}, {"kind": "other"}]}'::jsonb,
          'Instagram: attachments keep their kind only (no CDN URL is stored)');
select is(pg_temp.ig('[{"sender": {"id": "620314"}, "message": {"mid": "aWdf5", "is_deleted": true}},
                       {"sender": {"id": "620314"}, "reaction": {"mid": "aWdf1", "action": "react"}},
                       {"sender": {"id": "620314"}, "postback": {"payload": "x"}}]'), '[]'::jsonb,
          'Instagram: unsent messages, reactions and postbacks produce nothing');
select is(pg_temp.ig('[{"sender": {"id": "620314"}, "read": {"mid": "aWdf2"}}]'),
          '[{"kind": "read", "account_id": "17841400000000001", "provider_message_id": "aWdf2", "provider_event_key": "read:aWdf2"}]'::jsonb,
          'Instagram: a read receipt names the message it read');
select is(pg_temp.ig('[{"sender": {"id": "620314"}, "message": {"mid": "aWdf6", "text": "x"}}]', 'page'), '[]'::jsonb,
          'Instagram: a Page (Messenger) body is not an Instagram body');
select is(pg_temp.ig('[{"sender": {"id": "620314"}, "timestamp": "soon", "message": {"mid": "aWdf7", "text": 42}}]') -> 0,
          '{"kind": "message", "account_id": "17841400000000001", "external_user_id": "620314", "external_message_id": "aWdf7"}'::jsonb,
          'Instagram: malformed fields are dropped, never fatal (no time, non-string text)');
select is(pg_temp.norm('instagram', '{"object": "instagram", "entry": "nope"}'), '[]'::jsonb, 'Instagram: a malformed body yields nothing');
select is((select array_agg(capability || ':' || evidence order by capability) from app.provider_capabilities
            where provider_id = 'instagram' and evidence = 'verified'), null,
          'Instagram: no capability is recorded as verified (the official pages were not read)');

-- Sending through the real Instagram row stays blocked until outbound_text is VERIFIED.
insert into ids values ('a', pg_temp.new_user('prov-a@example.test')), ('b', pg_temp.new_user('prov-b@example.test'));
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Shop B', '+9647701234567', 'IQD', 'en', 'Duhok', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as_admin();
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at)
           values (pg_temp.id('store_a'), 'instagram', '17841400000000001', 'connected', true, now()) returning id)
insert into ids select 'ig_a', id from x;
select internal.channel_store_events('instagram', 'ev-ig-1', null,
  '[{"kind": "message", "account_id": "17841400000000001", "external_user_id": "620314", "external_message_id": "aWdf8", "text": "hi"}]',
  repeat('a', 64));
select internal.channel_process_batch();
insert into ids select 'conv_ig', id from app.conversations where connection_id = pg_temp.id('ig_a');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_ig'), 'hello', null, null, null, gen_random_uuid()) #>> '{error,code}',
          'CHANNEL_CAPABILITY_MISSING', 'Instagram: no send while outbound_text is only an assumption');
select pg_temp.act_as_admin();
update app.provider_capabilities set evidence = 'verified', checked_on = current_date where provider_id = 'instagram' and capability = 'outbound_text';
select pg_temp.act_as(pg_temp.id('a'));
create temp table sends (k text primary key, v uuid);
grant all on sends to public;
insert into sends select 'ig', (api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_ig'), 'hello', null, null, null, gen_random_uuid())
                                #>> '{data,send_request_id}')::uuid;
select isnt((select v from sends where k = 'ig'), null, 'Instagram: once verified (here only inside this test), the seller can send to a test connection');

-- The send endpoint's ownership check (api.check_send_dispatch).
select is(api.check_send_dispatch((select v from sends where k = 'ig')) ->> 'ok', 'true', 'the store''s owner may dispatch its send');
select pg_temp.act_as(pg_temp.id('b'));
select is(api.check_send_dispatch((select v from sends where k = 'ig')) #>> '{error,code}', 'NOT_FOUND',
          'another store''s user cannot dispatch it (and learns nothing)');
select is(api.check_send_dispatch(gen_random_uuid()) #>> '{error,code}', 'NOT_FOUND', 'an unknown send is NOT_FOUND');
select pg_temp.act_as_admin();
set local role anon;
select throws_ok(format('select api.check_send_dispatch(%L)', (select v from sends where k = 'ig')), '42501', null,
                 'an anonymous caller cannot even ask');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.audit_events where action = 'message.send_authorized' and store_id = pg_temp.id('store_a')), 1,
          'the send is audited once, with the person who authorized it');
select is((select status from app.providers where id = 'messenger'), 'planned', 'providers not yet implemented stay planned');

select * from finish();
rollback;
