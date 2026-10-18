-- Phase 9: provider webhook normalisers (run in the database since the security review, O6) and the
-- registry gates of the real providers. Bodies follow each provider's public webhook reference;
-- see the migrations' EVIDENCE notes (assumption until the official pages are verified).
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(39);

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

-- ---- Messenger -------------------------------------------------------------------------------------------------
select is((select row(webhook_scheme, payload_format, status)::text from app.providers where id = 'messenger'),
          row('meta_sha256', 'meta_messenger', 'in_development')::text, 'Messenger: Meta signature, Page body, test connections only');
create function pg_temp.fb(p_messaging jsonb, p_object text default 'page') returns jsonb language sql as $$
  select pg_temp.norm('messenger', jsonb_build_object('object', p_object, 'entry',
           jsonb_build_array(jsonb_build_object('id', '1066000000000001', 'time', 1760781600, 'messaging', p_messaging))))
$$;
select is(pg_temp.fb('[{"sender": {"id": "2463"}, "recipient": {"id": "1066000000000001"}, "timestamp": 1760781600000,
                        "message": {"mid": "m_1", "text": "مرحبا"}}]') -> 0,
          '{"kind": "message", "account_id": "1066000000000001", "external_user_id": "2463", "external_message_id": "m_1",
            "occurred_at": "2025-10-18T10:00:00+00:00", "text": "مرحبا"}'::jsonb, 'Messenger: a text message (account = Page, user = PSID)');
select is(pg_temp.fb('[{"sender": {"id": "2463"}, "delivery": {"mids": ["m_a", "m_b"], "watermark": 1760781600000}}]'),
          '[{"kind": "delivery", "account_id": "1066000000000001", "provider_message_id": "m_a", "provider_event_key": "delivery:m_a"},
            {"kind": "delivery", "account_id": "1066000000000001", "provider_message_id": "m_b", "provider_event_key": "delivery:m_b"}]'::jsonb,
          'Messenger: a delivery receipt becomes one item per delivered message');
select is(pg_temp.fb('[{"sender": {"id": "2463"}, "read": {"watermark": 1760781600000}}]'), '[]'::jsonb,
          'Messenger: a watermark-only read is ignored (it names no message)');
select is(pg_temp.fb('[{"sender": {"id": "2463"}, "message": {"mid": "m_2", "text": "x"}}]', 'instagram'), '[]'::jsonb,
          'Messenger: an Instagram body is not a Page body');
select is((select count(*)::integer from app.provider_capabilities where provider_id = 'messenger' and evidence = 'verified'), 0,
          'Messenger: no capability is recorded as verified');

-- ---- WhatsApp --------------------------------------------------------------------------------------------------
select is((select row(webhook_scheme, payload_format, status)::text from app.providers where id = 'whatsapp'),
          row('meta_sha256', 'whatsapp_cloud', 'in_development')::text, 'WhatsApp: Meta signature, Cloud API body, test connections only');
create function pg_temp.wa(p_value jsonb, p_field text default 'messages') returns jsonb language sql as $$
  select pg_temp.norm('whatsapp', jsonb_build_object('object', 'whatsapp_business_account', 'entry', jsonb_build_array(jsonb_build_object(
    'id', 'WABA1', 'changes', jsonb_build_array(jsonb_build_object('field', p_field, 'value',
      jsonb_build_object('messaging_product', 'whatsapp', 'metadata', '{"display_phone_number": "9647500000000", "phone_number_id": "106540352242922"}'::jsonb)
      || p_value))))))
$$;
select is(pg_temp.wa('{"contacts": [{"profile": {"name": "Shno"}, "wa_id": "9647501112233"}],
                       "messages": [{"from": "9647501112233", "id": "wamid.A", "timestamp": "1760781600", "type": "text", "text": {"body": "سڵاو"}}]}') -> 0,
          '{"kind": "message", "account_id": "106540352242922", "external_user_id": "9647501112233", "phone": "+9647501112233",
            "display_name": "Shno", "external_message_id": "wamid.A", "occurred_at": "2025-10-18T10:00:00+00:00", "text": "سڵاو"}'::jsonb,
          'WhatsApp: a text message (account = business number id, user = wa_id, phone in E.164, name from contacts)');
