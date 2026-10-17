-- Conversations, messages, written policies and the AI switch (Phase 8; Phase 1 US-020–022, BR-45–49),
-- including seller isolation for every new function.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(43);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;
create function pg_temp.cver(p text) returns integer language sql security definer as $$ select version from app.conversations where id = pg_temp.id(p) $$;

insert into ids values ('a', pg_temp.new_user('conv-a@example.test')), ('b', pg_temp.new_user('conv-b@example.test')),
  ('staff', pg_temp.new_user('conv-staff@example.test'));
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Shop B', '+9647701234567', 'IQD', 'en', 'Duhok', gen_random_uuid()) #>> '{data,id}')::uuid;

-- ---- Import (US-020) -----------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.id('a'));
insert into ids values ('k1', gen_random_uuid());
insert into res select 'c1', api.create_conversation(pg_temp.id('store_a'), 'instagram', 'Nzar',
  '[{"direction": "in", "body": "Hi, how much is the beige abaya?"}, {"direction": "out", "body": "Hello!"}]', pg_temp.id('k1'));
insert into ids select 'c1', (pg_temp.r('c1') #>> '{data,id}')::uuid;
select is(pg_temp.r('c1') #>> '{data,messages_added}', '2', 'a conversation is created with the pasted messages');
select is(api.create_conversation(pg_temp.id('store_a'), 'instagram', 'Nzar',
  '[{"direction": "in", "body": "Hi, how much is the beige abaya?"}, {"direction": "out", "body": "Hello!"}]', pg_temp.id('k1')),
  pg_temp.r('c1'), 'a retry with the same key replays (no duplicate conversation)');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.conversations where store_id = pg_temp.id('store_a')), 1, '… only one exists');
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'get', api.get_conversation(pg_temp.id('store_a'), pg_temp.id('c1'));
select is((pg_temp.r('get') -> 'data') ->> 'status', 'needs_reply', 'a new inbound message needs a reply');
select is((select jsonb_agg(jsonb_build_array(m ->> 'direction', m ->> 'origin', m ->> 'state') order by o)
             from jsonb_array_elements(pg_temp.r('get') #> '{data,messages}') with ordinality e(m, o)),
          '[["in", "imported", "imported"], ["out", "imported", "imported"]]'::jsonb,
          'pasted messages are labelled imported, never sent');
select is((pg_temp.r('get') -> 'data') ->> 'source', 'instagram', 'the source is recorded');
select is(api.create_conversation(pg_temp.id('store_a'), 'instagram', null, '[]', gen_random_uuid()) #>> '{error,details,fields,messages}',
          'required', 'empty text saves nothing (US-020)');
select is(api.create_conversation(pg_temp.id('store_a'), 'instagram', null, '[{"direction": "in", "body": "   "}]', gen_random_uuid())
            #>> '{error,details,fields,messages.0.body}', 'required', 'whitespace-only text saves nothing');
select is(api.create_conversation(pg_temp.id('store_a'), 'tiktok_live', null, '[{"direction": "in", "body": "hi"}]', gen_random_uuid())
            #>> '{error,details,fields,source}', 'invalid', 'an unknown source is refused');
select is(api.create_conversation(pg_temp.id('store_a'), 'whatsapp', null,
            jsonb_build_array(jsonb_build_object('direction', 'in', 'body', repeat('x', 4001))), gen_random_uuid())
            #>> '{error,details,fields,messages.0.body}', 'too_long', 'a message over 4,000 characters is refused');
select is(api.create_conversation(pg_temp.id('store_a'), 'whatsapp', null,
            '[{"direction": "in", "body": "hi", "state": "sent"}]', gen_random_uuid()) #>> '{error,details,fields,messages.0}',
          'invalid', 'a message cannot claim a state or origin');
select is(api.create_conversation(pg_temp.id('store_a'), 'whatsapp', null,
            (select jsonb_agg(jsonb_build_object('direction', 'in', 'body', 'm' || g)) from generate_series(1, 21) g), gen_random_uuid())
            #>> '{error,details,fields,messages}', 'too_many', 'at most 20 messages per import');

select is(api.import_messages(pg_temp.id('store_a'), pg_temp.id('c1'), '[{"direction": "in", "body": "Size M please"}]',
                              gen_random_uuid()) #>> '{data,messages_added}', '1', 'more messages can be imported');
select is(api.record_seller_reply(pg_temp.id('store_a'), pg_temp.id('c1'), 'It is available.', gen_random_uuid()) #>> '{data,conversation_id}',
          pg_temp.id('c1')::text, 'the seller records a reply they sent themselves');
select pg_temp.act_as_admin();
select is((select row(origin, state)::text from app.messages where conversation_id = pg_temp.id('c1') order by seq desc limit 1),
          row('seller_written', 'marked_sent')::text, '… as written and marked sent by the seller (never "sent")');
select is((select status from app.conversations where id = pg_temp.id('c1')), 'waiting', '… and the conversation waits for the customer');
select pg_temp.act_as(pg_temp.id('a'));
select api.import_messages(pg_temp.id('store_a'), pg_temp.id('c1'), '[{"direction": "in", "body": "OK"}]', gen_random_uuid());
select pg_temp.act_as_admin();
select is((select status from app.conversations where id = pg_temp.id('c1')), 'needs_reply', 'a new customer message needs a reply again');
select pg_temp.act_as(pg_temp.id('a'));

-- Status and settings.
select is(api.update_conversation(pg_temp.id('store_a'), pg_temp.id('c1'), pg_temp.cver('c1'), '{"status": "closed", "ai_paused": true}')
            #>> '{data,status}', 'closed', 'the seller closes a conversation');
select is(api.update_conversation(pg_temp.id('store_a'), pg_temp.id('c1'), 1, '{"status": "needs_reply"}') #>> '{error,code}',
          'CONFLICT_VERSION', 'a stale version is refused');
select is(api.update_conversation(pg_temp.id('store_a'), pg_temp.id('c1'), pg_temp.cver('c1'), '{"status": "needs_you"}')
            #>> '{error,details,fields,status}', 'invalid', 'the seller cannot set "Needs you" (only escalation does)');
select is(api.update_conversation(pg_temp.id('store_a'), pg_temp.id('c1'), pg_temp.cver('c1'), '{"order_id": null}')
            #>> '{error,details,fields,order_id}', 'unknown', 'a conversation cannot be linked to an order by hand');
select is(api.list_conversations(pg_temp.id('store_a')) #>> '{data,total}', '0', 'closed conversations leave the open list');
select is(api.list_conversations(pg_temp.id('store_a'), 'closed') #>> '{data,items,0,last_message,preview}', 'OK',
          'the list shows the latest message');

-- Sandbox (US-021).
insert into ids select 'sb', (api.create_conversation(pg_temp.id('store_a'), 'sandbox', null,
  '[{"direction": "in", "body": "test"}]', gen_random_uuid()) #>> '{data,id}')::uuid;
select is(api.get_conversation(pg_temp.id('store_a'), pg_temp.id('sb')) #>> '{data,is_sandbox}', 'true', 'a sandbox conversation is flagged');
select is(api.list_conversations(pg_temp.id('store_a'), 'sandbox') #>> '{data,total}', '1', 'sandboxes are listed apart');
select is(api.list_conversations(pg_temp.id('store_a'), 'all') #>> '{data,total}', '2', '… and in "all"');

-- ---- Written policies --------------------------------------------------------------------------------------
insert into res select 'p1', api.upsert_policy(pg_temp.id('store_a'), null, null, 'returns', 'Exchange within 3 days if unworn.', true,
                                               gen_random_uuid());
insert into ids select 'p1', (pg_temp.r('p1') #>> '{data,id}')::uuid;
select is(pg_temp.r('p1') #>> '{data,topic}', 'returns', 'the seller writes a policy');
select is(api.upsert_policy(pg_temp.id('store_a'), null, null, 'refunds', 'x', true, gen_random_uuid()) #>> '{error,details,fields,topic}',
          'invalid', 'an unknown topic is refused');
select is(api.upsert_policy(pg_temp.id('store_a'), null, null, 'other', repeat('x', 1001), true, gen_random_uuid())
            #>> '{error,details,fields,body}', 'too_long', 'a policy is at most 1,000 characters');
select is(api.upsert_policy(pg_temp.id('store_a'), pg_temp.id('p1'), 1, 'returns', 'Exchange within 7 days.', true, gen_random_uuid())
            #>> '{data,version}', '2', 'a policy is edited with its version');
select is(jsonb_array_length(api.list_policies(pg_temp.id('store_a')) #> '{data,items}'), 1, 'policies are listed');

-- ---- The AI switch (owner) ---------------------------------------------------------------------------------
select is(api.set_ai_enabled(pg_temp.id('store_a'), false) #>> '{data,ai_enabled}', 'false', 'the owner switches the AI off');
select is(api.list_policies(pg_temp.id('store_a')) #>> '{data,ai_enabled}', 'false', '… and it is stored');
select api.set_ai_enabled(pg_temp.id('store_a'), true);
select pg_temp.act_as_admin();
insert into app.store_members (store_id, user_id, role, permissions)
values (pg_temp.id('store_a'), pg_temp.id('staff'), 'staff', '{"ai.manage": true, "conversations.manage": true}');
select pg_temp.act_as(pg_temp.id('staff'));
select is(api.set_ai_enabled(pg_temp.id('store_a'), false) #>> '{error,code}', 'FORBIDDEN',
          'staff cannot switch the AI, even with the permission');

-- ---- Isolation: seller B gets NOT_FOUND for everything of A -------------------------------------------
select pg_temp.act_as(pg_temp.id('b'));
create function pg_temp.attempts(p_store uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'get', api.get_conversation(p_store, pg_temp.id('c1')) #>> '{error,code}',
    'import', api.import_messages(p_store, pg_temp.id('c1'), '[{"direction": "in", "body": "x"}]', gen_random_uuid()) #>> '{error,code}',
    'reply', api.record_seller_reply(p_store, pg_temp.id('c1'), 'x', gen_random_uuid()) #>> '{error,code}',
    'update', api.update_conversation(p_store, pg_temp.id('c1'), 1, '{"status": "closed"}') #>> '{error,code}',
    'policy_edit', api.upsert_policy(p_store, pg_temp.id('p1'), 2, 'returns', 'mine', true, gen_random_uuid()) #>> '{error,code}',
    'policy_delete', api.delete_policy(p_store, pg_temp.id('p1'), 2) #>> '{error,code}')
$$;
insert into res select 'via_a', pg_temp.attempts(pg_temp.id('store_a'));
insert into res select 'via_b', pg_temp.attempts(pg_temp.id('store_b'));
select ok(not exists (select 1 from jsonb_each_text(pg_temp.r('via_a')) e where e.value <> 'NOT_FOUND'),
          'B gets NOT_FOUND from every conversation and policy function via A''s store id');
select ok(not exists (select 1 from jsonb_each_text(pg_temp.r('via_b')) e where e.value <> 'NOT_FOUND'),
          '… and via B''s own store id');
select is(api.list_conversations(pg_temp.id('store_a')) #>> '{error,code}', 'NOT_FOUND', 'B cannot list A''s conversations');
select is(api.list_policies(pg_temp.id('store_a')) #>> '{error,code}', 'NOT_FOUND', 'B cannot list A''s policies');
select is(api.set_ai_enabled(pg_temp.id('store_a'), false) #>> '{error,code}', 'NOT_FOUND', 'B cannot switch A''s AI');
select is(api.create_conversation(pg_temp.id('store_a'), 'other', null, '[{"direction": "in", "body": "x"}]', gen_random_uuid())
            #>> '{error,code}', 'NOT_FOUND', 'B cannot create a conversation in A''s store');
select is(api.list_conversations(pg_temp.id('store_b'), 'all') #>> '{data,total}', '0', 'B''s own list holds none of A''s');
select throws_ok($$ select * from app.messages $$, '42501', null, 'messages are not readable directly');
select pg_temp.act_as_anon();
select throws_ok($$ select api.list_conversations(pg_temp.id('store_a')) $$, '42501', null, 'anon cannot call conversation functions');

select * from finish();
rollback;
