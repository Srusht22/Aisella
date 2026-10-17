-- Scheduled retention jobs: idempotency keys (7 days, Phase 3 §6.4) and the AI request log.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(16);

create temp table ids (k text primary key, v uuid);
grant all on ids to public;
insert into ids values ('u', gen_random_uuid()), ('old', gen_random_uuid()), ('edge', gen_random_uuid()),
  ('new', gen_random_uuid());
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;

-- Keys 8 days, 6 days 23 hours and 1 minute old.
insert into app.idempotency_keys (user_id, key, operation, request_hash, response, created_at) values
  (pg_temp.id('u'), pg_temp.id('old'), 'test', 'h', '{"ok": true}', now() - interval '8 days'),
  (pg_temp.id('u'), pg_temp.id('edge'), 'test', 'h', '{"ok": true}', now() - interval '6 days 23 hours'),
  (pg_temp.id('u'), pg_temp.id('new'), 'test', 'h', '{"ok": true}', now() - interval '1 minute');

-- ---- Nobody but the scheduler (service_role) may run or read the jobs ------------------------------
select pg_temp.act_as(pg_temp.id('u'));
select throws_ok($$ select internal.purge_idempotency_keys() $$, '42501', null, 'a signed-in user cannot run the purge');
select throws_ok($$ select * from internal.job_health() $$, '42501', null, '… nor read job health');
select throws_ok($$ select * from app.job_runs $$, '42501', null, '… nor read the job log');
select pg_temp.act_as_anon();
select throws_ok($$ select internal.purge_idempotency_keys() $$, '42501', null, 'anon cannot run the purge');
select pg_temp.act_as_admin();
select ok(not has_function_privilege('aisellia_ai', 'internal.purge_idempotency_keys(interval)', 'EXECUTE'),
          'the AI role cannot run the purge');

-- ---- Safety -----------------------------------------------------------------------------------------
select is(internal.purge_idempotency_keys(interval '1 hour'), -1, 'a retention under one day is refused');
select is((select count(*)::integer from app.idempotency_keys where user_id = pg_temp.id('u')), 3, '… and deletes nothing');
select is((select status || ':' || (details ->> 'reason') from app.job_runs where job = 'purge_idempotency_keys'
            order by id desc limit 1), 'failed:retention_too_short', '… and the refusal is recorded');
select is((select stale from internal.job_health() where job = 'purge_idempotency_keys'), true,
          'job health reports the job as needing attention');

-- ---- The 7-day purge -----------------------------------------------------------------------------------
select cmp_ok(internal.purge_idempotency_keys(), '>=', 1, 'the purge deletes keys older than 7 days');
select is((select array_agg(key::text order by created_at) from app.idempotency_keys where user_id = pg_temp.id('u')),
          array[pg_temp.id('edge')::text, pg_temp.id('new')::text], 'only keys older than 7 days are gone');
select is((select row(status, affected >= 1, finished_at is not null)::text from app.job_runs
            where job = 'purge_idempotency_keys' order by id desc limit 1), row('ok', true, true)::text,
          'the run is recorded with its row count');
select is((select stale from internal.job_health() where job = 'purge_idempotency_keys'), false,
          'job health shows a recent successful run');

-- ---- AI request log ------------------------------------------------------------------------------------
insert into ids values ('seller', pg_temp.new_user('jobs@example.test'));
select pg_temp.act_as(pg_temp.id('seller'));
insert into ids select 'store', (api.create_store('Jobs Shop', '+9647501234567', 'IQD', 'ckb', 'Erbil',
                                                  gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'grant', (api.create_ai_draft_grant(pg_temp.id('store'), null, null, 1) #>> '{data,grant_id}')::uuid;
select pg_temp.act_as_admin();
insert into app.ai_requests (grant_id, store_id, outcome, created_at) values
  (pg_temp.id('grant'), pg_temp.id('store'), 'created', now() - interval '9 days'),
  (pg_temp.id('grant'), pg_temp.id('store'), 'updated', now() - interval '2 hours');
select cmp_ok(internal.purge_ai_request_log(), '>=', 1, 'the AI request-log purge runs');
select is((select array_agg(outcome) from app.ai_requests where grant_id = pg_temp.id('grant')), array['updated'],
          'AI requests older than 7 days are gone; recent ones stay');

-- ---- Scheduled ------------------------------------------------------------------------------------------
select is((select array_agg(jobname::text order by jobname) from cron.job
            where jobname in ('aisellia-purge-idempotency-keys', 'aisellia-purge-ai-request-log')),
          array['aisellia-purge-ai-request-log', 'aisellia-purge-idempotency-keys'], 'both jobs are scheduled daily');

select * from finish();
rollback;
