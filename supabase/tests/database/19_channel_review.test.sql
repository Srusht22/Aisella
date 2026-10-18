-- Phase 9 MC-2 post-implementation review: regressions for the defects confirmed by the review.
--   R1 webhook event ids are scoped to the provider ACCOUNT (two sellers' bots can reuse an id).
--   R2 a live conversation holds only provider messages, and a pasted one never holds them.
--   R3 an order confirmation can only carry the server-rendered text of the approved order.
--   R4 deleting a live conversation erases the contact and the stored webhook payloads about them.
--   R5 a "delivered" or "read" after a provider "failed" report corrects the send's state.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(29);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;
grant usage on schema extensions to aisellia_channel_ingest, aisellia_channel_sender;   -- pgTAP; rolled back
grant aisellia_channel_ingest, aisellia_channel_sender to postgres with set true, inherit false;  -- rolled back
create function pg_temp.as_role(p_role text) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  execute format('set local role %I', p_role);
end $$;
create function pg_temp.ingest(p_event text, p_events jsonb) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as_admin();   -- normalised events: the storage step behind api.channel_ingest_raw (suite 20)
  v := internal.channel_store_events('stub', p_event, null, p_events, encode(sha256(convert_to(p_events::text, 'UTF8')), 'hex'));
  perform pg_temp.act_as_admin();
  return v;
end $$;
create function pg_temp.sender(p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_role('aisellia_channel_sender');
  execute p_sql into v;
  perform pg_temp.act_as_admin();
  return v;
end $$;
create function pg_temp.msg(p_account text, p_user text, p_mid text, p_text text, p_name text default null) returns jsonb
language sql as $$
  select jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('kind', 'message', 'account_id', p_account, 'external_user_id', p_user,
                                              'external_message_id', p_mid, 'occurred_at', now(), 'text', p_text, 'display_name', p_name)))
$$;

