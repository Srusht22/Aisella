-- Aisellia — scheduled maintenance: idempotency-key and AI request-log retention, made observable.
--
-- Phase 3 backend-and-data-model.md §4.5 / §6.4: idempotency keys are purged after 7 days. Until
-- now nothing did. Rules:
--   * Only rows older than the retention are deleted; a retention under 1 day is refused (a
--     mistyped interval cannot wipe keys that protect in-flight retries).
--   * Every run is recorded in app.job_runs (started, finished, status, rows affected; never data).
--   * A failure is recorded and reported as a warning; it never raises into pg_cron silently.
--   * internal.job_health() tells operators the last outcome of every job and whether it is stale.
-- After a key is purged, a request reusing it is processed as new. Clients use one key per
-- in-flight intent (seconds to minutes), so 7 days leaves a wide margin; status guards still prevent
-- a second approval, cancellation or stock movement.

create table app.job_runs (
  id          bigint generated always as identity primary key,
  job         text not null check (char_length(job) between 1 and 60),
  started_at  timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  status      text not null default 'running' check (status in ('running', 'ok', 'failed')),
  affected    integer,
  details     jsonb
);
create index job_runs_job on app.job_runs (job, started_at desc);
alter table app.job_runs enable row level security;
revoke all on app.job_runs from public, anon, authenticated;

create index idempotency_keys_created on app.idempotency_keys (created_at);

-- Shared runner: deletes rows of one retention-managed table older than p_older_than.
create function internal.run_retention(p_job text, p_older_than interval)
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_run bigint;
  v_count integer;
  v_state text;
begin
  if p_older_than is null or p_older_than < interval '1 day' then
    insert into app.job_runs (job, finished_at, status, affected, details)
    values (p_job, clock_timestamp(), 'failed', 0, jsonb_build_object('reason', 'retention_too_short'));
    raise warning 'job % refused: retention % is shorter than 1 day', p_job, p_older_than;
    return -1;
  end if;
  insert into app.job_runs (job) values (p_job) returning id into v_run;
  if p_job = 'purge_idempotency_keys' then
    delete from app.idempotency_keys where created_at < now() - p_older_than;
  elsif p_job = 'purge_ai_request_log' then
    delete from app.ai_requests where created_at < now() - p_older_than;
  else
    raise exception 'unknown retention job %', p_job;
  end if;
  get diagnostics v_count = row_count;
  update app.job_runs
     set finished_at = clock_timestamp(), status = 'ok', affected = v_count,
         details = jsonb_build_object('retention', p_older_than::text)
   where id = v_run;
  return v_count;
exception
  when others then
    get stacked diagnostics v_state = returned_sqlstate;
    -- The failed attempt was rolled back; record it (no data, only the SQL state).
    insert into app.job_runs (job, finished_at, status, details)
    values (p_job, clock_timestamp(), 'failed', jsonb_build_object('sqlstate', v_state));
    raise warning 'job % failed: sqlstate %', p_job, v_state;
    return -1;
end;
$$;

create function internal.purge_idempotency_keys(p_older_than interval default interval '7 days')
returns integer
language sql volatile security definer set search_path = ''
as $$ select internal.run_retention('purge_idempotency_keys', p_older_than) $$;

create function internal.purge_ai_request_log(p_older_than interval default interval '7 days')
returns integer
language sql volatile security definer set search_path = ''
as $$ select internal.run_retention('purge_ai_request_log', p_older_than) $$;

-- Last outcome of every scheduled job; stale = no successful run in the last 36 hours.
create function internal.job_health()
returns table (job text, last_started_at timestamptz, last_status text, last_affected integer,
               last_ok_at timestamptz, stale boolean)
language sql stable security definer set search_path = ''
as $$
  select j.job, l.started_at, l.status, l.affected, ok.finished_at,
         ok.finished_at is null or ok.finished_at < now() - interval '36 hours' or l.status = 'failed'
    from (values ('purge_idempotency_keys'), ('purge_ai_request_log')) j(job)
    left join lateral (select * from app.job_runs r where r.job = j.job order by r.id desc limit 1) l on true
    left join lateral (select * from app.job_runs r where r.job = j.job and r.status = 'ok'
                        order by r.id desc limit 1) ok on true;
$$;

revoke all on function internal.run_retention(text, interval), internal.purge_idempotency_keys(interval),
  internal.purge_ai_request_log(interval), internal.job_health()
from public, anon, authenticated, aisellia_ai;
grant execute on function internal.purge_idempotency_keys(interval), internal.purge_ai_request_log(interval),
  internal.job_health()
to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('aisellia-purge-idempotency-keys', '23 3 * * *',
                          'select internal.purge_idempotency_keys()');
    perform cron.schedule('aisellia-purge-ai-request-log', '29 3 * * *',
                          'select internal.purge_ai_request_log()');
  end if;
end $$;
