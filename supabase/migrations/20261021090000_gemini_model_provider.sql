-- Phase 9: Gemini as the primary AI model provider (owner decision, 2026-10-18).
-- Only the model-calling layer changed (supabase/functions/ai-assist/gemini_provider.ts). Every
-- database rule stays as it was: grounding, validation, the reply guard, drafts that wait for the
-- seller, tenant isolation, and the usage limits.
--
-- 1. Prices for the Gemini models AI_MODEL may name, in micro-USD per million tokens (the same unit
--    as the Claude rows). ASSUMPTION: the published standard tier for prompts up to 200k tokens; the
--    official pricing page could not be read from this environment, so they must be re-checked
--    before staging (docs/implementation/phase-9). Thinking tokens are billed as output, and cached
--    input at the cache rate; there is no cache-write charge for implicit caching.
-- 2. A model without a price no longer escapes the spending brakes: its runs are costed at the
--    highest price in the table instead of null (a null cost added nothing to the daily totals).

insert into app.ai_model_prices (model, input_micro, output_micro, cache_read_micro, cache_write_micro) values
  ('gemini-2.5-pro', 1250000, 10000000, 310000, 0),
  ('gemini-2.5-flash', 300000, 2500000, 75000, 0),
  ('gemini-2.5-flash-lite', 100000, 400000, 25000, 0)
on conflict (model) do update set input_micro = excluded.input_micro, output_micro = excluded.output_micro,
  cache_read_micro = excluded.cache_read_micro, cache_write_micro = excluded.cache_write_micro, updated_at = now();

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
  if v_price.model is null then
    -- Unknown model: costed at the most expensive known prices, never at nothing.
    select null::text, max(input_micro), max(output_micro), max(cache_read_micro), max(cache_write_micro), now()
      into v_price from app.ai_model_prices;
  end if;
  update app.ai_runs set
    model = left(p_meta ->> 'model', 80), served_model = left(p_meta ->> 'served_model', 80),
    prompt_version = left(p_meta ->> 'prompt_version', 40), effort = left(p_meta ->> 'effort', 20),
    stop_reason = left(p_meta ->> 'stop_reason', 40), provider_request_id = left(p_meta ->> 'request_id', 120),
    correlation_id = left(p_meta ->> 'correlation_id', 80),
    attempts = least(greatest(coalesce((p_meta ->> 'attempts')::integer, 1), 0), 10),
    latency_ms = least(greatest(coalesce((p_meta ->> 'latency_ms')::integer, 0), 0), 600000),
    input_tokens = v_in, output_tokens = v_out, cache_read_tokens = v_cr, cache_write_tokens = v_cw,
    -- US-only inference is billed at 1.1x (Anthropic pricing, data residency; Gemini reports none).
    cost_micro_usd = (v_in::numeric * v_price.input_micro + v_out::numeric * v_price.output_micro
                      + v_cr::numeric * v_price.cache_read_micro + v_cw::numeric * v_price.cache_write_micro)
                     / 1000000 * case when p_meta ->> 'inference_geo' = 'us' then 1.1 else 1 end
  where id = p_run_id;
end;
$$;
