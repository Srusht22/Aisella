-- Phase 9: WhatsApp message templates outside the customer-service window: the synced list (only
-- approved, utility, plain-text templates usable), the seller's send (server-rendered exact text,
-- parameter rules, every other send rule kept), the claim's integrity check, and the roles.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(34);

create temp table ids (k text primary key, v uuid);
grant all on ids to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
grant aisellia_channel_sender to postgres with set true, inherit false;   -- rolled back
create function pg_temp.sender(p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  set local role aisellia_channel_sender;
  execute p_sql into v;
  perform pg_temp.act_as_admin();
  return v;
end $$;
create function pg_temp.seller(p_sql text, p_user text default 'a') returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.id(p_user));
  execute p_sql into v;
  perform pg_temp.act_as_admin();
  return v;
end $$;
create function pg_temp.tpl(p_name text) returns uuid language sql as $$
  select id from app.message_templates where connection_id = pg_temp.id('conn') and name = p_name
$$;
create function pg_temp.send_tpl(p_name text, p_params jsonb, p_key uuid default gen_random_uuid()) returns jsonb language sql as $$
  select pg_temp.seller(format('select api.send_template(%L, %L, %L, %L, %L)', pg_temp.id('store_a'), pg_temp.id('conv'),
                                pg_temp.tpl(p_name), p_params, p_key))
$$;

-- Fixtures: a released WhatsApp-style provider (24-hour window), one connected number, one customer.
insert into ids values ('a', pg_temp.new_user('tpl-a@example.test')), ('b', pg_temp.new_user('tpl-b@example.test'));
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Shop B', '+9647501234568', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as_admin();
insert into app.providers (id, display_name, status, webhook_scheme, payload_format, connect_method)
values ('fx_wa', 'Template fixture', 'pilot', 'stub_sha256', 'aisellia_stub', 'whatsapp_signup');
insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('fx_wa', 'outbound_text', 'true', 'verified', 'https://fixture.invalid', current_date),
  ('fx_wa', 'reply_window_hours', '24', 'verified', 'https://fixture.invalid', current_date);
with x as (
  insert into app.connections (store_id, provider_id, external_account_id, display_name, state, connected_at, provider_meta)
  values (pg_temp.id('store_a'), 'fx_wa', '106540352242922', 'Shop A', 'connected', now(), '{"waba_id": "102290129340398"}')
  returning id)
insert into ids select 'conn', id from x;
select internal.channel_store_events('fx_wa', 'ev-1', null,
  '[{"kind": "message", "account_id": "106540352242922", "external_user_id": "9647501112233", "external_message_id": "in-1", "text": "hello"}]',
  repeat('e', 64));
select internal.channel_process_batch();
insert into ids select 'conv', id from app.conversations where connection_id = pg_temp.id('conn');
insert into ids select 'contact', contact_id from app.conversations where id = pg_temp.id('conv');

