-- Phase 10: spending brakes, after the Gemini verification (docs/implementation/phase-10/gemini-readiness.md).
--  1. The all-stores daily cap could be overshot by concurrent requests of DIFFERENT stores: each
--     locked only its own store row, so both read the total before either was counted. The total
--     check is now serialised by a transaction-scoped advisory lock (regression test:
--     ai-assist/tests/budget_race_local_test.ts).
--  2. Failures whose cost is unknown are charged the reserve, not only timeouts (a connection lost
--     after sending, an unreadable 2xx answer, an unexpected error). Google documents that requests
--     failing with an HTTP 400 or 500 error are not charged; those stay at their reported usage.

create or replace function api.request_ai_assist(p_store_id uuid, p_conversation_id uuid, p_mode text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_store app.stores;
  v_conv app.conversations;
  v_run app.ai_runs;
  v_count integer;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  if coalesce(p_mode, 'reply') not in ('reply', 'draft') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"mode": "invalid"}}');
  end if;
  if p_idempotency_key is null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"idempotency_key": "required"}}');
  end if;
  -- A retry with the same key gets the same run (Phase 3 §6.4: "a retry replays").
  select * into v_run from app.ai_runs where requested_by = v_uid and idempotency_key = p_idempotency_key;
  if found then
    if v_run.store_id <> p_store_id or v_run.conversation_id <> p_conversation_id or v_run.mode <> coalesce(p_mode, 'reply') then
      perform app.fail('IDEMPOTENCY_KEY_REUSED');
    end if;
    return app.ok(jsonb_build_object('run_id', v_run.id, 'status', v_run.status, 'replayed', true));
  end if;

  select * into v_store from app.stores where id = p_store_id for update;   -- serialises the quota per store
  if not v_store.ai_enabled or v_store.deletion_requested_at is not null then
    perform app.fail('AI_DISABLED');
  end if;
  v_conv := app.lock_conversation(p_store_id, p_conversation_id);
  -- Live customer conversations get no AI until the store explicitly opts in (Phase 9 condition 2).
  if v_conv.connection_id is not null and not v_store.ai_live_enabled then
    perform app.fail('AI_DISABLED', '{"reason": "live_not_enabled"}');
  end if;
  if v_conv.ai_paused then
    perform app.fail('AI_PAUSED');
  end if;
  if not exists (select 1 from app.messages where conversation_id = v_conv.id and direction = 'in' and body is not null) then
    perform app.fail('NOTHING_TO_ANSWER');
  end if;
  -- One run at a time per conversation; a stuck one expires.
  update app.ai_runs set status = 'expired', finished_at = now(), pii_map = null, error_code = 'stale'
   where conversation_id = v_conv.id and status in ('queued', 'running')
     and created_at < now() - make_interval(secs => app.ai_limit('assist_run_seconds'));
  select * into v_run from app.ai_runs where conversation_id = v_conv.id and status in ('queued', 'running') limit 1;
  if found then
    perform app.fail('AI_BUSY', jsonb_build_object('run_id', v_run.id));
  end if;
  select count(*) into v_count from app.ai_runs where store_id = p_store_id and created_at > now() - interval '10 minutes';
  if v_count >= app.ai_limit('assist_calls_per_store_per_10min') then
    perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'store_10min', 'retry_after_seconds', 600,
                                                        'limit', app.ai_limit('assist_calls_per_store_per_10min')));
  end if;
  select count(*) into v_count from app.ai_runs where store_id = p_store_id and created_at > now() - interval '24 hours';
  if v_count >= app.ai_limit('assist_calls_per_store_per_day') then
    perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'store_day', 'retry_after_seconds', 3600,
                                                        'limit', app.ai_limit('assist_calls_per_store_per_day')));
  end if;

  -- Spending brakes: what the last 24 hours cost, counting every run whose cost is not known yet
  -- (in flight, or ended without usage) at the reserve, plus this run's own reserve. Parallel
  -- requests therefore cannot together overshoot a cap.
  if app.ai_spent(p_store_id) + app.ai_limit('assist_run_reserve_micro_usd')
     > app.ai_limit('assist_daily_cost_micro_usd_per_store') then
    perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'budget_store', 'retry_after_seconds', 3600));
  end if;
  -- The all-stores cap is shared: requests of different stores lock different store rows, so they
  -- are serialised here (until this transaction ends) to be counted one after the other.
  perform pg_advisory_xact_lock(hashtextextended('aisellia.ai_budget_total', 0));
  if app.ai_spent(null) + app.ai_limit('assist_run_reserve_micro_usd')
     > app.ai_limit('assist_daily_cost_micro_usd_total') then
    perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'budget_total', 'retry_after_seconds', 3600));
  end if;

  insert into app.ai_runs (store_id, conversation_id, requested_by, idempotency_key, mode, input_message_ids, last_message_seq)
  values (p_store_id, v_conv.id, v_uid, p_idempotency_key, coalesce(p_mode, 'reply'),
          coalesce((select array_agg(id) from (select id from app.messages where conversation_id = v_conv.id
                                                order by seq desc limit app.ai_limit('assist_context_messages')) m), '{}'),
          (select max(seq) from app.messages where conversation_id = v_conv.id))
  returning * into v_run;
  return app.ok(jsonb_build_object('run_id', v_run.id, 'status', v_run.status, 'replayed', false));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when unique_violation then
    return app.err('AI_BUSY', '{}'::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('request_ai_assist', v_state, v_code);
end;
$$;

create or replace function api.ai_fail_run(p_run_id uuid, p_status text, p_error_code text, p_meta jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_run app.ai_runs;
  v_code text;
  v_detail text;
  v_state text;
begin
  if coalesce(p_status, '') not in ('timeout', 'provider_error', 'refused', 'rate_limited', 'invalid_output') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"status": "invalid"}}');
  end if;
  v_run := app.ai_lock_running_run(p_run_id);
  perform app.ai_record_meta(v_run.id, coalesce(p_meta, '{}'::jsonb));
  -- Outcomes the provider may have billed without reporting usage are charged the reserve: a
  -- timeout, a connection lost after the request left, an unreadable 2xx answer, anything
  -- unexpected. Only errors the provider documents as unbilled (HTTP 4xx/5xx answers, rate
  -- limits, refusals before sending) are not (Gemini billing docs, checked 2026-10-18).
  if p_status = 'timeout'
     or (p_status = 'provider_error'
         and coalesce(p_error_code, '') not in ('auth', 'bad_request', 'model_not_found', 'overloaded', 'server_error',
                                                'no_api_key', 'bad_model')
         and coalesce(p_error_code, '') !~ '^http_[0-9]{3}$') then
    update app.ai_runs set cost_micro_usd = greatest(coalesce(cost_micro_usd, 0), app.ai_limit('assist_run_reserve_micro_usd'))
     where id = v_run.id;
  end if;
  update app.ai_runs set status = p_status, finished_at = now(), pii_map = null,
                         error_code = left(regexp_replace(coalesce(p_error_code, p_status), '[^a-z0-9_]', '', 'g'), 60)
   where id = v_run.id;
  -- A provider refusal is an escalation: the seller answers (Phase 3 AI §8.1).
  if p_status = 'refused' then
    update app.conversations
       set status = 'needs_you',
           escalation_reasons = array(select distinct x from unnest(escalation_reasons || 'out_of_scope'::text) x order by x),
           updated_at = now(), version = version + 1
     where id = v_run.conversation_id;
  end if;
  return app.ok(jsonb_build_object('run_id', v_run.id, 'status', p_status));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('ai_fail_run', v_state, v_code);
end;
$$;
