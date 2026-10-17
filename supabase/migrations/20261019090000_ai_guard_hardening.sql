-- Aisellia — Phase 8.5: stronger checks on AI replies, spending brakes, current prices.
--
-- A deterministic red-team of app.reply_guard (supabase/tests/database/16_ai_guard_redteam.test.sql)
-- found 19 of 30 unsafe phrasings it let through, for example "Delivery is free for you", "It will
-- arrive in 2 days", "Your order is placed!", "طلبك مؤكد" and "بەخۆڕایی دەیگەیەنین". Fixes:
--   * Structural: a number written by the model must be one the store's catalog or the customer's
--     own messages contain (sizes, options, quantities); anything else (a price, a day count, a stock
--     count) is "unverified_number" and only the holding reply is offered. Prices, fees, stock and
--     delivery times reach the customer only as server-rendered facts.
--   * Lexical, widened in English, Sorani and Arabic: free / cheaper / half price / buy-one-get-one,
--     delivery-time words (days, hours, weekdays, next week, arrive), and order-state claims
--     (placed, booked, all set, on the way, confirmed / مؤكد / تۆمارکرا).
--   * Spending brakes: requests stop when the estimated cost of the last 24 hours reaches a per-store
--     or a total limit (app.ai_limits; operators set them, the app cannot).
--   * Prices for the models AD-07 may choose between (fetched from the Anthropic pricing page,
--     2026-10-17), and the 1.1x multiplier for US-only inference.

insert into app.ai_limits (name, value) values
  ('assist_daily_cost_micro_usd_per_store', 2000000),   -- USD 2 per store per rolling day
  ('assist_daily_cost_micro_usd_total', 20000000);      -- USD 20 across all stores per rolling day

insert into app.ai_model_prices (model, input_micro, output_micro, cache_read_micro, cache_write_micro) values
  ('claude-sonnet-5-5', 2000000, 10000000, 100000, 2500000),
  ('claude-haiku-5-5', 100000, 500000, 10000, 125000)
on conflict (model) do update set input_micro = excluded.input_micro, output_micro = excluded.output_micro,
  cache_read_micro = excluded.cache_read_micro, cache_write_micro = excluded.cache_write_micro, updated_at = now();
update app.ai_model_prices set updated_at = now() where model = 'claude-opus-5-5';