-- Fixtures: two stores, a stub provider (verified capabilities), one test connection each.
insert into ids values ('a', pg_temp.new_user('rev-a@example.test')), ('b', pg_temp.new_user('rev-b@example.test'));
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'v_a', (api.upsert_product(pg_temp.id('store_a'), gen_random_uuid(), null,
  '{"name": "Abaya A", "base_price": 35000, "track_stock": true, "status": "active", "option_types": ["Size"],
    "variants": [{"option_values": ["M"], "initial_stock": 9}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;
insert into ids select 'zone_a', (api.upsert_zone(pg_temp.id('store_a'), null, null, 'Erbil', 5000, null, gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'pasted', (api.create_conversation(pg_temp.id('store_a'), 'instagram', null,
  '[{"direction": "in", "body": "pasted text"}]', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Shop B', '+9647701234567', 'IQD', 'en', 'Duhok', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as_admin();
insert into app.providers (id, display_name, status) values ('stub', 'Stub (tests only)', 'in_development');
insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('stub', 'outbound_text', 'true', 'verified', 'https://stub.invalid/docs', current_date),
  ('stub', 'reply_window_hours', '24', 'verified', 'https://stub.invalid/docs', current_date);
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at)
           values (pg_temp.id('store_a'), 'stub', 'bot-A', 'connected', true, now()) returning id)
insert into ids select 'conn_a', id from x;
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at)
           values (pg_temp.id('store_b'), 'stub', 'bot-B', 'connected', true, now()) returning id)
insert into ids select 'conn_b', id from x;

-- ---- R1: event ids are scoped to the account ----------------------------------------------------------------
-- Per-bot providers number their updates per bot: two sellers' bots can both send update 1.
select is(pg_temp.ingest('update-1', pg_temp.msg('bot-A', 'cust-1', 'm-a1', 'hello A', 'Shno Ali')) #>> '{data,stored}', 'true',
          'store A''s event 1 is stored');
select is(pg_temp.ingest('update-1', pg_temp.msg('bot-B', 'cust-9', 'm-b1', 'hello B')) #>> '{data,stored}', 'true',
          'store B''s event with the same id is stored too, not dropped as a duplicate');
select is(pg_temp.ingest('update-1', pg_temp.msg('bot-A', 'cust-1', 'm-a1', 'hello A', 'Shno Ali')) #>> '{data,duplicate}', 'true',
          'a true redelivery for the same account is still a duplicate');
select internal.channel_process_batch();
select is((select count(*)::integer from app.messages where external_message_id in ('m-a1', 'm-b1')), 2,
          'both stores receive their message');
insert into ids select 'conv_a', id from app.conversations where connection_id = pg_temp.id('conn_a');

-- ---- R2: live and pasted conversations never mix ------------------------------------------------------------
select pg_temp.act_as(pg_temp.id('a'));
select is(api.import_messages(pg_temp.id('store_a'), pg_temp.id('conv_a'), '[{"direction": "in", "body": "pasted into live"}]',
                              gen_random_uuid()) #>> '{error,code}', 'CONVERSATION_IS_LIVE',
          'pasted messages cannot be added to a provider conversation');
select is(api.record_seller_reply(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'I sent this elsewhere', gen_random_uuid()) #>> '{error,code}',
          'CONVERSATION_IS_LIVE', '"I sent this" cannot be recorded in a provider conversation (it would look sent through the provider)');
select pg_temp.act_as_admin();
select throws_ok(format($$insert into app.messages (store_id, conversation_id, direction, origin, body, state, created_by)
                          values (%L, %L, 'out', 'ai_reply_copied', 'copied text', 'copied', %L)$$,
                        pg_temp.id('store_a'), pg_temp.id('conv_a'), pg_temp.id('a')),
                 'AS001', 'CONVERSATION_IS_LIVE', 'no function can add a copied-suggestion message to a provider conversation');
select throws_ok(format($$insert into app.messages (store_id, conversation_id, direction, origin, body, state, connection_id, external_message_id)
                          values (%L, %L, 'in', 'channel_in', 'injected', 'live', %L, 'm-x')$$,
                        pg_temp.id('store_a'), pg_temp.id('pasted'), pg_temp.id('conn_a')),
                 'AS001', 'CONVERSATION_NOT_LIVE', 'a provider message can never land in a pasted conversation');
with x as (insert into app.connections (store_id, provider_id, external_account_id, state, is_test)
           values (pg_temp.id('store_a'), 'stub', 'bot-A2', 'connected', true) returning id)
insert into ids select 'conn_a2', id from x;
select throws_ok(format($$insert into app.messages (store_id, conversation_id, direction, origin, body, state, connection_id, external_message_id)
                          values (%L, %L, 'in', 'channel_in', 'wrong connection', 'live', %L, 'm-y')$$,
                        pg_temp.id('store_a'), pg_temp.id('conv_a'), pg_temp.id('conn_a2')),
                 'AS001', 'CONNECTION_MISMATCH', 'a message must belong to its conversation''s connection');
select is((select count(*)::integer from app.messages where conversation_id = pg_temp.id('conv_a') and origin not in ('channel_in', 'seller_sent', 'seller_external')),
          0, 'the provider conversation holds only provider messages');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.import_messages(pg_temp.id('store_a'), pg_temp.id('pasted'), '[{"direction": "in", "body": "more pasted"}]',
                              gen_random_uuid()) #>> '{data,messages_added}', '1', 'pasting into a pasted conversation still works');

-- ---- R3: confirmations carry only the server-rendered text of the approved order -------------------------------
insert into ids select 'order', (api.create_order(pg_temp.id('store_a'), jsonb_build_object('customer_name', 'Shno', 'customer_phone', '+9647501112233',
  'zone_id', pg_temp.id('zone_a'), 'area', 'X', 'payment_method', 'cod',
  'lines', jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v_a'), 'quantity', 2))), gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as_admin();
update app.conversations set order_id = pg_temp.id('order') where id = pg_temp.id('conv_a');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.order_confirmation_text(pg_temp.id('store_a'), pg_temp.id('order'), 'en') #>> '{error,code}', 'ORDER_NOT_APPROVED',
          'no confirmation text exists before approval');
select api.approve_order(pg_temp.id('store_a'), pg_temp.id('order'), (select version from app.orders where id = pg_temp.id('order')), '{}', gen_random_uuid());
insert into res select 'en', api.order_confirmation_text(pg_temp.id('store_a'), pg_temp.id('order'), 'en');
insert into res select 'ckb', api.order_confirmation_text(pg_temp.id('store_a'), pg_temp.id('order'), 'ckb');
insert into res select 'ar', api.order_confirmation_text(pg_temp.id('store_a'), pg_temp.id('order'), 'ar');
select ok(pg_temp.r('en') #>> '{data,text}' like '%#' || (select number from app.orders where id = pg_temp.id('order')) || '%'
          and pg_temp.r('en') #>> '{data,text}' like '%75,000 IQD%',
          'the server renders the confirmation from the order record (number, total)');
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'Your order is confirmed! Free delivery tomorrow, total 1,000 IQD.',
                           null, 'order_confirmation', pg_temp.id('order'), gen_random_uuid()) #>> '{error,code}',
          'CONFIRMATION_TEXT_MISMATCH', 'a misleading confirmation text is refused even for an approved order');
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), (pg_temp.r('en') #>> '{data,text}') || ' ',
                           null, 'order_confirmation', pg_temp.id('order'), gen_random_uuid()) #>> '{error,code}',
          'CONFIRMATION_TEXT_MISMATCH', '… including the rendered text with any change at all');
select ok(not exists (select 1 from jsonb_each(jsonb_build_object(
    'en', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), pg_temp.r('en') #>> '{data,text}', null, 'order_confirmation', pg_temp.id('order'), gen_random_uuid()),
    'ckb', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), pg_temp.r('ckb') #>> '{data,text}', null, 'order_confirmation', pg_temp.id('order'), gen_random_uuid()),
    'ar', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), pg_temp.r('ar') #>> '{data,text}', null, 'order_confirmation', pg_temp.id('order'), gen_random_uuid())))
          e where e.value ->> 'ok' <> 'true'),
  'the exact server-rendered confirmation is accepted in English, Sorani and Arabic');
