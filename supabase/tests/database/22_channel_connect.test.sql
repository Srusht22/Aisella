-- Phase 9: connecting and disconnecting per-bot channels (Telegram, Viber).
--   * the connector login role: no attributes, exactly two functions, no tables, and no other role
--     (AI roles included) can redeem a nonce;
--   * only a store manager can start a connection, only for a released bot provider, rate-limited;
--   * a nonce is single-use, expires, and binds the connection to the seller's store;
--   * the account id is the one the provider reported; another store's bot cannot be taken over;
--   * disconnecting deletes the Vault secrets and cancels queued sends; account deletion removes
--     connect requests and both secrets.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(27);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;
grant aisellia_channel_connector to postgres with set true, inherit false; -- rolled back
create function pg_temp.connector(p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  set local role aisellia_channel_connector;
  execute p_sql into v;
  perform pg_temp.act_as_admin();
  return v;
end $$;
create function pg_temp.register(p_nonce text, p_provider text, p_account text) returns jsonb language sql as $$
  select pg_temp.connector(format('select api.channel_register_bot(%L, %L, %L, %L, %L, %L)', p_nonce, p_provider, p_account,
                                  'Shop Bot', 'bot-token-' || repeat('x', 30), 'webhook_secret_' || repeat('y', 40)))
$$;

-- ---- The connector role -------------------------------------------------------------------------------------------
select is((select row(rolcanlogin, rolinherit, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication)::text
             from pg_roles where rolname = 'aisellia_channel_connector'),
          row(true, false, false, false, false, false, false)::text, 'the connector role can log in, inherits nothing, has no attributes');
select is((select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('api', 'app', 'internal') and has_function_privilege('aisellia_channel_connector', p.oid, 'EXECUTE')),
          array['api.channel_finish_connect(text,boolean)', 'api.channel_register_bot(text,text,text,text,text,text)'],
          'the connector role can execute exactly the two nonce-redeeming functions');
select is((select count(*)::integer from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.relkind in ('r', 'v', 'm', 'p', 'f') and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_t%'
              and has_schema_privilege('aisellia_channel_connector', n.oid, 'USAGE')
              and (has_table_privilege('aisellia_channel_connector', c.oid, 'SELECT') or has_table_privilege('aisellia_channel_connector', c.oid, 'INSERT')
                   or has_table_privilege('aisellia_channel_connector', c.oid, 'UPDATE') or has_table_privilege('aisellia_channel_connector', c.oid, 'DELETE'))),
          0, 'the connector role reaches no table or view (not even vault)');
select is((select array_agg(r order by r) from unnest(array['anon', 'authenticated', 'service_role', 'aisellia_ai', 'aisellia_ai_worker',
                                                            'aisellia_channel_ingest', 'aisellia_channel_sender']) r
            where has_function_privilege(r, 'api.channel_register_bot(text,text,text,text,text,text)', 'EXECUTE')
               or has_function_privilege(r, 'api.channel_finish_connect(text,boolean)', 'EXECUTE')),
          null, 'no other role (AI roles included) can redeem a connect nonce');
select is((select array_agg(r order by r) from unnest(array['anon', 'aisellia_ai', 'aisellia_ai_worker', 'aisellia_channel_ingest',
                                                            'aisellia_channel_sender', 'aisellia_channel_connector']) r
            where has_function_privilege(r, 'api.begin_channel_connect(uuid,text)', 'EXECUTE')
               or has_function_privilege(r, 'api.disconnect_channel(uuid,uuid)', 'EXECUTE')),
          null, 'only signed-in users can start or end a connection');

-- ---- Fixtures --------------------------------------------------------------------------------------------------------
insert into ids values ('a', pg_temp.new_user('con-a@example.test')), ('b', pg_temp.new_user('con-b@example.test')),
                       ('staff', pg_temp.new_user('con-staff@example.test'));
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Shop B', '+9647701234567', 'IQD', 'en', 'Duhok', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as_admin();
insert into app.store_members (store_id, user_id, role, status, permissions)
values (pg_temp.id('store_a'), pg_temp.id('staff'), 'staff', 'active', '{"messages.send": true}');
insert into app.providers (id, display_name, status, webhook_scheme, payload_format) values
  ('fx_tg', 'Released bot fixture', 'pilot', 'telegram_token', 'telegram_bot');
insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('fx_tg', 'outbound_text', 'true', 'verified', 'https://fixture.invalid', current_date),
  ('fx_tg', 'reply_window_hours', 'null', 'verified', 'https://fixture.invalid', current_date);

-- ---- Starting ----------------------------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.id('staff'));
select is(api.begin_channel_connect(pg_temp.id('store_a'), 'fx_tg') #>> '{error,code}', 'FORBIDDEN',
          'staff without settings.manage cannot connect a channel');