select is(pg_temp.wa('{"messages": [{"from": "9647501112233", "id": "wamid.B", "type": "image", "image": {"id": "media-1", "mime_type": "image/jpeg", "caption": "this one"}},
                                    {"from": "9647501112233", "id": "wamid.C", "type": "audio", "audio": {"id": "media-2", "voice": true}},
                                    {"from": "9647501112233", "id": "wamid.D", "type": "interactive", "interactive": {"button_reply": {"id": "b1", "title": "Yes"}}},
                                    {"from": "9647501112233", "id": "wamid.E", "type": "reaction", "reaction": {"emoji": "👍"}}]}'),
          '[{"kind": "message", "account_id": "106540352242922", "external_user_id": "9647501112233", "phone": "+9647501112233",
             "external_message_id": "wamid.B", "text": "this one", "attachments": [{"kind": "image", "ref": "media-1", "mime_type": "image/jpeg"}]},
            {"kind": "message", "account_id": "106540352242922", "external_user_id": "9647501112233", "phone": "+9647501112233",
             "external_message_id": "wamid.C", "attachments": [{"kind": "voice", "ref": "media-2"}]},
            {"kind": "message", "account_id": "106540352242922", "external_user_id": "9647501112233", "phone": "+9647501112233",
             "external_message_id": "wamid.D", "text": "Yes"}]'::jsonb,
          'WhatsApp: media become a media id to fetch later (never a URL), captions and button replies become text, reactions nothing');
select is(pg_temp.wa('{"statuses": [{"id": "wamid.S", "status": "sent", "timestamp": "1760781600", "recipient_id": "9647501112233"},
                                    {"id": "wamid.S", "status": "delivered", "timestamp": "1760781601", "recipient_id": "9647501112233"},
                                    {"id": "wamid.S", "status": "read", "timestamp": "1760781602", "recipient_id": "9647501112233"},
                                    {"id": "wamid.T", "status": "failed", "timestamp": "1760781603", "recipient_id": "9647501112233",
                                     "errors": [{"code": 131047, "title": "Re-engagement message"}]}]}'),
          '[{"kind": "delivery", "account_id": "106540352242922", "provider_message_id": "wamid.S", "provider_event_key": "delivered:wamid.S",
             "occurred_at": "2025-10-18T10:00:01+00:00"},
            {"kind": "read", "account_id": "106540352242922", "provider_message_id": "wamid.S", "provider_event_key": "read:wamid.S",
             "occurred_at": "2025-10-18T10:00:02+00:00"},
            {"kind": "failed", "account_id": "106540352242922", "provider_message_id": "wamid.T", "provider_event_key": "failed:wamid.T",
             "provider_status": "131047", "occurred_at": "2025-10-18T10:00:03+00:00"}]'::jsonb,
          'WhatsApp: delivered / read / failed statuses (with the error code, not its text); "sent" adds nothing');
select is(pg_temp.wa('{"messages": [{"from": "x", "id": "wamid.F", "type": "text", "text": {"body": "x"}}]}', 'account_update'), '[]'::jsonb,
          'WhatsApp: other webhook fields (account updates, templates) produce no messages');

-- From a WhatsApp webhook to anonymisation by phone number (review O2), through the real normaliser.
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at)
           values (pg_temp.id('store_a'), 'whatsapp', '106540352242922', 'connected', true, now()) returning id)
insert into ids select 'wa_a', id from x;
select internal.channel_store_events('whatsapp', 'ev-wa-1', null, pg_temp.wa('{"contacts": [{"profile": {"name": "Shno"}, "wa_id": "9647501112233"}],
  "messages": [{"from": "9647501112233", "id": "wamid.Z1", "type": "text", "text": {"body": "I am Shno, call me on this number"}}]}'), repeat('b', 64));
select internal.channel_process_batch();
select is((select phone from app.contacts where connection_id = pg_temp.id('wa_a')), '+9647501112233',
          'WhatsApp: the customer''s contact keeps their number for anonymisation');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.anonymize_customer(pg_temp.id('store_a'), '+9647501112233', gen_random_uuid()) #>> '{data,contacts_anonymized}', '1',
          'WhatsApp: anonymising the number reaches the WhatsApp contact');