select pg_temp.act_as(pg_temp.id('b'));
select is(api.order_confirmation_text(pg_temp.id('store_a'), pg_temp.id('order'), 'en') #>> '{error,code}', 'NOT_FOUND',
          'another store cannot read the confirmation text');
select pg_temp.act_as_admin();
update app.orders set discount = 5000, total = total - 5000, cod_due = cod_due - 5000, version = version + 1 where id = pg_temp.id('order');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), pg_temp.r('en') #>> '{data,text}', null, 'order_confirmation',
                           pg_temp.id('order'), gen_random_uuid()) #>> '{error,code}',
          'CONFIRMATION_TEXT_MISMATCH', 'a confirmation rendered before the order changed is refused (stale amounts)');
select is(api.order_confirmation_text(pg_temp.id('store_a'), pg_temp.id('order'), 'xx') #>> '{error,code}', 'VALIDATION_FAILED',
          'only en, ckb and ar templates exist');

-- ---- R5: delivery state stays consistent ----------------------------------------------------------------------
select pg_temp.act_as_admin();
update app.conversations set order_id = null where id = pg_temp.id('conv_a');
update app.send_requests set state = 'cancelled' where conversation_id = pg_temp.id('conv_a') and state = 'queued';
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'send', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv_a'), 'multi-device', null, null, null, gen_random_uuid());
select pg_temp.sender(format('select api.channel_claim_send(%L)', pg_temp.r('send') #>> '{data,send_request_id}'));
select pg_temp.sender(format('select api.channel_complete_send(%L, %L, %L)', pg_temp.r('send') #>> '{data,send_request_id}', 'pm-md',
                             pg_temp.r('send') #>> '{data,text_sha256}'));
select pg_temp.ingest('f1', '[{"kind": "failed", "account_id": "bot-A", "provider_message_id": "pm-md", "provider_event_key": "f1"}]');
select internal.channel_process_batch();
select is((select state from app.send_requests where id = (pg_temp.r('send') #>> '{data,send_request_id}')::uuid), 'failed',
          'a provider "failed" report marks the send failed');
select pg_temp.ingest('d1', '[{"kind": "delivery", "account_id": "bot-A", "provider_message_id": "pm-md"}]');
select internal.channel_process_batch();
select is((select s.state || ':' || m.delivery_state from app.send_requests s join app.messages m on m.id = s.message_id
            where s.id = (pg_temp.r('send') #>> '{data,send_request_id}')::uuid), 'sent:delivered',
          'a later "delivered" (another device) corrects both the send and the message');

-- ---- R4: deleting a live conversation erases the contact's personal data --------------------------------------
select pg_temp.act_as_admin();
update app.send_requests set state = 'failed' where conversation_id = pg_temp.id('conv_a') and state in ('queued', 'sending');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.delete_conversation(pg_temp.id('store_a'), pg_temp.id('conv_a')) #>> '{data,deleted}', 'true', 'the owner deletes the live conversation');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.contacts where connection_id = pg_temp.id('conn_a') and external_user_id = 'cust-1'), 0,
          'the contact (name and provider user id) is erased');
select ok(not exists (select 1 from app.webhook_events where payload::text like '%cust-1%' or payload::text like '%Shno Ali%' or payload::text like '%hello A%'),
          'stored webhook payloads that mention the contact are purged');
select ok(exists (select 1 from app.webhook_events where external_event_id = 'update-1' and payload_purged_at is not null),
          '… the event rows stay (dedupe keys and outcomes), without content');
select is((select count(*)::integer from app.delivery_events where provider_message_id = 'pm-md'), 0,
          'delivery events of the deleted messages are removed');
select ok(exists (select 1 from app.audit_events where action = 'message.send_authorized' and store_id = pg_temp.id('store_a')),
          'the audit trail of who authorized which send is kept');
select ok(not exists (select 1 from app.audit_events where store_id = pg_temp.id('store_a')
                       and (coalesce(before::text, '') || coalesce(after::text, '')) ~ '(cust-1|Shno Ali|hello A|multi-device)'),
          '… and holds no message text, name or provider user id');
select is((select count(*)::integer from app.messages m join app.conversations c on c.id = m.conversation_id where c.store_id = pg_temp.id('store_b')), 1,
          'the other store''s conversation is untouched');

select * from finish();
rollback;