select pg_temp.act_as(pg_temp.id('b'));
select is(api.begin_channel_connect(pg_temp.id('store_a'), 'fx_tg') #>> '{error,code}', 'NOT_FOUND', 'another store''s owner cannot either');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.begin_channel_connect(pg_temp.id('store_a'), 'telegram') #>> '{error,code}', 'CHANNEL_UNAVAILABLE',
          'a provider still in development cannot be connected by a seller');
select is(api.begin_channel_connect(pg_temp.id('store_a'), 'instagram') #>> '{error,code}', 'VALIDATION_FAILED',
          'OAuth providers have no bot-token connect');
insert into res select 'n1', api.begin_channel_connect(pg_temp.id('store_a'), 'fx_tg');
select ok(pg_temp.r('n1') #>> '{data,nonce}' ~ '^[0-9a-f]{64}$', 'the owner receives a one-time nonce');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.connect_requests where nonce_sha256 = app.sha256_hex(pg_temp.r('n1') #>> '{data,nonce}')
             and not exists (select 1 from app.connect_requests x where x.nonce_sha256 = pg_temp.r('n1') #>> '{data,nonce}')), 1,
          'only the nonce''s hash is stored');

-- ---- Redeeming ---------------------------------------------------------------------------------------------------------
select is(pg_temp.register(pg_temp.r('n1') #>> '{data,nonce}', 'fx_other', '5001') #>> '{error,code}', 'NOT_FOUND',
          'a nonce is bound to the provider it was issued for');
select is(pg_temp.register(repeat('0', 64), 'fx_tg', '5001') #>> '{error,code}', 'NOT_FOUND', 'an unknown nonce is refused');
insert into res select 'reg1', pg_temp.register(pg_temp.r('n1') #>> '{data,nonce}', 'fx_tg', '5001');
select is((select store_id from app.connections where id = (pg_temp.r('reg1') #>> '{data,connection_id}')::uuid), pg_temp.id('store_a'),
          'the connection is created in the store that issued the nonce');
select is((select state || ':' || credential_kind from app.connections where id = (pg_temp.r('reg1') #>> '{data,connection_id}')::uuid),
          'connecting:bot_token', '… as connecting until the webhook is registered');
select is(pg_temp.register(pg_temp.r('n1') #>> '{data,nonce}', 'fx_tg', '5002') #>> '{error,code}', 'NOT_FOUND', 'a nonce is redeemed once');
select is(pg_temp.connector(format('select api.channel_finish_connect(%L, true)', pg_temp.r('n1') #>> '{data,nonce}')) #>> '{data,connected}',
          'true', 'after the webhook registration the connection is connected');
select ok(exists (select 1 from app.audit_events where action = 'channel.connected' and store_id = pg_temp.id('store_a')
                   and after ->> 'requested_by' = pg_temp.id('a')::text), 'the connection is audited with the person who started it');

-- Another store cannot take the bot over.
select pg_temp.act_as(pg_temp.id('b'));
insert into res select 'n2', api.begin_channel_connect(pg_temp.id('store_b'), 'fx_tg');
select pg_temp.act_as_admin();
select is(pg_temp.register(pg_temp.r('n2') #>> '{data,nonce}', 'fx_tg', '5001') #>> '{error,code}', 'ACCOUNT_IN_USE',
          'a bot connected to one store cannot be connected to another');
-- A failed webhook registration leaves nothing behind.
insert into res select 'reg2', pg_temp.register(pg_temp.r('n2') #>> '{data,nonce}', 'fx_tg', '5003');
select pg_temp.act_as(pg_temp.id('b'));
insert into res select 'n3', api.begin_channel_connect(pg_temp.id('store_b'), 'fx_tg');
select pg_temp.act_as_admin();
insert into res select 'reg3', pg_temp.register(pg_temp.r('n3') #>> '{data,nonce}', 'fx_tg', '5003');
create temp table refs as select credential_ref, webhook_secret_ref from app.connections where id = (pg_temp.r('reg3') #>> '{data,connection_id}')::uuid;
select pg_temp.connector(format('select api.channel_finish_connect(%L, false)', pg_temp.r('n3') #>> '{data,nonce}'));
select is((select state from app.connections where id = (pg_temp.r('reg3') #>> '{data,connection_id}')::uuid), 'disconnected',
          'a connection whose webhook could not be registered is not left active');
select is((select count(*)::integer from vault.secrets where id in (select credential_ref from refs union all select webhook_secret_ref from refs)), 0,
          '… and its token and webhook secret are deleted');
update app.connect_requests set expires_at = now() - interval '1 minute' where nonce_sha256 = app.sha256_hex(pg_temp.r('n2') #>> '{data,nonce}');

-- ---- Disconnecting -----------------------------------------------------------------------------------------------------
insert into ids select 'conn', (pg_temp.r('reg1') #>> '{data,connection_id}')::uuid;
select internal.channel_store_events('fx_tg', 'u-1', pg_temp.id('conn')::text,
  '[{"kind": "message", "account_id": "5001", "external_user_id": "77", "external_message_id": "77:1", "text": "hi"}]', repeat('d', 64));
select internal.channel_process_batch();
insert into ids select 'conv', id from app.conversations where connection_id = pg_temp.id('conn');
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'queued', api.send_message(pg_temp.id('store_a'), pg_temp.id('conv'), 'still queued', null, null, null, gen_random_uuid());
select pg_temp.act_as_admin();
create temp table refs2 as select credential_ref, webhook_secret_ref from app.connections where id = pg_temp.id('conn');
select pg_temp.act_as(pg_temp.id('staff'));
select is(api.disconnect_channel(pg_temp.id('store_a'), pg_temp.id('conn')) #>> '{error,code}', 'FORBIDDEN', 'staff cannot disconnect');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.disconnect_channel(pg_temp.id('store_a'), pg_temp.id('conn')) #>> '{data,sends_cancelled}', '1',
          'the owner disconnects; the queued send is cancelled, never sent later');
select pg_temp.act_as_admin();
select is((select count(*)::integer from vault.secrets where id in (select credential_ref from refs2 union all select webhook_secret_ref from refs2)), 0,
          'the bot token and webhook secret are deleted from Vault');
select is((select state || ':' || coalesce(error_code, '') from app.send_requests where id = (pg_temp.r('queued') #>> '{data,send_request_id}')::uuid),
          'cancelled:disconnected', '… the send records why');

-- ---- Account deletion ----------------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.id('b'));
insert into res select 'n4', api.begin_channel_connect(pg_temp.id('store_b'), 'fx_tg');
select pg_temp.act_as_admin();
select pg_temp.register(pg_temp.r('n4') #>> '{data,nonce}', 'fx_tg', '5004');
select pg_temp.connector(format('select api.channel_finish_connect(%L, true)', pg_temp.r('n4') #>> '{data,nonce}'));
create temp table refs3 as select credential_ref, webhook_secret_ref from app.connections
 where store_id = pg_temp.id('store_b') and credential_ref is not null;
insert into app.account_deletion_requests (user_id, store_id, execute_after) values (pg_temp.id('b'), pg_temp.id('store_b'), now() - interval '1 minute');
select internal.purge_due_account_deletions();
select is((select count(*)::integer from app.connect_requests where store_id = pg_temp.id('store_b'))
          + (select count(*)::integer from vault.secrets where id in (select credential_ref from refs3 union all select webhook_secret_ref from refs3)),
          0, 'deleting an account removes its connect requests and both Vault secrets of every connection');
select ok((select count(*) from refs3) > 0, '… (the store had a connection with secrets to remove)');

select * from finish();
rollback;