select pg_temp.act_as_admin();
select is((select row(phone, display_name, external_user_id like 'anon:%')::text from app.contacts where connection_id = pg_temp.id('wa_a')),
          row(null::text, null::text, true)::text, 'WhatsApp: no number, name or wa_id is left on the contact');
select ok(not exists (select 1 from app.messages where connection_id = pg_temp.id('wa_a') and body is not null),
          'WhatsApp: the message text is purged');

-- ---- Telegram --------------------------------------------------------------------------------------------------
select is((select row(webhook_scheme, payload_format, status)::text from app.providers where id = 'telegram'),
          row('telegram_token', 'telegram_bot', 'in_development')::text, 'Telegram: per-bot secret token, Bot API update, test connections only');
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at)
           values (pg_temp.id('store_a'), 'telegram', '7000000001', 'connected', true, now()) returning id)
insert into ids select 'tg_a', id from x;
create function pg_temp.tg(p_update jsonb) returns jsonb language plpgsql as $$
declare c app.connections; p app.providers; v jsonb;
begin
  select * into c from app.connections where id = pg_temp.id('tg_a');
  select * into p from app.providers where id = 'telegram';
  return app.channel_normalize_telegram_bot(p, c, p_update);
end $$;
select is(pg_temp.tg('{"update_id": 9001, "message": {"message_id": 5, "from": {"id": 42, "is_bot": false, "first_name": "Shno", "last_name": "Ali", "username": "shno"},
                       "chat": {"id": 42, "type": "private"}, "date": 1760781600, "text": "سڵاو"}}'),
          '{"event_id": "9001", "events": [{"kind": "message", "account_id": "7000000001", "external_user_id": "42", "external_message_id": "42:5",
            "display_name": "Shno Ali", "occurred_at": "2025-10-18T10:00:00+00:00", "text": "سڵاو"}]}'::jsonb,
          'Telegram: a private message (account = the bot, id scoped to the chat, the update id as event id; no username kept)');
select is(pg_temp.tg('{"update_id": 9002, "message": {"message_id": 6, "from": {"id": 42}, "chat": {"id": 42, "type": "private"},
                       "contact": {"phone_number": "+9647501112233", "first_name": "Shno"}}}') #> '{events,0,attachments}',
          '[{"kind": "contact"}]'::jsonb, 'Telegram: a shared contact is recorded as such; its phone number is not stored');
select is(pg_temp.tg('{"update_id": 9003, "message": {"message_id": 7, "from": {"id": 42}, "chat": {"id": 42, "type": "private"},
                       "photo": [{"file_id": "small"}, {"file_id": "large"}], "caption": "this one?"}}') #> '{events,0}',
          '{"kind": "message", "account_id": "7000000001", "external_user_id": "42", "external_message_id": "42:7", "text": "this one?",
            "attachments": [{"kind": "image", "ref": "large"}]}'::jsonb, 'Telegram: a photo keeps the largest size''s file id and its caption');
select is((select jsonb_agg(pg_temp.tg(u) -> 'events') from jsonb_array_elements('[
            {"update_id": 1, "message": {"message_id": 1, "from": {"id": 9}, "chat": {"id": -100, "type": "group"}, "text": "group"}},
            {"update_id": 2, "message": {"message_id": 1, "from": {"id": 9, "is_bot": true}, "chat": {"id": 9, "type": "private"}, "text": "bot"}},
            {"update_id": 3, "edited_message": {"message_id": 1, "from": {"id": 9}, "chat": {"id": 9, "type": "private"}, "text": "edit"}},
            {"update_id": 4, "my_chat_member": {"chat": {"id": 9, "type": "private"}}}]') u),
          '[[], [], [], []]'::jsonb, 'Telegram: groups, bots, edits and membership updates produce no messages');
select is((select value from app.provider_capabilities where provider_id = 'telegram' and capability = 'reply_window_hours'), 'null'::jsonb,
          'Telegram: no customer-service window (recorded as an assumption)');

select * from finish();
rollback;