-- ---- Rendering (same cases as the sender's renderTemplate, templates_test.ts) ------------------------------------------
select is(app.render_template('سڵاو {{1}}، داواکارییەکەت {{2}} ئامادەیە. Order {{2}} is ready.', '["ئارام", "A-17"]'),
          'سڵاو ئارام، داواکارییەکەت A-17 ئامادەیە. Order A-17 is ready.', 'parameters replace {{n}}, every occurrence');
select is(app.render_template('No parameters.', '[]'), 'No parameters.', 'no parameters: the body as is');
select is(app.render_template('{{1}}{{1}} {{2}}', '["$&", "{1}"]'), '$&$& {1}', 'no pattern semantics in the replacement');

-- ---- Sync: which templates are usable --------------------------------------------------------------------------------
select is((select count(*)::integer from jsonb_array_elements(pg_temp.sender('select api.channel_due_template_syncs()') #> '{data,items}') x
            where x ->> 'connection_id' = pg_temp.id('conn')::text), 1,
          'a connected WhatsApp number never synced is due');
select is(pg_temp.sender($q$select api.channel_store_templates('$q$ || pg_temp.id('conn') || $q$', '[
  {"name": "order_ready", "language": "ckb", "status": "APPROVED", "category": "UTILITY",
   "components": [{"type": "BODY", "text": "سڵاو {{1}}، داواکارییەکەت {{2}} ئامادەیە."}]},
  {"name": "promo", "language": "ckb", "status": "APPROVED", "category": "MARKETING",
   "components": [{"type": "BODY", "text": "Sale {{1}}"}]},
  {"name": "with_header", "language": "en", "status": "APPROVED", "category": "UTILITY",
   "components": [{"type": "HEADER", "format": "IMAGE"}, {"type": "BODY", "text": "Hi {{1}}"}]},
  {"name": "pending_one", "language": "ar", "status": "PENDING", "category": "UTILITY",
   "components": [{"type": "BODY", "text": "مرحبا {{1}}"}]},
  {"name": "gap", "language": "en", "status": "APPROVED", "category": "UTILITY",
   "components": [{"type": "BODY", "text": "{{1}} and {{3}}"}]},
  {"name": "Bad Name", "language": "en", "status": "APPROVED", "category": "UTILITY",
   "components": [{"type": "BODY", "text": "x"}]}
]')$q$) #>> '{data,templates}', '5', 'stored what Meta returned (an invalid name is skipped)');
select is(array(select name from app.message_templates where connection_id = pg_temp.id('conn') and usable order by name),
          array['order_ready'], 'only the approved, utility, plain-text template with consecutive parameters is usable');
select is((select param_count from app.message_templates where id = pg_temp.tpl('order_ready')), 2, 'its parameter count');
select is((select count(*)::integer from jsonb_array_elements(pg_temp.sender('select api.channel_due_template_syncs()') #> '{data,items}') x
            where x ->> 'connection_id' = pg_temp.id('conn')::text), 0,
          'synced: not due again for six hours');

-- ---- The seller's view --------------------------------------------------------------------------------------------------
update app.contacts set window_expires_at = now() - interval '1 hour' where id = pg_temp.id('contact');
select is(pg_temp.seller(format('select api.list_templates(%L, %L)', pg_temp.id('store_a'), pg_temp.id('conv'))) #> '{data,window_open}',
          'false', 'the app learns the window is closed');
select is(pg_temp.seller(format('select api.list_templates(%L, %L)', pg_temp.id('store_a'), pg_temp.id('conv'))) #>> '{data,items,0,name}',
          'order_ready', '… and is offered only the usable template');
select is(pg_temp.seller(format('select api.list_templates(%L, %L)', pg_temp.id('store_a'), pg_temp.id('conv')), 'b') ->> 'ok',
          'false', 'another store''s user cannot list them');
select is(pg_temp.seller(format('select api.send_message(%L, %L, %L, null, null, null, %L)', pg_temp.id('store_a'), pg_temp.id('conv'),
                                'free text', gen_random_uuid())) #>> '{error,code}',
          'REPLY_WINDOW_CLOSED', 'outside the window, free-form text is still refused');

-- ---- Parameter rules -------------------------------------------------------------------------------------------------------
select is(pg_temp.send_tpl('order_ready', '["ئارام"]') #>> '{error,code}', 'VALIDATION_FAILED', 'wrong parameter count');
select is(pg_temp.send_tpl('order_ready', '["ئارام", "A\n17"]') #>> '{error,code}', 'VALIDATION_FAILED', 'a line break in a parameter');
select is(pg_temp.send_tpl('order_ready', '["ئارام", "A    17"]') #>> '{error,code}', 'VALIDATION_FAILED', 'four spaces in a row');
select is(pg_temp.send_tpl('order_ready', '["{{2}}", "x"]') #>> '{error,code}', 'VALIDATION_FAILED', 'a parameter cannot inject a placeholder');
select is(pg_temp.send_tpl('order_ready', '["", "x"]') #>> '{error,code}', 'VALIDATION_FAILED', 'an empty parameter');
select is(pg_temp.send_tpl('order_ready', '[1, "x"]') #>> '{error,code}', 'VALIDATION_FAILED', 'parameters are strings');
select is(pg_temp.send_tpl('promo', '["x"]') #>> '{error,code}', 'NOT_FOUND', 'a marketing template cannot be sent');

-- ---- The send: server-rendered exact text, authorized like any message ---------------------------------------------------
insert into ids values ('key1', gen_random_uuid());
insert into ids select 's1', (pg_temp.send_tpl('order_ready', '["ئارام", "A-17"]', pg_temp.id('key1')) #>> '{data,send_request_id}')::uuid;
select is((select s.kind || ':' || s.state || ':' || (s.text_sha256 = app.sha256_hex(m.body))::text from app.send_requests s
             join app.messages m on m.id = s.message_id where s.id = pg_temp.id('s1')),
          'template:queued:true', 'outside the window a template is queued, hashed like any message');
select is((select m.body from app.send_requests s join app.messages m on m.id = s.message_id where s.id = pg_temp.id('s1')),
          'سڵاو ئارام، داواکارییەکەت A-17 ئامادەیە.', 'the stored message is the rendered text the customer will read');
select is(pg_temp.send_tpl('order_ready', '["ئارام", "A-17"]', pg_temp.id('key1')) #>> '{data,send_request_id}',
          pg_temp.id('s1')::text, 'a retried request (same key) returns the same send');
select is(pg_temp.sender(format('select api.channel_claim_send(%L)', pg_temp.id('s1'))) #> '{data,template}',
          jsonb_build_object('name', 'order_ready', 'language', 'ckb', 'body_text', 'سڵاو {{1}}، داواکارییەکەت {{2}} ئامادەیە.',
                             'params', '["ئارام", "A-17"]'::jsonb),
          'the claim hands the sender the template and parameters to submit');

-- A template changed at Meta after authorization: the rendering no longer matches, so nothing is submitted.
insert into ids select 's2', (pg_temp.send_tpl('order_ready', '["ئارام", "B-2"]') #>> '{data,send_request_id}')::uuid;
update app.message_templates set body_text = 'Different {{1}} {{2}}' where id = pg_temp.tpl('order_ready');
select is(pg_temp.sender(format('select api.channel_claim_send(%L)', pg_temp.id('s2'))) #>> '{error,details,reason}',
          'template_unavailable', 'a changed template is not claimed');
select is((select state || ':' || coalesce(error_code, '') from app.send_requests where id = pg_temp.id('s2')),
          'failed:template_unavailable', '… the send fails visibly for the seller');
update app.message_templates set body_text = 'سڵاو {{1}}، داواکارییەکەت {{2}} ئامادەیە.' where id = pg_temp.tpl('order_ready');

-- Every other send rule still applies: a blocked customer gets no template either.
update app.contacts set blocked = true where id = pg_temp.id('contact');
select is(pg_temp.send_tpl('order_ready', '["ئارام", "A-18"]') #>> '{error,code}', 'CONTACT_BLOCKED', 'a blocked customer gets no template');
update app.contacts set blocked = false where id = pg_temp.id('contact');

-- A template removed at Meta: no longer usable.
select pg_temp.sender(format('select api.channel_store_templates(%L, %L)', pg_temp.id('conn'), '[]'));
select is((select status || ':' || usable::text from app.message_templates where id = pg_temp.tpl('order_ready')),
          'MISSING:false', 'a template gone from Meta is marked missing');
select is(pg_temp.send_tpl('order_ready', '["ئارام", "A-19"]') #>> '{error,code}', 'NOT_FOUND', '… and cannot be sent');

-- ---- What the app sees (conversation_json additions) ------------------------------------------------------------------
create temp table cj on commit drop as
  select pg_temp.seller(format('select api.get_conversation(%L, %L)', pg_temp.id('store_a'), pg_temp.id('conv'))) -> 'data' as v;
grant all on cj to public;
select is((select v #>> '{channel,provider}' || ':' || (v #>> '{channel,window_open}') || ':' || (v #>> '{channel,templates}') from cj),
          'fx_wa:false:true', 'a live conversation names its channel, the closed window and that templates are possible');
select ok((select not (v -> 'channel' ?| array['external_account_id', 'credential', 'phone', 'external_user_id']) from cj),
          'no provider ids, phone numbers or credentials in what the app sees');
select is((select m #>> '{send,state}' || ':' || (m #>> '{send,kind}') || ':' || (m #>> '{send,can_cancel}')
             from cj, jsonb_array_elements(v -> 'messages') m where m ->> 'body' = 'سڵاو ئارام، داواکارییەکەت A-17 ئامادەیە.'),
          'sending:template:false', 'each sent message carries its send state and what the seller can do (claimed: not cancellable)');
select is((select jsonb_typeof(m -> 'send') from cj, jsonb_array_elements(v -> 'messages') m where m ->> 'direction' = 'in' limit 1),
          'null', 'incoming messages have no send');

-- ---- Roles ------------------------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('authenticated', 'api.channel_store_templates(uuid, jsonb)', 'execute')
          and not has_function_privilege('authenticated', 'api.channel_due_template_syncs()', 'execute'),
          'a seller cannot write templates or read the sync credentials');
select ok(not has_function_privilege('aisellia_channel_sender', 'api.send_template(uuid, uuid, uuid, jsonb, uuid)', 'execute')
          and not has_function_privilege('aisellia_ai_worker', 'api.send_template(uuid, uuid, uuid, jsonb, uuid)', 'execute')
          and not has_function_privilege('aisellia_ai', 'api.list_templates(uuid, uuid)', 'execute'),
          'neither the sender nor any AI role can send a template');

select * from finish();
rollback;
