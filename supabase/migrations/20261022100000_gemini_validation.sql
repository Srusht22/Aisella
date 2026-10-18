-- Phase 9: Gemini validation (2026-10-18; docs/implementation/phase-9/provider-verification.md).
--  1. gemini-2.5-pro is no longer available to new projects (since 2026-09-18): the default model is
--     now gemini-3.8-flash (listed Stable). Its price is recorded at the 2027 standard rate
--     ($1.50 / $7.50 per 1M input / output tokens; the 2026 introductory rate is half), and cached
--     input at the input rate (the cache rate was not found): the brakes act early, never late.
--  2. Spending brakes cannot be bypassed by runs whose cost is not known yet. Every queued or running
--     run, and every run that expired after it may have reached the model, counts at a reserve
--     (assist_run_reserve_micro_usd), and a request must leave room for its own reserve. A provider
--     timeout (no usage reported, possibly billed) is charged the reserve.

insert into app.ai_model_prices (model, input_micro, output_micro, cache_read_micro, cache_write_micro) values
  ('gemini-3.8-flash', 1500000, 7500000, 1500000, 0),
  ('gemini-3.6-flash', 1500000, 7500000, 1500000, 0)
on conflict (model) do update set input_micro = excluded.input_micro, output_micro = excluded.output_micro,
  cache_read_micro = excluded.cache_read_micro, cache_write_micro = excluded.cache_write_micro, updated_at = now();

-- About the worst case of one run (two attempts of ~20k input and 8k output tokens at the price above).
insert into app.ai_limits (name, value) values ('assist_run_reserve_micro_usd', 150000) on conflict (name) do nothing;

-- Estimated spending of the last 24 hours for one store (or all stores with null).
create function app.ai_spent(p_store_id uuid)
returns bigint
language sql stable
as $$
  select coalesce(sum(coalesce(cost_micro_usd,
           case when status in ('queued', 'running') or (status = 'expired' and coalesce(error_code, '') <> 'not_claimed')
                then app.ai_limit('assist_run_reserve_micro_usd') else 0 end)), 0)::bigint
    from app.ai_runs
   where created_at > now() - interval '24 hours' and (p_store_id is null or store_id = p_store_id);
$$;
revoke all on function app.ai_spent(uuid) from public, anon, authenticated, aisellia_ai, aisellia_ai_worker,
  aisellia_channel_ingest, aisellia_channel_sender, aisellia_channel_connector;

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
  -- A timeout reports no usage, yet the provider may have billed the generation: charge the reserve.
  if p_status = 'timeout' then
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
