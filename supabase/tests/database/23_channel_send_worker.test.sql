-- Phase 9: the background send worker's selection (api.channel_due_sends) and the delivery-state
-- transitions it drives: order per conversation, per-recipient pacing, fairness across connections,
-- backoff, retry limit, unknown never selected, suspended providers skipped.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(21);

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
create function pg_temp.due(p_limit integer default 50) returns uuid[] language sql as $$
  select coalesce(array(select (x #>> '{}')::uuid from jsonb_array_elements(pg_temp.sender(format('select api.channel_due_sends(%s)', p_limit)) #> '{data,ids}') x), '{}')
$$;
create function pg_temp.send(p_conv text, p_text text) returns uuid language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.id('a'));
  v := api.send_message(pg_temp.id('store_a'), pg_temp.id(p_conv), p_text, null, null, null, gen_random_uuid());
  perform pg_temp.act_as_admin();
  return (v #>> '{data,send_request_id}')::uuid;
end $$;
create function pg_temp.state(p uuid) returns text language sql as $$
  select s.state || ':' || coalesce(m.delivery_state, '') from app.send_requests s join app.messages m on m.id = s.message_id where s.id = p
$$;

-- Fixtures: one store, a released fixture provider, three connections (two of the same provider).
insert into ids values ('a', pg_temp.new_user('wk-a@example.test'));
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as_admin();
insert into app.providers (id, display_name, status, webhook_scheme, payload_format) values
  ('wk', 'Worker fixture', 'pilot', 'stub_sha256', 'aisellia_stub'),
  ('wk_paced', 'Paced fixture', 'pilot', 'stub_sha256', 'aisellia_stub');
insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on)
select p, c, v::jsonb, 'verified', 'https://fixture.invalid', current_date
  from unnest(array['wk', 'wk_paced']) p, (values ('outbound_text', 'true'), ('reply_window_hours', 'null')) x(c, v);
insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on)
values ('wk_paced', 'per_recipient_min_interval_ms', '6000', 'verified', 'https://fixture.invalid', current_date);
with x as (
  insert into app.connections (store_id, provider_id, external_account_id, display_name, state, connected_at)
  select pg_temp.id('store_a'), case when n = 3 then 'wk_paced' else 'wk' end, 'acct-' || n, 'Shop', 'connected', now()
    from generate_series(1, 3) n
  returning id, external_account_id)
insert into ids select 'c' || substr(external_account_id, 6), id from x;
select internal.channel_store_events(p, 'ev-' || n, null,
  jsonb_build_array(jsonb_build_object('kind', 'message', 'account_id', 'acct-' || n, 'external_user_id', 'u-' || n,
                                       'external_message_id', 'in-' || n, 'text', 'hello')), repeat('e', 64))
  from (values (1, 'wk'), (2, 'wk'), (3, 'wk_paced')) v(n, p);
select internal.channel_process_batch();
insert into ids select 'v' || n, (select id from app.conversations where connection_id = pg_temp.id('c' || n)) from generate_series(1, 3) n;

-- ---- Order within a conversation --------------------------------------------------------------------------------
insert into ids values ('s1a', pg_temp.send('v1', 'first')), ('s1b', pg_temp.send('v1', 'second')), ('s2a', pg_temp.send('v2', 'other'));
select ok(pg_temp.id('s1a') = any (pg_temp.due()) and not pg_temp.id('s1b') = any (pg_temp.due()),
          'a conversation''s second reply waits until its first is done: never out of order');
select ok(pg_temp.id('s2a') = any (pg_temp.due()), 'another conversation is not held up');
select is(pg_temp.sender(format('select api.channel_claim_send(%L)', pg_temp.id('s1a'))) ->> 'ok', 'true', 'the worker claims the first');
select is(pg_temp.state(pg_temp.id('s1a')), 'sending:sending', 'claimed: sending');
select ok(not pg_temp.id('s1b') = any (pg_temp.due()), '… the second still waits while the first is sending');
select pg_temp.sender(format('select api.channel_complete_send(%L, %L, %L)', pg_temp.id('s1a'), 'pm-1',
                             (select text_sha256 from app.send_requests where id = pg_temp.id('s1a'))));
select is(pg_temp.state(pg_temp.id('s1a')), 'sent:sent', 'accepted by the provider: sent');
select ok(pg_temp.id('s1b') = any (pg_temp.due()), 'then the second becomes due');

-- ---- Delivery receipts move the state forward only -----------------------------------------------------------------
select internal.channel_store_events('wk', 'ev-d', null, '[{"kind": "delivery", "account_id": "acct-1", "provider_message_id": "pm-1"}]', repeat('f', 64));
select internal.channel_store_events('wk', 'ev-r', null, '[{"kind": "read", "account_id": "acct-1", "provider_message_id": "pm-1"}]', repeat('1', 64));
select internal.channel_process_batch();
select is(pg_temp.state(pg_temp.id('s1a')), 'sent:read', 'delivered then read: the message shows read');
select internal.channel_store_events('wk', 'ev-d2', null, '[{"kind": "delivery", "account_id": "acct-1", "provider_message_id": "pm-1", "provider_event_key": "late"}]', repeat('2', 64));
select internal.channel_process_batch();
select is(pg_temp.state(pg_temp.id('s1a')), 'sent:read', 'a late "delivered" never moves it back');

-- ---- Retries: backoff, then the retry limit ------------------------------------------------------------------------
select pg_temp.sender(format('select api.channel_claim_send(%L)', pg_temp.id('s2a')));
select pg_temp.sender(format('select api.channel_fail_send(%L, %L, %L, %s)', pg_temp.id('s2a'), 'retriable', 'rate_limited', 30000));
select is(pg_temp.state(pg_temp.id('s2a')), 'queued:queued', 'a retriable failure goes back to the queue');
select ok(not pg_temp.id('s2a') = any (pg_temp.due()), '… and is not due during its backoff (the provider''s retry-after)');
update app.send_requests set next_attempt_at = now() - interval '1 second' where id = pg_temp.id('s2a');
select ok(pg_temp.id('s2a') = any (pg_temp.due()), '… then due again');
select pg_temp.sender(format('select api.channel_claim_send(%L)', pg_temp.id('s2a')));
select pg_temp.sender(format('select api.channel_fail_send(%L, %L, %L, null)', pg_temp.id('s2a'), 'retriable', 'http_500'));
update app.send_requests set next_attempt_at = now() - interval '1 second' where id = pg_temp.id('s2a');
select pg_temp.sender(format('select api.channel_claim_send(%L)', pg_temp.id('s2a')));
select pg_temp.sender(format('select api.channel_fail_send(%L, %L, %L, null)', pg_temp.id('s2a'), 'retriable', 'http_500'));
select is(pg_temp.state(pg_temp.id('s2a')) || ':' || (select attempts from app.send_requests where id = pg_temp.id('s2a')),
          'failed:failed:3', 'after the third attempt it stops: failed, for the seller to decide');
select ok(not pg_temp.id('s2a') = any (pg_temp.due()), 'a failed send is never selected again');

-- ---- Unknown outcomes are never selected ----------------------------------------------------------------------------
insert into ids values ('s2b', pg_temp.send('v2', 'timeout please'));
select pg_temp.sender(format('select api.channel_claim_send(%L)', pg_temp.id('s2b')));
select pg_temp.sender(format('select api.channel_fail_send(%L, %L, %L, null)', pg_temp.id('s2b'), 'unknown', 'timeout'));
select is(pg_temp.state(pg_temp.id('s2b')), 'unknown:unknown', 'a timeout after submission is unknown');
select ok(not pg_temp.id('s2b') = any (pg_temp.due()), '… and never selected (no blind resend)');

-- ---- Per-recipient pacing (WhatsApp-style) ----------------------------------------------------------------------------
insert into ids values ('s3a', pg_temp.send('v3', 'one')), ('s3b', pg_temp.send('v3', 'two'));
select pg_temp.sender(format('select api.channel_claim_send(%L)', pg_temp.id('s3a')));
select pg_temp.sender(format('select api.channel_complete_send(%L, %L, %L)', pg_temp.id('s3a'), 'pm-3',
                             (select text_sha256 from app.send_requests where id = pg_temp.id('s3a'))));
select ok(not pg_temp.id('s3b') = any (pg_temp.due()), 'the next send to the same customer waits the provider''s pacing interval');
update app.send_requests set updated_at = now() - interval '7 seconds' where id = pg_temp.id('s3a');
select ok(pg_temp.id('s3b') = any (pg_temp.due()), '… and goes once it has passed');

-- ---- Fairness across connections --------------------------------------------------------------------------------------
-- Ten conversations on connection 1, one on connection 2: connection 2 is not starved.
insert into app.contacts (store_id, connection_id, external_user_id)
select pg_temp.id('store_a'), pg_temp.id('c1'), 'bulk-' || n from generate_series(1, 10) n;
insert into app.conversations (store_id, source, connection_id, contact_id, customer_label)
select pg_temp.id('store_a'), 'live', pg_temp.id('c1'), k.id, 'bulk' from app.contacts k where k.external_user_id like 'bulk-%';
update app.contacts set window_expires_at = now() + interval '1 day' where connection_id = pg_temp.id('c1');
insert into ids select 'bulk' || row_number() over (order by c.id), c.id from app.conversations c where c.customer_label = 'bulk';
select pg_temp.send('bulk' || n, 'promo ' || n) from generate_series(1, 10) n;
insert into ids values ('s2c', pg_temp.send('v2', 'for connection 2'));
select ok(pg_temp.id('s2c') = any (pg_temp.due(3)), 'with a small batch, the quiet connection still gets its turn (round robin)');
select is((select count(*)::integer from unnest(pg_temp.due()) x join app.send_requests s on s.id = x where s.connection_id = pg_temp.id('c1')),
          (select value from app.ai_limits where name = 'channel_sends_per_connection_per_cycle')::integer,
          'one busy connection gets at most its per-cycle share');

-- ---- Suspended provider ------------------------------------------------------------------------------------------------
update app.providers set status = 'suspended' where id = 'wk';
select is((select count(*)::integer from unnest(pg_temp.due()) x join app.send_requests s on s.id = x
             join app.connections c on c.id = s.connection_id where c.provider_id = 'wk'), 0,
          'a suspended provider''s sends wait (none of its sends is selected)');

select * from finish();
rollback;