-- ---------------------------------------------------------------------------------------------
-- Lexical guard, widened (categories unchanged: money, stock_count, discount, promise, claim).
-- ---------------------------------------------------------------------------------------------
create or replace function app.reply_guard(p_text text)
returns text[] language sql immutable
as $$
  select array_remove(array[
    case when t ~ ('[0-9]{1,3}([,.،٬][0-9]{3})+|[0-9]{4,}|[0-9]+\s*k\M|\$|\m(iqd|usd|dinars?|dollars?|thousand|hundred)\M'
                   || '|د\.ع|دینار|دينار|دۆلار|دولار|هەزار|سەد|\mألف\M|\mآلاف\M|\mمئة\M|\mمائة\M')
         then 'money' end,
    case when t ~ ('[0-9]+\s*(pcs|pieces|units|items|left|in stock|دانە|دانه|قطعة|قطع)'
                   || '|\m(only|last)\s+[0-9a-z]+\s+(left|remaining|pieces)|\mlast\s+(one|piece|few)\M')
         then 'stock_count' end,
    case when t ~ ('\m(discount|discounted|free|cheaper|cheapest|half price|half-price|bogo|bargain|special offer|promo|promotion|coupon|sale price)\M'
                   || '|buy\s+one|[0-9]+\s*%|\m[0-9]+\s*off\M'
                   || '|خصم|تخفيض|مجان|مجاناً|مجانا|نصف\s+السعر|عرض\s+خاص|أرخص|ارخص'
                   || '|داشکاندن|داشکان|بەخۆڕایی|بێ\s*بەرامبەر|نیوەی\s+نرخ|هەرزانتر|ئۆفەر')
         then 'discount' end,
    case when t ~ ('\m(tomorrow|today|tonight|guarantee|guaranteed|arrive|arrives|arriving|same.day|next\s+week|this\s+week)\M'
                   || '|\m(within|in|by)\s+([0-9]+|one|two|three|a\s+few|a\s+couple\s+of)\s+(days?|hours?|weeks?)\M'
                   || '|\m[0-9]+\s*(days?|hours?|weeks?|hrs?)\M'
                   || '|\m(by|on|before)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\M'
                   || '|سبەینێ|سبەی|ئەمڕۆ|ئەمشەو|ڕۆژ(ی|ێک|ێ)?(\s|$)|کاتژمێر|هەفتە|دەگات|دەگەیەنرێت|گەرەنتی'
                   || '|غداً|غدا|اليوم|الليلة|خلال\s+([0-9]+|يوم|يومين|أيام|ايام|ساعة|ساعات|أسبوع)|يومين|أيام|ايام|ساعات|أسبوع|اسبوع|سيصل|يصل|ستصل|ضمان|مضمون')
         then 'promise' end,
    case when t ~ ('\m(confirmed|approved|shipped|dispatched|booked|reserved)\M|\m(been|was|were|is|are)\s+delivered\M'
                   || '|\m(has|have|was|were|been|is|are)\s+(sent|placed|created|booked|registered|reserved|confirmed|processed|accepted)\M'
                   || '|\m(we|i)\s+(have\s+|''ve\s+)?(sent|shipped|created|booked|registered|placed|added|reserved|processed|accepted)\M'
                   || '|on\s+its\s+way|\mall\s+set\M|order\s+is\s+(placed|ready|done|complete|in)\M'
                   || '|پشتڕاست\s*کرایەوە|پشتڕاستکرایەوە|پەسەند\s*کرا|نێردرا|ناردمان|ناردرا|تۆمار\s*کرا|تۆمارکرا|داواکارییەکەت\s+ئامادەیە|دەینێرین|دەنێردرێت'
                   || '|تم\s+تأكيد|تم\s+التأكيد|تمت\s+الموافقة|تم\s+إرسال|تم\s+الإرسال|تم\s+شحن|تم\s+تسجيل|تم\s+استلام'
                   || '|سيتم\s+شحن|سيتم\s+إرسال|مؤكد|تأكد\s+طلبك|طلبك\s+جاهز')
         then 'claim' end], null)
  from (select lower(app.western_digits(coalesce(p_text, ''))) as t) x;
$$;

-- ---------------------------------------------------------------------------------------------
-- Structural number check: the only numbers the model may write are ones the store's catalog
-- (names, sizes, options, SKUs) or the customer's own messages in this run contain (≤ 3 digits).
-- ---------------------------------------------------------------------------------------------
create function app.reply_number_check(p_run app.ai_runs, p_text text)
returns text[]
language plpgsql stable
as $$
declare
  v_used text[];
  v_allowed text[];
begin
  select coalesce(array_agg(distinct ltrim(m[1], '0')), '{}') into v_used
    from regexp_matches(app.western_digits(regexp_replace(coalesce(p_text, ''), '\[(PHONE|EMAIL)_[0-9]+\]', '', 'g')),
                        '([0-9]+)', 'g') m;
  if cardinality(v_used) = 0 then
    return '{}';
  end if;
  select coalesce(array_agg(distinct ltrim(m[1], '0')), '{}') into v_allowed from (
    select regexp_matches(app.western_digits(p.name || ' ' || v.label || ' ' || coalesce(v.sku, '') || ' '
                                             || array_to_string(v.option_values, ' ')), '([0-9]+)', 'g') m
      from app.products p join app.product_variants v on v.product_id = p.id
     where p.store_id = p_run.store_id and p.status = 'active' and v.status = 'active'
    union all
    select regexp_matches(app.western_digits(regexp_replace(coalesce(msg.body, ''), '(\+|00)?[0-9٠-٩۰-۹][0-9٠-٩۰-۹\s-]{8,}', '', 'g')),
                          '(?:^|[^0-9])([0-9]{1,3})(?![0-9])', 'g')
      from app.messages msg
     where msg.id = any (p_run.input_message_ids) and msg.direction = 'in'
  ) s;
  if exists (select 1 from unnest(v_used) u where u <> '' and not (u = any (v_allowed))) then
    return array['unverified_number'];
  end if;
  return '{}';
end;
$$;

create or replace function app.ai_render(p_run app.ai_runs, p_segments jsonb, p_lang text)
returns jsonb
language plpgsql stable
as $$
declare
  v_s jsonb;
  v_r jsonb;
  v_text text := '';
  v_facts jsonb := '[]'::jsonb;
  v_flags text[] := '{}';
begin
  for v_s in select * from jsonb_array_elements(coalesce(p_segments, '[]')) loop
    if v_s ? 'text' then
      v_flags := v_flags || app.reply_guard(v_s ->> 'text') || app.reply_number_check(p_run, v_s ->> 'text');
      v_text := v_text || (v_s ->> 'text');
    else
      v_r := app.ai_render_fact(p_run, v_s ->> 'fact', v_s ->> 'ref', p_lang);
      if v_r is null then
        v_flags := v_flags || 'invalid_reference'::text;
      else
        v_text := v_text || (v_r ->> 'text');
        v_facts := v_facts || jsonb_build_object('fact', v_s ->> 'fact', 'ref', v_s ->> 'ref', 'label', v_r ->> 'label',
                                                 'value', v_r ->> 'text');
      end if;
    end if;
  end loop;
  -- Tokens never reach the seller as text; the customer's number is theirs to write.
  if v_text ~ '\[(PHONE|EMAIL)_[0-9]+\]' then
    v_flags := v_flags || 'pii_token'::text;
  end if;
  return jsonb_build_object('text', btrim(v_text), 'facts', v_facts,
                            'flags', to_jsonb(array(select distinct f from unnest(v_flags) f order by f)));
end;
$$;

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

  -- Spending brakes (estimated cost of the last 24 hours, from the server-side price table).
  if (select coalesce(sum(cost_micro_usd), 0) from app.ai_runs
       where store_id = p_store_id and created_at > now() - interval '24 hours')
     >= app.ai_limit('assist_daily_cost_micro_usd_per_store') then
    perform app.fail('RATE_LIMITED', jsonb_build_object('scope', 'budget_store', 'retry_after_seconds', 3600));
  end if;
  if (select coalesce(sum(cost_micro_usd), 0) from app.ai_runs where created_at > now() - interval '24 hours')
     >= app.ai_limit('assist_daily_cost_micro_usd_total') then
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

create or replace function app.ai_record_meta(p_run_id uuid, p_meta jsonb)
returns void
language plpgsql
as $$
declare
  v_price app.ai_model_prices;
  v_in integer := greatest(coalesce((p_meta #>> '{usage,input_tokens}')::integer, 0), 0);
  v_out integer := greatest(coalesce((p_meta #>> '{usage,output_tokens}')::integer, 0), 0);
  v_cr integer := greatest(coalesce((p_meta #>> '{usage,cache_read_input_tokens}')::integer, 0), 0);
  v_cw integer := greatest(coalesce((p_meta #>> '{usage,cache_creation_input_tokens}')::integer, 0), 0);
begin
  select * into v_price from app.ai_model_prices where model = p_meta ->> 'model';
  update app.ai_runs set
    model = left(p_meta ->> 'model', 80), served_model = left(p_meta ->> 'served_model', 80),
    prompt_version = left(p_meta ->> 'prompt_version', 40), effort = left(p_meta ->> 'effort', 20),
    stop_reason = left(p_meta ->> 'stop_reason', 40), provider_request_id = left(p_meta ->> 'request_id', 120),
    correlation_id = left(p_meta ->> 'correlation_id', 80),
    attempts = least(greatest(coalesce((p_meta ->> 'attempts')::integer, 1), 0), 10),
    latency_ms = least(greatest(coalesce((p_meta ->> 'latency_ms')::integer, 0), 0), 600000),
    input_tokens = v_in, output_tokens = v_out, cache_read_tokens = v_cr, cache_write_tokens = v_cw,
    -- US-only inference is billed at 1.1x (Anthropic pricing, data residency).
    cost_micro_usd = case when v_price.model is null then null
                          else (v_in::numeric * v_price.input_micro + v_out::numeric * v_price.output_micro
                                + v_cr::numeric * v_price.cache_read_micro + v_cw::numeric * v_price.cache_write_micro)
                               / 1000000 * case when p_meta ->> 'inference_geo' = 'us' then 1.1 else 1 end end
  where id = p_run_id;
end;
$$;

revoke all on function app.reply_number_check(app.ai_runs, text) from public, anon, authenticated, aisellia_ai, aisellia_ai_worker;
