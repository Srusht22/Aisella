-- Aisellia — Phase 8: the AI sales assistant pipeline (suggested replies, escalation, AI drafts).
--
-- Phase 3 ai-integration-architecture.md, with the stronger boundary of the pre-Phase 8 hardening
-- (Phase 7 doc I) where the two differ:
--   * The seller asks for help (api.request_ai_assist, seller JWT): membership, the store's AI switch,
--     per-store quotas and idempotency are checked and a run is queued. Nothing else happens.
--   * The AI worker (the ai-assist Edge Function) talks to the database as its own LOGIN role,
--     `aisellia_ai_worker`, never with the seller's token and never with a JWT secret. Its ONLY
--     privileges are EXECUTE on api.ai_claim_run, api.ai_complete_run, api.ai_fail_run and
--     api.ai_run_state. It can claim a run a seller queued in the last minute, read the context
--     this database builds for that run (one store, by construction), and hand back the model's
--     output. It can't read a table, name a store, approve, reject, cancel or fulfil anything.
--   * The model proposes; this database decides (Phase 3 AI §1). ai_complete_run re-validates the
--     output: strict shape, references limited to the ids sent for this run, prices / fees / stock
--     / policies rendered from current records (never from model text), a guard against literal
--     prices, discounts, delivery promises and "confirmed / sent" claims, mandatory escalation, and a
--     lenient draft merge that never overwrites seller edits and can only produce `draft` or
--     `pending_approval`. Customer phone numbers never reach the provider: they are replaced by
--     tokens here and mapped back here.
--   * Every run is recorded in app.ai_runs with outcome, tokens and estimated cost (never the
--     phone map after the run ends); the seller sees suggestions labelled "not sent".

-- ---------------------------------------------------------------------------------------------
-- The AI worker role. LOGIN without a password: it can't connect until an operator sets one
-- (outside migrations, never committed).
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'aisellia_ai_worker') then
    create role aisellia_ai_worker login noinherit;
  end if;
end $$;
alter role aisellia_ai_worker login noinherit nocreatedb nocreaterole nobypassrls noreplication connection limit 20;
alter role aisellia_ai_worker set statement_timeout = '15s';
alter role aisellia_ai_worker set idle_in_transaction_session_timeout = '30s';
grant usage on schema api to aisellia_ai_worker;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------
insert into app.ai_limits (name, value) values
  ('assist_calls_per_store_per_10min', 30),
  ('assist_calls_per_store_per_day', 300),
  ('assist_claim_seconds', 60),
  ('assist_run_seconds', 120),
  ('assist_catalog_full_max_variants', 400),
  ('assist_catalog_candidates', 40),
  ('assist_context_messages', 20),
  ('assist_context_chars', 12000);

-- Server-side price table for the cost estimate (micro-USD per million tokens). Operators keep it
-- current; values from the Phase 3 cost estimate (verify before relying on them).
create table app.ai_model_prices (
  model             text primary key,
  input_micro       bigint not null check (input_micro >= 0),
  output_micro      bigint not null check (output_micro >= 0),
  cache_read_micro  bigint not null check (cache_read_micro >= 0),
  cache_write_micro bigint not null check (cache_write_micro >= 0),
  updated_at        timestamptz not null default now()
);
insert into app.ai_model_prices (model, input_micro, output_micro, cache_read_micro, cache_write_micro)
values ('claude-opus-5-5', 4000000, 20000000, 200000, 5000000);

create table app.ai_runs (
  id                  uuid primary key default gen_random_uuid(),
  store_id            uuid not null references app.stores (id),
  conversation_id     uuid not null,
  requested_by        uuid not null,
  idempotency_key     uuid not null,
  mode                text not null default 'reply' check (mode in ('reply', 'draft')),
  status              text not null default 'queued'
                        check (status in ('queued', 'running', 'succeeded', 'invalid_output', 'timeout', 'provider_error',
                                          'refused', 'rate_limited', 'expired', 'skipped')),
  error_code          text check (error_code is null or char_length(error_code) <= 60),
  input_message_ids   uuid[] not null default '{}',
  last_message_seq    bigint,
  context_ids         jsonb,
  pii_map             jsonb,
  model               text check (model is null or char_length(model) <= 80),
  served_model        text check (served_model is null or char_length(served_model) <= 80),
  prompt_version      text check (prompt_version is null or char_length(prompt_version) <= 40),
  effort              text check (effort is null or char_length(effort) <= 20),
  stop_reason         text check (stop_reason is null or char_length(stop_reason) <= 40),
  provider_request_id text check (provider_request_id is null or char_length(provider_request_id) <= 120),
  correlation_id      text check (correlation_id is null or char_length(correlation_id) <= 80),
  attempts            integer check (attempts is null or attempts between 0 and 10),
  latency_ms          integer check (latency_ms is null or latency_ms between 0 and 600000),
  input_tokens        integer check (input_tokens is null or input_tokens >= 0),
  output_tokens       integer check (output_tokens is null or output_tokens >= 0),
  cache_read_tokens   integer check (cache_read_tokens is null or cache_read_tokens >= 0),
  cache_write_tokens  integer check (cache_write_tokens is null or cache_write_tokens >= 0),
  cost_micro_usd      bigint check (cost_micro_usd is null or cost_micro_usd >= 0),
  validation_errors   jsonb,
  output_json         jsonb,
  created_at          timestamptz not null default clock_timestamp(),
  claimed_at          timestamptz,
  finished_at         timestamptz,
  unique (store_id, id),
  unique (requested_by, idempotency_key),
  foreign key (store_id, conversation_id) references app.conversations (store_id, id)
);
create index ai_runs_store_created on app.ai_runs (store_id, created_at desc);
create index ai_runs_conversation on app.ai_runs (conversation_id, created_at desc);
create index ai_runs_finished on app.ai_runs (finished_at) where output_json is not null;

create table app.reply_suggestions (
  id                 uuid primary key default gen_random_uuid(),
  store_id           uuid not null,
  conversation_id    uuid not null,
  ai_run_id          uuid not null,
  intent             text not null,
  reply_language     text not null check (reply_language in ('ckb', 'ar', 'en')),
  text_rendered      text check (text_rendered is null or char_length(text_rendered) between 1 and 4000),
  facts_used         jsonb not null default '[]'::jsonb,
  missing_fields     text[] not null default '{}',
  escalation_reasons text[] not null default '{}',
  conflicts          jsonb not null default '[]'::jsonb,
  flags              text[] not null default '{}',
  is_holding         boolean not null default false,
  status             text not null default 'suggested' check (status in ('suggested', 'copied', 'dismissed', 'superseded')),
  message_id         uuid,
  created_at         timestamptz not null default clock_timestamp(),
  updated_at         timestamptz not null default now(),
  unique (store_id, id),
  foreign key (store_id, conversation_id) references app.conversations (store_id, id),
  foreign key (store_id, ai_run_id) references app.ai_runs (store_id, id)
);
create index reply_suggestions_conversation on app.reply_suggestions (conversation_id, created_at desc);

alter table app.messages
  add constraint messages_suggestion_fk foreign key (store_id, suggestion_id) references app.reply_suggestions (store_id, id);
alter table app.conversations add column last_ai_seq bigint;
alter table app.order_items add column candidate_variant_ids uuid[] not null default '{}'
  check (cardinality(candidate_variant_ids) <= 3);

alter table app.ai_model_prices enable row level security;
alter table app.ai_runs enable row level security;
alter table app.reply_suggestions enable row level security;
revoke all on app.ai_model_prices, app.ai_runs, app.reply_suggestions from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- Text helpers: localised strings, money, phone normalisation and tokenisation
-- ---------------------------------------------------------------------------------------------
-- Fixed server texts per reply language (native review pending, Phase 2 DD-08).
create function app.ai_text(p_key text, p_lang text)
returns text language sql immutable
as $$
  select case p_key || ':' || coalesce(p_lang, 'en')
    when 'holding:en' then 'Thank you for your message. The owner will reply to you personally shortly.'
    when 'holding:ckb' then 'سوپاس بۆ نامەکەت. خاوەنی فرۆشگاکە بەم زووانە خۆی وەڵامت دەداتەوە.'
    when 'holding:ar' then 'شكراً لرسالتك. سيرد عليك صاحب المتجر شخصياً قريباً.'
    when 'in_stock:en' then 'available'
    when 'in_stock:ckb' then 'بەردەستە'
    when 'in_stock:ar' then 'متوفر'
    when 'low:en' then 'available, only a few left'
    when 'low:ckb' then 'بەردەستە، تەنها چەند دانەیەک ماوە'
    when 'low:ar' then 'متوفر، الكمية محدودة'
    when 'out:en' then 'out of stock'
    when 'out:ckb' then 'لە کۆگادا نەماوە'
    when 'out:ar' then 'غير متوفر حالياً'
    when 'unavailable:en' then 'not available'
    when 'unavailable:ckb' then 'بەردەست نییە'
    when 'unavailable:ar' then 'غير متوفر'
    when 'cod:en' then 'cash on delivery'
    when 'cod:ckb' then 'پارەدان لە کاتی گەیاندن'
    when 'cod:ar' then 'الدفع عند الاستلام'
    when 'other:en' then 'another payment method (the seller will explain)'
    when 'other:ckb' then 'ڕێگایەکی تری پارەدان (فرۆشیار ڕوونی دەکاتەوە)'
    when 'other:ar' then 'طريقة دفع أخرى (سيوضحها البائع)'
    when 'or:en' then ' or '
    when 'or:ckb' then ' یان '
    when 'or:ar' then ' أو '
  end;
$$;

-- "35,000 IQD" (en) / "35,000 د.ع" (ckb, ar) / "$25"; the same rules as the app (Phase 2 §07 §3).
create function app.format_money(p_amount bigint, p_currency text, p_lang text)
returns text language sql immutable
as $$
  select case when p_currency = 'USD' then '$' || to_char(p_amount, 'FM999,999,999,990')
              else to_char(p_amount, 'FM999,999,999,990') || case when p_lang = 'en' then ' IQD' else ' د.ع' end end;
$$;

-- Western digits for Arabic-Indic and Persian digits.
create function app.western_digits(p_text text)
returns text language sql immutable
as $$ select translate(p_text, '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789') $$;

-- An Iraqi mobile number in any common form (07…, +9647…, 009647…, spaces, dashes, Eastern
-- digits) as +9647XXXXXXXXX, or null (Phase 1 §8.7).
create function app.normalize_phone(p_text text)
returns text language sql immutable
as $$
  select case
    when d ~ '^009647[0-9]{9}$' then '+' || substr(d, 3)
    when d ~ '^9647[0-9]{9}$' then '+' || d
    when d ~ '^07[0-9]{9}$' then '+964' || substr(d, 2)
    when d ~ '^7[0-9]{9}$' then '+964' || d
  end
  from (select regexp_replace(app.western_digits(coalesce(p_text, '')), '[^0-9]', '', 'g') as d) x;
$$;

-- Replaces phone numbers and e-mail addresses with tokens ([PHONE_1], [EMAIL_1]) consistently
-- within one run. p_map carries the tokens assigned so far: {"PHONE_1": "+9647…", "EMAIL_1": "…"}.
create function app.pii_minimise(p_text text, p_map jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
  v_text text := coalesce(p_text, '');
  v_map jsonb := coalesce(p_map, '{}'::jsonb);
  v_match text;
  v_value text;
  v_token text;
begin
  for v_match in
    select distinct m[1] from regexp_matches(v_text,
      '((?:\+|00)?(?:[9٩۹][6٦۶][4٤۴][\s-]*)?[0٠۰]?[7٧۷](?:[\s-]*[0-9٠-٩۰-۹]){9})', 'g') m
  loop
    v_value := app.normalize_phone(v_match);
    if v_value is not null then
      select k into v_token from jsonb_each_text(v_map) e(k, v) where k like 'PHONE_%' and v = v_value;
      if v_token is null then
        v_token := 'PHONE_' || ((select count(*) from jsonb_object_keys(v_map) k where k like 'PHONE_%') + 1);
        v_map := v_map || jsonb_build_object(v_token, v_value);
      end if;
      v_text := replace(v_text, v_match, '[' || v_token || ']');
      v_token := null;
    end if;
  end loop;
  for v_match in select distinct m[1] from regexp_matches(v_text, '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})', 'g') m loop
    select k into v_token from jsonb_each_text(v_map) e(k, v) where k like 'EMAIL_%' and v = lower(v_match);
    if v_token is null then
      v_token := 'EMAIL_' || ((select count(*) from jsonb_object_keys(v_map) k where k like 'EMAIL_%') + 1);
      v_map := v_map || jsonb_build_object(v_token, lower(v_match));
    end if;
    v_text := replace(v_text, v_match, '[' || v_token || ']');
    v_token := null;
  end loop;
  return jsonb_build_object('text', v_text, 'map', v_map);
end;
$$;

-- Availability without exact counts (Phase 1 D-11): in_stock | low | out | available | unavailable.
create function app.variant_availability(p app.products, v app.product_variants)
returns text language sql immutable
as $$
  select case
    when p.status <> 'active' or v.status <> 'active' then 'unavailable'
    when not p.track_stock then case when v.available then 'available' else 'unavailable' end
    when v.stock_on_hand <= 0 then 'out'
    when v.stock_on_hand <= coalesce(v.low_stock_threshold, 2) then 'low'
    else 'in_stock' end;
$$;

-- Customer text that tries to steer the assistant (Phase 1 §8.5 "suspected manipulation").
-- Deterministic and deliberately broad: a false positive only means "Needs you".
create function app.looks_like_manipulation(p_text text)
returns boolean language sql immutable
as $$
  select lower(coalesce(p_text, '')) ~ (
    '(ignore|disregard|forget|override|bypass)\s+(all\s+|any\s+|your\s+|the\s+|previous\s+|prior\s+|above\s+)*(rules|instructions|prompts?|guidelines|restrictions)'
    || '|system\s*prompt|developer\s*mode|jailbreak|you\s+are\s+now\s|pretend\s+(to\s+be|you)|act\s+as\s+(the\s+)?(seller|owner|admin|system)'
    || '|reveal\s+(your|the)\s+(prompt|instructions|rules)'
    || '|(other|another|different)\s+(customers?|sellers?|stores?|shops?)(''s)?\s+(data|orders?|info|information|details|phones?|products?)'
    || '|approve\s+(it|this|the\s+order|my\s+order)\s+yourself|mark\s+(it|the\s+order|my\s+order)\s+(as\s+)?(approved|paid|confirmed)'
    || '|تجاهل\s+(كل\s+|جميع\s+)?(التعليمات|القواعد|الأوامر)|تعليمات\s+النظام|موجه\s+النظام|بيانات\s+(العملاء|الزبائن)\s+الآخرين'
    || '|(ڕێنماییەکان|یاساکان|فەرمانەکان|ڕێساکان)\s*(پشتگوێ|فەرامۆش)|زانیاریی\s+(کڕیارانی|فرۆشیارانی)\s+تر');
$$;

-- Literal claims a reply must not make outside rendered facts: prices or money, stock counts,
-- discounts, delivery promises, guarantees and "confirmed / sent / approved" (Phase 3 AI §8.5).
create function app.reply_guard(p_text text)
returns text[] language sql immutable
as $$
  select array_remove(array[
    case when t ~ '[0-9]{1,3}([,.،٬][0-9]{3})+|[0-9]{4,}|[0-9]+\s*k\M|\$|\m(iqd|usd|dinars?|dollars?|thousand)\M|د\.ع|دینار|دينار|دۆلار|دولار|هەزار|\mألف\M'
         then 'money' end,
    case when t ~ '[0-9]+\s*(pcs|pieces|units|items|left|in stock|دانە|دانه|قطعة|قطع)' then 'stock_count' end,
    case when t ~ '\m(discount|discounted|free shipping|free delivery)\M|[0-9]+\s*%|خصم|تخفيض|داشکاندن|داشکان' then 'discount' end,
    case when t ~ '\m(tomorrow|today|tonight|guarantee|guaranteed)\M|\mwithin\s+[0-9]+|سبەینێ|ئەمڕۆ|غداً|غدا|اليوم|خلال\s+[0-9]+|ضمان|گەرەنتی' then 'promise' end,
    case when t ~ ('\m(confirmed|approved|shipped|dispatched|delivered)\M|\m(has|have|was|were|been)\s+(sent|placed|created|booked|registered)\M|\m(we|i)\s+(have\s+)?(sent|shipped|created|booked|registered|placed)\M|on\s+its\s+way'
           || '|پشتڕاست\s*کرایەوە|پەسەند\s*کرا|نێردرا|ناردمان|ناردرا|تۆمار\s*کرا|تم\s+تأكيد|تم\s+التأكيد|تمت\s+الموافقة|تم\s+إرسال|تم\s+الإرسال|تم\s+شحن|تم\s+تسجيل')
         then 'claim' end], null)
  from (select lower(app.western_digits(coalesce(p_text, ''))) as t) x;
$$;

-- ---------------------------------------------------------------------------------------------
-- Context for one run (built here, so it can only ever contain this store's data)
-- ---------------------------------------------------------------------------------------------
create function app.ai_build_context(p_run app.ai_runs)
returns jsonb
language plpgsql stable
as $$
declare
  v_store app.stores;
  v_conv app.conversations;
  v_map jsonb := '{}'::jsonb;
  v_min jsonb;
  v_messages jsonb := '[]'::jsonb;
  v_m record;
  v_chars integer := 0;
  v_query text := '';
  v_variant_count integer;
  v_variant_ids uuid[];
  v_catalog jsonb;
  v_zones jsonb;
  v_policies jsonb;
  v_draft jsonb;
  v_order app.orders;
begin
  select * into v_store from app.stores where id = p_run.store_id;
  select * into v_conv from app.conversations where id = p_run.conversation_id;

  -- Recent messages, newest kept first within the budget, then shown oldest first.
  for v_m in
    select m.id, m.direction, m.origin, m.body
      from app.messages m
     where m.conversation_id = v_conv.id and m.body is not null
     order by m.seq desc limit app.ai_limit('assist_context_messages')
  loop
    exit when v_chars + char_length(v_m.body) > app.ai_limit('assist_context_chars') and v_chars > 0;
    v_min := app.pii_minimise(left(v_m.body, app.ai_limit('assist_context_chars')), v_map);
    v_map := v_min -> 'map';
    v_chars := v_chars + char_length(v_m.body);
    v_query := v_m.body || ' ' || v_query;
    v_messages := jsonb_build_object('id', v_m.id,
                                     'from', case when v_m.direction = 'in' then 'customer' else 'seller' end,
                                     'text', v_min ->> 'text') || '[]'::jsonb || v_messages;
  end loop;
  v_messages := (select coalesce(jsonb_agg(x order by o), '[]'::jsonb)
                   from jsonb_array_elements(v_messages) with ordinality e(x, o));

  -- Catalog: everything active when small; otherwise the best trigram matches plus draft lines.
  select count(*) into v_variant_count
    from app.product_variants v join app.products p on p.id = v.product_id
   where p.store_id = v_store.id and p.status = 'active' and v.status = 'active';
  if v_variant_count <= app.ai_limit('assist_catalog_full_max_variants') then
    select coalesce(array_agg(v.id), '{}') into v_variant_ids
      from app.product_variants v join app.products p on p.id = v.product_id
     where p.store_id = v_store.id and p.status = 'active' and v.status = 'active';
  else
    v_query := app.search_normalize(v_query);
    select coalesce(array_agg(id), '{}') into v_variant_ids from (
      select v.id
        from app.product_variants v join app.products p on p.id = v.product_id
       where p.store_id = v_store.id and p.status = 'active' and v.status = 'active'
       order by extensions.word_similarity(
                  app.search_normalize(p.name || ' ' || v.label || ' ' || coalesce(v.sku, '') || ' ' || coalesce(p.category, '')),
                  v_query) desc, p.updated_at desc
       limit app.ai_limit('assist_catalog_candidates')) s;
    v_variant_ids := v_variant_ids || coalesce((
      select array_agg(l.variant_id) from app.order_items l
       where l.order_id = v_conv.order_id and l.variant_id is not null), '{}');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id', p.id, 'name', p.name, 'category', p.category,
           'description', left(p.description, 400), 'option_types', to_jsonb(p.option_types),
           'variants', (select jsonb_agg(jsonb_build_object(
                                 'variant_id', v.id, 'label', nullif(v.label, ''), 'options', to_jsonb(v.option_values),
                                 'sku', v.sku, 'price', coalesce(v.price_override, p.base_price),
                                 'availability', app.variant_availability(p, v))
                               order by v.position, v.id)
                          from app.product_variants v where v.product_id = p.id and v.id = any (v_variant_ids)))
           order by p.name), '[]'::jsonb)
    into v_catalog
    from app.products p
   where p.store_id = v_store.id and exists (select 1 from app.product_variants v where v.product_id = p.id and v.id = any (v_variant_ids));

  select coalesce(jsonb_agg(jsonb_build_object('zone_id', z.id, 'name', z.name, 'has_time_text', z.time_text is not null)
                            order by z.sort, z.name), '[]'::jsonb)
    into v_zones from app.delivery_zones z where z.store_id = v_store.id and z.active;
  select coalesce(jsonb_agg(jsonb_build_object('policy_id', p.id, 'topic', p.topic, 'text', p.body) order by p.topic, p.created_at),
                  '[]'::jsonb)
    into v_policies from app.store_policies p where p.store_id = v_store.id and p.active;

  if v_conv.order_id is not null then
    select * into v_order from app.orders where id = v_conv.order_id;
    v_draft := jsonb_build_object(
      'status', v_order.status,
      'editable_by_ai', v_order.status in ('draft', 'pending_approval'),
      'fields_set', to_jsonb(array_remove(array[
         case when v_order.customer_name is not null then 'customer_name' end,
         case when v_order.customer_phone is not null then 'customer_phone' end,
         case when v_order.zone_id is not null or v_order.city_text is not null then 'zone' end,
         case when v_order.area is not null then 'area' end,
         case when v_order.landmark is not null then 'landmark' end,
         case when v_order.address_details is not null then 'address_details' end,
         case when v_order.payment_method is not null then 'payment_method' end], null)),
      'seller_edited', to_jsonb(v_order.seller_edited),
      'lines', coalesce((select jsonb_agg(jsonb_build_object('variant_id', l.variant_id, 'name', l.name_snapshot,
                                                            'variant_label', nullif(l.variant_label_snapshot, ''),
                                                            'quantity', l.quantity, 'resolution', l.resolution)
                                          order by l.position, l.id)
                           from app.order_items l where l.order_id = v_order.id), '[]'::jsonb),
      'issues', app.order_issues(v_order.id));
  end if;

  return jsonb_build_object(
    'context', jsonb_build_object(
      'store', jsonb_build_object('name', v_store.name, 'currency', v_store.currency,
                                  'default_reply_language', v_store.reply_locale,
                                  'payment_methods', to_jsonb(array_remove(array[
                                    case when v_store.cod_enabled then 'cod' end,
                                    case when v_store.other_payment_enabled then 'other' end], null))),
      'policies', v_policies,
      'zones', v_zones,
      'catalog', v_catalog,
      'catalog_is_partial', v_variant_count > app.ai_limit('assist_catalog_full_max_variants'),
      'conversation', jsonb_build_object('source', v_conv.source, 'is_sandbox', v_conv.is_sandbox, 'messages', v_messages),
      'draft', v_draft,
      'state', jsonb_build_object('intent', v_conv.intent, 'missing_fields', to_jsonb(v_conv.missing_fields))),
    'ids', jsonb_build_object(
      'variants', to_jsonb(v_variant_ids),
      'products', (select coalesce(jsonb_agg(x ->> 'product_id'), '[]'::jsonb) from jsonb_array_elements(v_catalog) x),
      'zones', (select coalesce(jsonb_agg(x ->> 'zone_id'), '[]'::jsonb) from jsonb_array_elements(v_zones) x),
      'policies', (select coalesce(jsonb_agg(x ->> 'policy_id'), '[]'::jsonb) from jsonb_array_elements(v_policies) x),
      'messages', (select coalesce(jsonb_agg(x ->> 'id'), '[]'::jsonb) from jsonb_array_elements(v_messages) x)),
    'pii_map', v_map);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Output validation (strict shape; Phase 3 AI §7–8)
-- ---------------------------------------------------------------------------------------------
create function app.ai_enum(p_name text)
returns text[] language sql immutable
as $$
  select case p_name
    when 'intent' then array['price_inquiry', 'availability_inquiry', 'product_details', 'recommendation',
                             'delivery_inquiry', 'policy_inquiry', 'payment_inquiry', 'place_order', 'order_status',
                             'modify_order', 'greeting', 'other']
    when 'fact' then array['store_name', 'product_name', 'variant_label', 'variant_price', 'variant_availability',
                           'zone_name', 'zone_fee', 'zone_time_text', 'policy_text', 'payment_methods']
    when 'missing' then array['product', 'variant', 'quantity', 'customer_name', 'customer_phone', 'zone', 'area',
                              'payment_method']
    when 'escalation' then array['complaint', 'refund_or_dispute', 'discount_request', 'health_or_safety',
                                 'authenticity_dispute', 'abuse', 'modify_approved_order', 'order_status',
                                 'human_requested', 'suspected_manipulation', 'unsupported_language',
                                 'repeated_clarification_failed', 'out_of_scope']
    when 'conflict' then array['product', 'variant', 'quantity', 'customer_name', 'customer_phone', 'zone', 'area',
                               'address', 'payment_method']
  end;
$$;

create function app.ai_segments_errors(p_segments jsonb, p_path text)
returns jsonb
language plpgsql immutable
as $$
declare
  v_errors jsonb := '{}'::jsonb;
  v_s jsonb;
  v_i integer := 0;
begin
  if p_segments is null or jsonb_typeof(p_segments) <> 'array' then
    return jsonb_build_object(p_path, 'invalid');
  end if;
  if jsonb_array_length(p_segments) > 40 then
    return jsonb_build_object(p_path, 'too_many');
  end if;
  for v_s in select * from jsonb_array_elements(p_segments) loop
    if jsonb_typeof(v_s) <> 'object' then
      v_errors := v_errors || jsonb_build_object(p_path || '.' || v_i, 'invalid');
    elsif v_s ? 'text' then
      if exists (select 1 from jsonb_object_keys(v_s) k where k <> 'text') or jsonb_typeof(v_s -> 'text') <> 'string'
         or char_length(v_s ->> 'text') > 1500 then
        v_errors := v_errors || jsonb_build_object(p_path || '.' || v_i, 'invalid');
      end if;
    elsif v_s ? 'fact' then
      if exists (select 1 from jsonb_object_keys(v_s) k where k not in ('fact', 'ref'))
         or not (v_s ->> 'fact' = any (app.ai_enum('fact')))
         or jsonb_typeof(v_s -> 'ref') <> 'string' or char_length(v_s ->> 'ref') > 64 then
        v_errors := v_errors || jsonb_build_object(p_path || '.' || v_i, 'invalid');
      end if;
    else
      v_errors := v_errors || jsonb_build_object(p_path || '.' || v_i, 'invalid');
    end if;
    v_i := v_i + 1;
  end loop;
  return v_errors;
end;
$$;

-- Nullable string of at most p_max characters.
create function app.ai_str_ok(p_value jsonb, p_max integer)
returns boolean language sql immutable
as $$ select p_value is null or jsonb_typeof(p_value) = 'null'
          or (jsonb_typeof(p_value) = 'string' and char_length(p_value #>> '{}') <= p_max) $$;

create function app.ai_output_errors(p_out jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
  v_errors jsonb := '{}'::jsonb;
  v_x jsonb;
  v_l jsonb;
  v_i integer;
  v_k text;
begin
  if p_out is null or jsonb_typeof(p_out) <> 'object' then
    return '{"output": "invalid"}'::jsonb;
  end if;
  for v_k in select k from jsonb_object_keys(p_out) k
              where k not in ('intent', 'reply_language', 'reply', 'clarification', 'extraction', 'missing_fields', 'escalation') loop
    v_errors := v_errors || jsonb_build_object(v_k, 'unknown');
  end loop;
  if not coalesce(p_out ->> 'intent' = any (app.ai_enum('intent')), false) then
    v_errors := v_errors || '{"intent": "invalid"}';
  end if;
  if coalesce(p_out ->> 'reply_language', '') not in ('ckb', 'ar', 'en') then
    v_errors := v_errors || '{"reply_language": "invalid"}';
  end if;
  v_errors := v_errors || app.ai_segments_errors(p_out -> 'reply', 'reply')
                       || app.ai_segments_errors(coalesce(p_out -> 'clarification', '[]'), 'clarification');
  if jsonb_typeof(p_out -> 'missing_fields') <> 'array'
     or exists (select 1 from jsonb_array_elements(p_out -> 'missing_fields') m
                 where jsonb_typeof(m) <> 'string' or not (m #>> '{}' = any (app.ai_enum('missing')))) then
    v_errors := v_errors || '{"missing_fields": "invalid"}';
  end if;
  v_x := p_out -> 'escalation';
  if jsonb_typeof(v_x) <> 'object' or exists (select 1 from jsonb_object_keys(v_x) k where k not in ('required', 'reasons'))
     or jsonb_typeof(v_x -> 'required') <> 'boolean' or jsonb_typeof(v_x -> 'reasons') <> 'array'
     or exists (select 1 from jsonb_array_elements(v_x -> 'reasons') r
                 where jsonb_typeof(r) <> 'string' or not (r #>> '{}' = any (app.ai_enum('escalation')))) then
    v_errors := v_errors || '{"escalation": "invalid"}';
  end if;

  v_x := p_out -> 'extraction';
  if v_x is null or jsonb_typeof(v_x) = 'null' then
    return v_errors;
  end if;
  if jsonb_typeof(v_x) <> 'object' then
    return v_errors || '{"extraction": "invalid"}';
  end if;
  for v_k in select k from jsonb_object_keys(v_x) k
              where k not in ('customer_name', 'phone', 'phone2', 'zone_id', 'city_text', 'area', 'landmark',
                              'address_details', 'payment_method', 'customer_note', 'lines', 'conflicts') loop
    v_errors := v_errors || jsonb_build_object('extraction.' || v_k, 'unknown');
  end loop;
  if not (jsonb_typeof(coalesce(v_x -> 'customer_name', 'null')) = 'null'
          or (jsonb_typeof(v_x -> 'customer_name') = 'object'
              and not exists (select 1 from jsonb_object_keys(v_x -> 'customer_name') k where k not in ('value', 'basis'))
              and app.ai_str_ok(v_x #> '{customer_name,value}', 200) and jsonb_typeof(v_x #> '{customer_name,value}') = 'string'
              and coalesce(v_x #>> '{customer_name,basis}', '') in ('stated', 'inferred'))) then
    v_errors := v_errors || '{"extraction.customer_name": "invalid"}';
  end if;
  foreach v_k in array array['phone', 'phone2'] loop
    if not (jsonb_typeof(coalesce(v_x -> v_k, 'null')) = 'null'
            or (jsonb_typeof(v_x -> v_k) = 'object'
                and not exists (select 1 from jsonb_object_keys(v_x -> v_k) k where k <> 'token')
                and coalesce(v_x -> v_k ->> 'token', '') ~ '^PHONE_[0-9]{1,2}$')) then
      v_errors := v_errors || jsonb_build_object('extraction.' || v_k, 'invalid');
    end if;
  end loop;
  if not (app.ai_str_ok(v_x -> 'zone_id', 64) and app.ai_str_ok(v_x -> 'city_text', 200) and app.ai_str_ok(v_x -> 'area', 200)
          and app.ai_str_ok(v_x -> 'landmark', 300) and app.ai_str_ok(v_x -> 'address_details', 600)
          and app.ai_str_ok(v_x -> 'customer_note', 800)
          and coalesce(v_x ->> 'payment_method', 'cod') in ('cod', 'other')) then
    v_errors := v_errors || '{"extraction.fields": "invalid"}';
  end if;
  if jsonb_typeof(coalesce(v_x -> 'lines', '[]')) <> 'array' or jsonb_array_length(coalesce(v_x -> 'lines', '[]')) > 20 then
    v_errors := v_errors || '{"extraction.lines": "invalid"}';
  else
    v_i := 0;
    for v_l in select * from jsonb_array_elements(coalesce(v_x -> 'lines', '[]')) loop
      if jsonb_typeof(v_l) <> 'object'
         or exists (select 1 from jsonb_object_keys(v_l) k
                     where k not in ('candidate_variant_ids', 'customer_text', 'quantity', 'quantity_basis'))
         or jsonb_typeof(v_l -> 'candidate_variant_ids') <> 'array'
         or jsonb_array_length(v_l -> 'candidate_variant_ids') > 10
         or exists (select 1 from jsonb_array_elements(v_l -> 'candidate_variant_ids') c
                     where jsonb_typeof(c) <> 'string' or char_length(c #>> '{}') > 64)
         or jsonb_typeof(v_l -> 'customer_text') <> 'string' or char_length(v_l ->> 'customer_text') > 400
         or not (jsonb_typeof(coalesce(v_l -> 'quantity', 'null')) = 'null' or jsonb_typeof(v_l -> 'quantity') = 'number')
         or coalesce(v_l ->> 'quantity_basis', '') not in ('stated', 'inferred') then
        v_errors := v_errors || jsonb_build_object('extraction.lines.' || v_i, 'invalid');
      end if;
      v_i := v_i + 1;
    end loop;
  end if;
  if jsonb_typeof(coalesce(v_x -> 'conflicts', '[]')) <> 'array'
     or exists (select 1 from jsonb_array_elements(coalesce(v_x -> 'conflicts', '[]')) c
                 where jsonb_typeof(c) <> 'object'
                    or exists (select 1 from jsonb_object_keys(c) k where k not in ('field', 'note'))
                    or not (c ->> 'field' = any (app.ai_enum('conflict')))
                    or not app.ai_str_ok(c -> 'note', 300)) then
    v_errors := v_errors || '{"extraction.conflicts": "invalid"}';
  end if;
  return v_errors;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Rendering: fact references become current values from this store's records.
-- Returns {text, facts_used, flags}. A reference outside the run's context or to a missing value
-- returns a flag and the caller falls back to the holding reply.
-- ---------------------------------------------------------------------------------------------
create function app.ai_render_fact(p_run app.ai_runs, p_fact text, p_ref text, p_lang text)
returns jsonb
language plpgsql stable
as $$
declare
  v_store app.stores;
  v_uuid uuid;
  v_variant app.product_variants;
  v_product app.products;
  v_zone app.delivery_zones;
  v_policy app.store_policies;
  v_text text;
  v_label text;
begin
  select * into v_store from app.stores where id = p_run.store_id;
  if p_fact = 'store_name' then
    return jsonb_build_object('text', v_store.name, 'label', 'store');
  end if;
  if p_fact = 'payment_methods' then
    v_text := concat_ws(app.ai_text('or', p_lang),
                        case when v_store.cod_enabled then app.ai_text('cod', p_lang) end,
                        case when v_store.other_payment_enabled then app.ai_text('other', p_lang) end);
    return jsonb_build_object('text', v_text, 'label', 'payment_methods');
  end if;
  if p_ref !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return null;
  end if;
  v_uuid := p_ref::uuid;
  if p_fact in ('product_name', 'variant_label', 'variant_price', 'variant_availability') then
    if p_fact = 'product_name' and p_run.context_ids -> 'products' ? p_ref then
      select * into v_product from app.products where id = v_uuid and store_id = p_run.store_id;
    elsif p_run.context_ids -> 'variants' ? p_ref then
      select * into v_variant from app.product_variants where id = v_uuid and store_id = p_run.store_id;
      select * into v_product from app.products where id = v_variant.product_id and store_id = p_run.store_id;
    end if;
    if v_product.id is null or (p_fact <> 'product_name' and v_variant.id is null) then
      return null;
    end if;
    v_label := v_product.name || coalesce(nullif(' / ' || v_variant.label, ' / '), '');
    v_text := case p_fact
      when 'product_name' then v_product.name
      when 'variant_label' then nullif(v_variant.label, '')
      when 'variant_price' then case when v_product.status = 'active' and v_variant.status = 'active'
                                     then app.format_money(coalesce(v_variant.price_override, v_product.base_price),
                                                           v_store.currency, p_lang) end
      when 'variant_availability' then app.ai_text(case app.variant_availability(v_product, v_variant)
                                                     when 'available' then 'in_stock' else app.variant_availability(v_product, v_variant) end,
                                                   p_lang) end;
    return case when v_text is null then null else jsonb_build_object('text', v_text, 'label', v_label) end;
  end if;
  if p_fact in ('zone_name', 'zone_fee', 'zone_time_text') then
    if not (p_run.context_ids -> 'zones' ? p_ref) then
      return null;
    end if;
    select * into v_zone from app.delivery_zones where id = v_uuid and store_id = p_run.store_id and active;
    if v_zone.id is null then
      return null;
    end if;
    v_text := case p_fact when 'zone_name' then v_zone.name
                          when 'zone_fee' then app.format_money(v_zone.fee, v_store.currency, p_lang)
                          else v_zone.time_text end;
    return case when v_text is null then null else jsonb_build_object('text', v_text, 'label', v_zone.name) end;
  end if;
  if p_fact = 'policy_text' then
    if not (p_run.context_ids -> 'policies' ? p_ref) then
      return null;
    end if;
    select * into v_policy from app.store_policies where id = v_uuid and store_id = p_run.store_id and active;
    return case when v_policy.id is null then null else jsonb_build_object('text', v_policy.body, 'label', v_policy.topic) end;
  end if;
  return null;
end;
$$;

create function app.ai_render(p_run app.ai_runs, p_segments jsonb, p_lang text)
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
      v_flags := v_flags || app.reply_guard(v_s ->> 'text');
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

-- ---------------------------------------------------------------------------------------------
-- Draft merge (lenient): invalid proposals are dropped and reported, never fatal; seller edits win;
-- only draft / pending_approval; prices, fees and totals from the catalog, zones and calculation.
-- Returns {order_id, created, skipped, dropped, flags}.
-- ---------------------------------------------------------------------------------------------
create function app.ai_write_lines(p_run app.ai_runs, p_order_id uuid, p_lines jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_line jsonb;
  v_i integer := 0;
  v_cands uuid[];
  v_variant app.product_variants;
  v_product app.products;
  v_qty integer;
  v_basis text;
  v_text text;
  v_existing app.order_items;
  v_kept uuid[] := '{}';
  v_flags text[] := '{}';
  v_resolution text;
  v_products integer;
begin
  for v_line in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    -- Candidates: only ids sent for this run, of this store, still sellable.
    select coalesce(array_agg(distinct v.id), '{}') into v_cands
      from jsonb_array_elements_text(v_line -> 'candidate_variant_ids') c(id)
      join app.product_variants v on v.id::text = c.id and v.store_id = p_run.store_id
      join app.products p on p.id = v.product_id
     where p_run.context_ids -> 'variants' ? c.id and p.status = 'active' and v.status = 'active'
       and (p.track_stock or v.available);
    if jsonb_array_length(v_line -> 'candidate_variant_ids') > cardinality(v_cands) then
      v_flags := v_flags || 'line_candidate_dropped'::text;
    end if;
    v_qty := case when jsonb_typeof(v_line -> 'quantity') = 'number' and (v_line ->> 'quantity') ~ '^[0-9]{1,3}$'
                       and (v_line ->> 'quantity')::integer between 1 and 999
                  then (v_line ->> 'quantity')::integer end;
    v_basis := case when v_qty is null then 'inferred' else coalesce(v_line ->> 'quantity_basis', 'inferred') end;
    if v_line ->> 'quantity' is not null and v_qty is null then
      v_flags := v_flags || 'quantity_invalid'::text;
    end if;
    v_qty := coalesce(v_qty, 1);
    v_text := nullif(left(btrim(coalesce(v_line ->> 'customer_text', '')), 200), '');
    select count(distinct product_id) into v_products from app.product_variants where id = any (v_cands);

    if cardinality(v_cands) = 1 then
      select * into v_variant from app.product_variants where id = v_cands[1];
      select * into v_product from app.products where id = v_variant.product_id;
      if v_variant.id = any (select variant_id from app.order_items where order_id = p_order_id and id = any (v_kept)) then
        continue;   -- the same variant twice: one line
      end if;
      select * into v_existing from app.order_items where order_id = p_order_id and variant_id = v_variant.id;
      if v_existing.id is not null then
        update app.order_items set quantity = v_qty, quantity_basis = v_basis, position = v_i, customer_text = v_text
         where id = v_existing.id;
      else
        insert into app.order_items (store_id, order_id, position, variant_id, product_id, customer_text, name_snapshot,
                                     variant_label_snapshot, sku_snapshot, quantity, quantity_basis, quoted_unit_price)
        values (p_run.store_id, p_order_id, v_i, v_variant.id, v_product.id, v_text, v_product.name, v_variant.label,
                v_variant.sku, v_qty, v_basis, coalesce(v_variant.price_override, v_product.base_price))
        returning * into v_existing;
      end if;
      if v_product.track_stock and v_variant.stock_on_hand < v_qty then
        v_flags := v_flags || 'exceeds_stock'::text;
      end if;
      v_kept := v_kept || v_existing.id;
      v_existing := null;
    else
      -- Unresolved: the seller chooses (Phase 1 §8.4); never a default variant.
      v_resolution := case when cardinality(v_cands) = 0 then 'not_in_catalog'
                           when v_products = 1 then 'variant_needed' else 'choose_product' end;
      insert into app.order_items (store_id, order_id, position, resolution, customer_text, name_snapshot, quantity,
                                   quantity_basis, candidate_variant_ids)
      values (p_run.store_id, p_order_id, v_i, v_resolution, v_text, coalesce(v_text, '?'), v_qty, v_basis,
              v_cands[1:3])
      returning * into v_existing;
      v_kept := v_kept || v_existing.id;
      v_existing := null;
    end if;
    v_i := v_i + 1;
  end loop;
  delete from app.order_items where order_id = p_order_id and not (id = any (v_kept));
  return to_jsonb(array(select distinct f from unnest(v_flags) f order by f));
end;
$$;

create function app.ai_merge_draft(p_run app.ai_runs, p_extraction jsonb, p_pii jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_conv app.conversations;
  v_store app.stores;
  v_order app.orders;
  v_exists boolean := false;
  v_order_id uuid;
  v_conflicts text[];
  v_ai jsonb := '{}'::jsonb;
  v_skipped text[] := '{}';
  v_dropped text[] := '{}';
  v_flags jsonb := '[]'::jsonb;
  v_merged jsonb;
  v_errors jsonb;
  v_val text;
  v_key text;
  v_count integer;
  v_number integer;
  v_status text;
  v_before jsonb;
  v_after jsonb;
begin
  select * into v_conv from app.conversations where id = p_run.conversation_id for update;
  select * into v_store from app.stores where id = p_run.store_id;
  select coalesce(array_agg(c ->> 'field'), '{}') into v_conflicts
    from jsonb_array_elements(coalesce(p_extraction -> 'conflicts', '[]')) c;

  -- Proposed values, each validated on its own; conflicting or invalid ones are not written.
  v_val := left(btrim(coalesce(p_extraction #>> '{customer_name,value}', '')), 80);
  if v_val <> '' then v_ai := v_ai || jsonb_build_object('customer_name', v_val); end if;
  foreach v_key in array array['phone', 'phone2'] loop
    if p_extraction -> v_key ->> 'token' is not null then
      v_val := p_pii ->> (p_extraction -> v_key ->> 'token');
      if v_val is null then
        v_dropped := v_dropped || ('customer_' || v_key);
      else
        v_ai := v_ai || jsonb_build_object(case v_key when 'phone' then 'customer_phone' else 'customer_phone2' end, v_val);
      end if;
    end if;
  end loop;
  if p_extraction ->> 'zone_id' is not null then
    if p_run.context_ids -> 'zones' ? (p_extraction ->> 'zone_id') then
      v_ai := v_ai || jsonb_build_object('zone_id', p_extraction ->> 'zone_id');
    else
      v_dropped := v_dropped || 'zone_id'::text;
    end if;
  elsif nullif(btrim(coalesce(p_extraction ->> 'city_text', '')), '') is not null then
    v_ai := v_ai || jsonb_build_object('city_text', left(btrim(p_extraction ->> 'city_text'), 60));
  end if;
  foreach v_key in array array['area', 'landmark', 'address_details', 'customer_note'] loop
    v_val := nullif(btrim(coalesce(p_extraction ->> v_key, '')), '');
    if v_val is not null then
      v_ai := v_ai || jsonb_build_object(v_key, left(v_val, case v_key when 'area' then 80 when 'landmark' then 120
                                                                        when 'address_details' then 300 else 500 end));
    end if;
  end loop;
  if p_extraction ->> 'payment_method' is not null then
    if (p_extraction ->> 'payment_method' = 'cod' and v_store.cod_enabled)
       or (p_extraction ->> 'payment_method' = 'other' and v_store.other_payment_enabled) then
      v_ai := v_ai || jsonb_build_object('payment_method', p_extraction ->> 'payment_method');
    else
      v_dropped := v_dropped || 'payment_method'::text;
    end if;
  end if;
  -- Conflicts: the field waits for the customer's answer (Phase 1 §8.6 "Conflict — choose").
  foreach v_key in array v_conflicts loop
    v_ai := v_ai - case v_key when 'customer_phone' then 'customer_phone' when 'zone' then 'zone_id' else v_key end;
    if v_key = 'zone' then v_ai := v_ai - 'city_text'; end if;
    if v_key = 'address' then v_ai := v_ai - 'address_details' - 'landmark'; end if;
  end loop;

  if v_conv.order_id is not null then
    select * into v_order from app.orders where id = v_conv.order_id for update;
    v_exists := true;
    if v_order.status not in ('draft', 'pending_approval') then
      return jsonb_build_object('order_id', v_order.id, 'created', false, 'closed', true,
                                'flags', '["draft_closed"]'::jsonb);
    end if;
  else
    if v_ai = '{}'::jsonb and jsonb_array_length(coalesce(p_extraction -> 'lines', '[]')) = 0 then
      return null;   -- nothing to put on a draft
    end if;
    perform pg_advisory_xact_lock(hashtextextended('ai_drafts:' || p_run.store_id::text, 0));
    select count(*) into v_count from app.orders
     where store_id = p_run.store_id and origin = 'ai' and created_at > now() - interval '24 hours';
    if v_count >= app.ai_limit('drafts_per_store_per_day') then
      return jsonb_build_object('order_id', null, 'created', false, 'flags', '["draft_quota_reached"]'::jsonb);
    end if;
  end if;

  -- Seller edits win.
  if v_exists then
    for v_key in select k from jsonb_object_keys(v_ai) k loop
      if v_key = any (v_order.seller_edited)
         or (v_key in ('zone_id', 'city_text') and ('zone_id' = any (v_order.seller_edited) or 'city_text' = any (v_order.seller_edited))) then
        v_skipped := v_skipped || v_key;
        v_ai := v_ai - v_key;
      end if;
    end loop;
  end if;
  if v_ai ? 'zone_id' then v_ai := v_ai || '{"city_text": null}';
  elsif v_ai ? 'city_text' then v_ai := v_ai || '{"zone_id": null}'; end if;

  v_merged := case when v_exists then app.order_payload(v_order.id) - 'lines' else '{}'::jsonb end || v_ai;
  v_merged := jsonb_strip_nulls(v_merged);
  -- Anything the order rules still refuse is dropped (one field at a time), not forced.
  for v_count in 1..12 loop
    v_errors := app.order_field_errors(p_run.store_id, v_merged || '{"lines": []}'::jsonb,
                                       case when v_exists then v_order.zone_id end) - 'lines';
    exit when v_errors = '{}'::jsonb;
    select k into v_key from jsonb_object_keys(v_errors) k limit 1;
    v_dropped := v_dropped || v_key;
    v_merged := v_merged - v_key - split_part(v_key, '.', 1);
  end loop;

  if not v_exists then
    update app.stores set last_order_number = last_order_number + 1 where id = p_run.store_id
      returning last_order_number into v_number;
    insert into app.orders (store_id, number, status, origin, ai_ref, currency, is_test)
    values (p_run.store_id, v_number, 'draft', 'ai', 'conversation:' || v_conv.id, v_store.currency, v_conv.is_sandbox)
    returning id into v_order_id;
    update app.conversations set order_id = v_order_id where id = v_conv.id;
  else
    v_order_id := v_order.id;
    v_before := app.order_audit_state(v_order_id);
  end if;

  if p_extraction ? 'lines' and jsonb_array_length(coalesce(p_extraction -> 'lines', '[]')) > 0 then
    if v_exists and 'lines' = any (v_order.seller_edited) then
      v_skipped := v_skipped || 'lines'::text;
    elsif 'product' = any (v_conflicts) or 'variant' = any (v_conflicts) or 'quantity' = any (v_conflicts) then
      v_flags := v_flags || '["lines_conflict"]'::jsonb;
    else
      v_flags := v_flags || app.ai_write_lines(p_run, v_order_id, p_extraction -> 'lines');
    end if;
  end if;
  perform app.order_recompute(v_order_id, app.order_write_header(v_order_id, v_merged));

  if not v_exists then
    v_status := case when app.order_issues(v_order_id) = '[]'::jsonb then 'pending_approval' else 'draft' end;
    update app.orders set status = v_status where id = v_order_id;
    insert into app.order_status_events (store_id, order_id, from_status, to_status, actor_system)
    values (p_run.store_id, v_order_id, null, v_status, 'ai');
    perform app.audit(p_run.store_id, 'order.ai_create', 'order', v_order_id, null,
                      app.order_audit_state(v_order_id) || jsonb_build_object('actor', 'ai', 'ai_run_id', p_run.id));
  else
    update app.orders set version = version + 1 where id = v_order_id;
    perform app.order_reevaluate(v_order_id);
    v_after := app.order_audit_state(v_order_id);
    if v_after <> v_before then
      perform app.audit(p_run.store_id, 'order.ai_update', 'order', v_order_id,
                        app.jsonb_changed(v_before, v_after, 'before'),
                        app.jsonb_changed(v_before, v_after, 'after') || jsonb_build_object('actor', 'ai', 'ai_run_id', p_run.id));
    end if;
  end if;

  return jsonb_build_object('order_id', v_order_id, 'created', not v_exists,
                            'skipped', to_jsonb(array(select distinct x from unnest(v_skipped) x order by x)),
                            'dropped', to_jsonb(array(select distinct x from unnest(v_dropped) x order by x)),
                            'flags', v_flags);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Seller side: ask for help
-- ---------------------------------------------------------------------------------------------
create function api.request_ai_assist(p_store_id uuid, p_conversation_id uuid, p_mode text, p_idempotency_key uuid)
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

-- ---------------------------------------------------------------------------------------------
-- Worker side (aisellia_ai_worker only)
-- ---------------------------------------------------------------------------------------------
create function api.ai_claim_run(p_run_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_run app.ai_runs;
  v_built jsonb;
  v_skip text;
  v_code text;
  v_detail text;
  v_state text;
begin
  select * into v_run from app.ai_runs where id = p_run_id for update;
  if not found or v_run.status <> 'queued' then
    perform app.fail('RUN_NOT_CLAIMABLE');
  end if;
  if v_run.created_at < now() - make_interval(secs => app.ai_limit('assist_claim_seconds')) then
    update app.ai_runs set status = 'expired', finished_at = now(), error_code = 'not_claimed' where id = v_run.id;
    return app.err('RUN_NOT_CLAIMABLE', '{"reason": "expired"}');
  end if;
  -- The switches may have changed since the seller asked.
  select case when not s.ai_enabled or s.deletion_requested_at is not null then 'ai_disabled'
              when c.ai_paused then 'ai_paused' end
    into v_skip
    from app.stores s join app.conversations c on c.store_id = s.id and c.id = v_run.conversation_id
   where s.id = v_run.store_id;
  if v_skip is not null then
    update app.ai_runs set status = 'skipped', finished_at = now(), error_code = v_skip where id = v_run.id;
    return app.err('RUN_NOT_CLAIMABLE', jsonb_build_object('reason', v_skip));
  end if;
  v_built := app.ai_build_context(v_run);
  update app.ai_runs set status = 'running', claimed_at = now(), context_ids = v_built -> 'ids', pii_map = v_built -> 'pii_map'
   where id = v_run.id;
  return app.ok(jsonb_build_object('run_id', v_run.id, 'mode', v_run.mode, 'context', v_built -> 'context'));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('ai_claim_run', v_state, v_code);
end;
$$;

-- Usage, timings and the estimated cost of a run (no content).
create function app.ai_record_meta(p_run_id uuid, p_meta jsonb)
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
    cost_micro_usd = case when v_price.model is null then null
                          else (v_in::numeric * v_price.input_micro + v_out::numeric * v_price.output_micro
                                + v_cr::numeric * v_price.cache_read_micro + v_cw::numeric * v_price.cache_write_micro)
                               / 1000000 end
  where id = p_run_id;
end;
$$;

create function app.ai_lock_running_run(p_run_id uuid)
returns app.ai_runs
language plpgsql
as $$
declare
  v_run app.ai_runs;
begin
  select * into v_run from app.ai_runs where id = p_run_id for update;
  if not found or v_run.status <> 'running' then
    perform app.fail('RUN_NOT_RUNNING');
  end if;
  if v_run.claimed_at < now() - make_interval(secs => app.ai_limit('assist_run_seconds')) then
    update app.ai_runs set status = 'expired', finished_at = now(), pii_map = null, error_code = 'too_slow' where id = v_run.id;
    perform app.fail('RUN_NOT_RUNNING', '{"reason": "expired"}');
  end if;
  return v_run;
end;
$$;

create function api.ai_complete_run(p_run_id uuid, p_output jsonb, p_meta jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_run app.ai_runs;
  v_conv app.conversations;
  v_errors jsonb;
  v_lang text;
  v_reasons text[];
  v_reply jsonb;
  v_clar jsonb;
  v_text text;
  v_flags text[] := '{}';
  v_holding boolean := false;
  v_draft jsonb;
  v_missing text[];
  v_counts jsonb;
  v_new_inbound boolean;
  v_suggestion_id uuid;
  v_intent text;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_run := app.ai_lock_running_run(p_run_id);
  perform app.ai_record_meta(v_run.id, coalesce(p_meta, '{}'::jsonb));
  select * into v_conv from app.conversations where id = v_run.conversation_id for update;

  -- 1. Strict shape. Invalid output persists nothing but the run record.
  v_errors := app.ai_output_errors(p_output);
  if v_errors <> '{}'::jsonb then
    update app.ai_runs set status = 'invalid_output', finished_at = now(), pii_map = null, error_code = 'schema',
                           validation_errors = v_errors
     where id = v_run.id;
    return app.err('AI_INVALID_OUTPUT', jsonb_build_object('run_id', v_run.id));
  end if;
  v_lang := p_output ->> 'reply_language';
  v_intent := p_output ->> 'intent';

  -- 2. Escalation: the model's reasons, plus this database's own checks on the customer's new text.
  select coalesce(array_agg(distinct r), '{}') into v_reasons
    from jsonb_array_elements_text(p_output #> '{escalation,reasons}') r;
  if (p_output #>> '{escalation,required}')::boolean and cardinality(v_reasons) = 0 then
    v_reasons := array['out_of_scope'];
  end if;
  if exists (select 1 from app.messages m
              where m.conversation_id = v_conv.id and m.direction = 'in' and m.body is not null
                and m.seq > coalesce(v_conv.last_ai_seq, 0) and app.looks_like_manipulation(m.body)) then
    v_reasons := array(select distinct x from unnest(v_reasons || 'suspected_manipulation'::text) x);
  end if;
  if v_intent = 'order_status' and not ('order_status' = any (v_reasons)) then
    v_reasons := v_reasons || 'order_status'::text;   -- P0: order status is always the seller's
  end if;

  -- 3. Repeated clarification (Phase 1 §8.5): a field still missing after two rounds with new
  --    customer messages escalates.
  v_missing := array(select distinct m from jsonb_array_elements_text(p_output -> 'missing_fields') m order by m);
  v_new_inbound := exists (select 1 from app.messages m where m.conversation_id = v_conv.id and m.direction = 'in'
                                                         and m.seq > coalesce(v_conv.last_ai_seq, 0));
  select coalesce(jsonb_object_agg(f, case when v_new_inbound then coalesce((v_conv.clarify_counts ->> f)::integer, 0) + 1
                                           else coalesce((v_conv.clarify_counts ->> f)::integer, 0) end), '{}'::jsonb)
    into v_counts from unnest(v_missing) f;
  if exists (select 1 from jsonb_each_text(v_counts) e where e.value::integer > 2)
     and not ('repeated_clarification_failed' = any (v_reasons)) then
    v_reasons := v_reasons || 'repeated_clarification_failed'::text;
  end if;

  -- 4. Reply: rendered facts, guarded text; escalated runs only get the holding reply.
  if cardinality(v_reasons) > 0 then
    v_holding := true;
  else
    v_reply := app.ai_render(v_run, p_output -> 'reply', v_lang);
    v_clar := app.ai_render(v_run, coalesce(p_output -> 'clarification', '[]'), v_lang);
    v_flags := array(select jsonb_array_elements_text(v_reply -> 'flags'))
               || array(select jsonb_array_elements_text(v_clar -> 'flags'));
    v_text := btrim(concat_ws(' ', nullif(v_reply ->> 'text', ''), nullif(v_clar ->> 'text', '')));
    if cardinality(v_flags) > 0 or v_text = '' or char_length(v_text) > 4000 then
      v_holding := true;
      if v_text = '' then v_flags := v_flags || 'empty_reply'::text; end if;
    end if;
  end if;
  if v_holding then
    v_text := app.ai_text('holding', v_lang);
  end if;

  -- 5. Draft: buying intent (or the seller's "create order from conversation"), never when escalated.
  if cardinality(v_reasons) = 0 and (v_intent = 'place_order' or v_run.mode = 'draft')
     and jsonb_typeof(p_output -> 'extraction') = 'object' then
    v_draft := app.ai_merge_draft(v_run, p_output -> 'extraction', v_run.pii_map);
    if v_draft is not null then
      v_flags := v_flags || array(select jsonb_array_elements_text(v_draft -> 'flags'));
    end if;
  end if;

  -- 6. Suggestion and conversation state.
  update app.reply_suggestions set status = 'superseded', updated_at = now()
   where conversation_id = v_conv.id and status = 'suggested';
  insert into app.reply_suggestions (store_id, conversation_id, ai_run_id, intent, reply_language, text_rendered, facts_used,
                                     missing_fields, escalation_reasons, conflicts, flags, is_holding)
  values (v_run.store_id, v_conv.id, v_run.id, v_intent, v_lang, v_text,
          case when v_holding then '[]'::jsonb else (v_reply -> 'facts') || (v_clar -> 'facts') end,
          v_missing, v_reasons, coalesce(p_output #> '{extraction,conflicts}', '[]'::jsonb),
          array(select distinct f from unnest(v_flags) f order by f), v_holding)
  returning id into v_suggestion_id;

  update app.conversations set
    intent = v_intent,
    missing_fields = v_missing,
    clarify_counts = v_counts,
    status = case when cardinality(v_reasons) > 0 then 'needs_you'
                  when status = 'closed' then status else 'needs_reply' end,
    escalation_reasons = case when cardinality(v_reasons) > 0
                              then array(select distinct x from unnest(escalation_reasons || v_reasons) x order by x)
                              else escalation_reasons end,
    last_ai_seq = v_run.last_message_seq,
    updated_at = now(), version = version + 1
  where id = v_conv.id;

  update app.ai_runs set status = 'succeeded', finished_at = now(), pii_map = null, output_json = p_output,
                         validation_errors = case when cardinality(v_flags) > 0
                                                  then jsonb_build_object('flags', to_jsonb(v_flags)) end
   where id = v_run.id;
  return app.ok(jsonb_build_object('run_id', v_run.id, 'status', 'succeeded', 'suggestion_id', v_suggestion_id,
                                   'escalated', cardinality(v_reasons) > 0, 'order_id', v_draft ->> 'order_id'));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('ai_complete_run', v_state, v_code);
end;
$$;

-- The provider failed, timed out, refused or rate-limited, or the output never validated.
create function api.ai_fail_run(p_run_id uuid, p_status text, p_error_code text, p_meta jsonb)
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

-- For reconciliation after a lost connection: did the run finish?
create function api.ai_run_state(p_run_id uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce((select app.ok(jsonb_build_object('run_id', id, 'status', status)) from app.ai_runs where id = p_run_id),
                  app.err('NOT_FOUND'));
$$;

-- ---------------------------------------------------------------------------------------------
-- Seller side: suggestions and runs
-- ---------------------------------------------------------------------------------------------
create function app.suggestion_json(s app.reply_suggestions)
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'id', s.id, 'ai_run_id', s.ai_run_id, 'intent', s.intent, 'reply_language', s.reply_language,
    'text', s.text_rendered, 'facts_used', s.facts_used, 'missing_fields', to_jsonb(s.missing_fields),
    'escalation_reasons', to_jsonb(s.escalation_reasons), 'conflicts', s.conflicts, 'flags', to_jsonb(s.flags),
    'is_holding', s.is_holding, 'status', s.status, 'message_id', s.message_id, 'created_at', s.created_at);
$$;

create or replace function app.conversation_json(p_conversation_id uuid)
returns jsonb language sql stable
as $$
  select app.conversation_summary_json(c) || jsonb_build_object(
    'messages', coalesce((select jsonb_agg(app.message_json(m) order by m.seq)
                            from (select * from app.messages where conversation_id = c.id order by seq desc limit 200) m),
                         '[]'::jsonb),
    'message_count', (select count(*) from app.messages where conversation_id = c.id),
    'suggestion', (select app.suggestion_json(s) from app.reply_suggestions s
                    where s.conversation_id = c.id and s.status in ('suggested', 'copied')
                    order by s.created_at desc limit 1),
    'last_run', (select jsonb_build_object('id', r.id, 'status', r.status, 'error_code', r.error_code, 'mode', r.mode,
                                           'created_at', r.created_at, 'finished_at', r.finished_at)
                   from app.ai_runs r where r.conversation_id = c.id order by r.created_at desc limit 1),
    'order', (select jsonb_build_object('id', o.id, 'number', o.number, 'status', o.status, 'is_test', o.is_test,
                                        'total', o.total, 'currency', o.currency, 'issues', app.order_issues(o.id),
                                        'version', o.version)
                from app.orders o where o.id = c.order_id),
    'ai', (select jsonb_build_object('enabled', s.ai_enabled,
                                     'calls_today', (select count(*) from app.ai_runs r
                                                      where r.store_id = s.id and r.created_at > now() - interval '24 hours'),
                                     'daily_limit', app.ai_limit('assist_calls_per_store_per_day'))
             from app.stores s where s.id = c.store_id))
  from app.conversations c where c.id = p_conversation_id;
$$;

-- The seller copies a suggestion (optionally edited) to send it themselves: an outbound message
-- in state "copied — not confirmed as sent" (US-024). Never "sent".
create function api.copy_suggestion(p_store_id uuid, p_suggestion_id uuid, p_text text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_s app.reply_suggestions;
  v_text text := nullif(btrim(coalesce(p_text, '')), '');
  v_hash text;
  v_result jsonb;
  v_msg app.messages;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  if v_text is not null and char_length(v_text) > 4000 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"text": "too_long"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('suggestion_id', p_suggestion_id, 'text', app.secret_hash(coalesce(v_text, ''))));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'copy_suggestion', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  select * into v_s from app.reply_suggestions where id = p_suggestion_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_s.status not in ('suggested', 'copied') then
    perform app.fail('SUGGESTION_CLOSED', jsonb_build_object('status', v_s.status));
  end if;
  perform app.lock_conversation(p_store_id, v_s.conversation_id);
  insert into app.messages (store_id, conversation_id, direction, origin, body, state, edited, suggestion_id, created_by)
  values (p_store_id, v_s.conversation_id, 'out', 'ai_reply_copied', coalesce(v_text, v_s.text_rendered), 'copied',
          v_text is not null and v_text <> v_s.text_rendered, v_s.id, v_uid)
  returning * into v_msg;
  update app.reply_suggestions set status = 'copied', message_id = v_msg.id, updated_at = now() where id = v_s.id;
  update app.conversations set last_activity_at = now(), updated_at = now(), version = version + 1
   where id = v_s.conversation_id;
  v_result := app.ok(jsonb_build_object('message_id', v_msg.id, 'state', v_msg.state, 'edited', v_msg.edited));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'copy_suggestion', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('copy_suggestion', v_state, v_code);
end;
$$;

-- "I sent this" (US-024): copied → marked sent by the seller. The conversation waits for the customer.
create function api.mark_message_sent(p_store_id uuid, p_message_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_msg app.messages;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  select * into v_msg from app.messages where id = p_message_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_msg.state = 'marked_sent' then
    return app.ok(jsonb_build_object('message_id', v_msg.id, 'state', v_msg.state));
  end if;
  if v_msg.state <> 'copied' then
    perform app.fail('INVALID_TRANSITION', jsonb_build_object('state', v_msg.state));
  end if;
  update app.messages set state = 'marked_sent' where id = v_msg.id;
  update app.conversations
     set status = case when status in ('needs_reply') then 'waiting' else status end,
         last_activity_at = now(), updated_at = now(), version = version + 1
   where id = v_msg.conversation_id;
  return app.ok(jsonb_build_object('message_id', v_msg.id, 'state', 'marked_sent'));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('mark_message_sent', v_state, v_code);
end;
$$;

create function api.dismiss_suggestion(p_store_id uuid, p_suggestion_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_s app.reply_suggestions;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  select * into v_s from app.reply_suggestions where id = p_suggestion_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_s.status = 'suggested' then
    update app.reply_suggestions set status = 'dismissed', updated_at = now() where id = v_s.id;
  end if;
  return app.ok(jsonb_build_object('id', v_s.id, 'status', case when v_s.status = 'suggested' then 'dismissed' else v_s.status end));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('dismiss_suggestion', v_state, v_code);
end;
$$;

-- What happened to a run (polled by the app while the worker runs).
create function api.get_ai_run(p_store_id uuid, p_run_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_run app.ai_runs;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  select * into v_run from app.ai_runs where id = p_run_id and store_id = p_store_id;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  return app.ok(jsonb_build_object('id', v_run.id, 'conversation_id', v_run.conversation_id, 'status', v_run.status,
                                   'error_code', v_run.error_code, 'mode', v_run.mode,
                                   'created_at', v_run.created_at, 'finished_at', v_run.finished_at));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('get_ai_run', v_state, v_code);
end;
$$;

-- AI usage for the seller and operators: calls, outcomes, tokens and estimated cost per day.
create function api.ai_usage(p_store_id uuid, p_days integer default 7)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'ai.manage');
  return app.ok(jsonb_build_object(
    'daily_limit', app.ai_limit('assist_calls_per_store_per_day'),
    'days', coalesce((
      select jsonb_agg(jsonb_build_object(
               'day', d.day, 'calls', d.calls, 'succeeded', d.succeeded, 'failed', d.failed, 'escalated', d.escalated,
               'input_tokens', d.input_tokens, 'output_tokens', d.output_tokens, 'cache_read_tokens', d.cache_read_tokens,
               'cost_micro_usd', d.cost) order by d.day desc)
        from (select date_trunc('day', r.created_at)::date as day, count(*) as calls,
                     count(*) filter (where r.status = 'succeeded') as succeeded,
                     count(*) filter (where r.status in ('timeout', 'provider_error', 'invalid_output', 'rate_limited', 'expired')) as failed,
                     count(*) filter (where exists (select 1 from app.reply_suggestions s where s.ai_run_id = r.id
                                                     and cardinality(s.escalation_reasons) > 0)) as escalated,
                     coalesce(sum(r.input_tokens), 0) as input_tokens, coalesce(sum(r.output_tokens), 0) as output_tokens,
                     coalesce(sum(r.cache_read_tokens), 0) as cache_read_tokens, coalesce(sum(r.cost_micro_usd), 0) as cost
                from app.ai_runs r
               where r.store_id = p_store_id
                 and r.created_at > now() - make_interval(days => least(greatest(coalesce(p_days, 7), 1), 90))
               group by 1) d), '[]'::jsonb)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('ai_usage', v_state, v_code);
end;
$$;

-- Deletes a conversation's content (messages, suggestions, AI outputs) at the seller's request.
-- An order created from it stays (its own data is handled by api.anonymize_customer).
create function api.delete_conversation(p_store_id uuid, p_conversation_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_member app.store_members;
  v_conv app.conversations;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  v_member := app.require_permission(p_store_id, 'customers.delete');
  if v_member.role <> 'owner' then
    perform app.fail('FORBIDDEN');
  end if;
  v_conv := app.lock_conversation(p_store_id, p_conversation_id);
  if exists (select 1 from app.ai_runs where conversation_id = v_conv.id and status in ('queued', 'running')
               and created_at > now() - make_interval(secs => app.ai_limit('assist_run_seconds'))) then
    perform app.fail('AI_BUSY');
  end if;
  update app.messages set suggestion_id = null where conversation_id = v_conv.id;
  delete from app.messages where conversation_id = v_conv.id;
  delete from app.reply_suggestions where conversation_id = v_conv.id;
  delete from app.ai_runs where conversation_id = v_conv.id;
  delete from app.conversations where id = v_conv.id;
  perform app.audit(p_store_id, 'conversation.delete', 'conversation', v_conv.id, null,
                    jsonb_build_object('order_id', v_conv.order_id));
  return app.ok(jsonb_build_object('id', v_conv.id, 'deleted', true));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('delete_conversation', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Orders show where an AI draft came from and the candidates of an unresolved line.
-- ---------------------------------------------------------------------------------------------
alter function app.order_json(uuid) rename to order_json_base;
create function app.order_json(p_order_id uuid)
returns jsonb language sql stable
as $$
  select b || jsonb_build_object(
    'conversation_id', (select c.id from app.conversations c where c.order_id = p_order_id),
    'lines', coalesce((
      select jsonb_agg(l || jsonb_build_object('candidates', coalesce((
               select jsonb_agg(jsonb_build_object('variant_id', v.id, 'name', p.name, 'variant_label', v.label,
                                                   'price', coalesce(v.price_override, p.base_price),
                                                   'available', app.variant_availability(p, v) in ('in_stock', 'low', 'available'))
                                order by p.name, v.position)
                 from app.order_items i
                 join app.product_variants v on v.id = any (i.candidate_variant_ids)
                 join app.products p on p.id = v.product_id
                where i.id = (l ->> 'id')::uuid), '[]'::jsonb)) order by o)
        from jsonb_array_elements(b -> 'lines') with ordinality e(l, o)), '[]'::jsonb))
  from (select app.order_json_base(p_order_id) as b) x
  where b is not null;
$$;

-- ---------------------------------------------------------------------------------------------
-- Retention: AI outputs after 90 days (Phase 3 §7, D-13); message bodies 12 months after the
-- conversation's last activity. Both reuse the observable job runner.
-- ---------------------------------------------------------------------------------------------
create or replace function internal.run_retention(p_job text, p_older_than interval)
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
  elsif p_job = 'purge_ai_run_outputs' then
    update app.ai_runs set output_json = null, validation_errors = null, pii_map = null
     where output_json is not null and coalesce(finished_at, created_at) < now() - p_older_than;
  elsif p_job = 'purge_message_bodies' then
    update app.messages m set body = null, body_purged_at = now()
      from app.conversations c
     where c.id = m.conversation_id and m.body is not null and c.last_activity_at < now() - p_older_than;
    get diagnostics v_count = row_count;
    update app.reply_suggestions s set text_rendered = null, facts_used = '[]', conflicts = '[]'
      from app.conversations c
     where c.id = s.conversation_id and s.text_rendered is not null and c.last_activity_at < now() - p_older_than;
    update app.job_runs set finished_at = clock_timestamp(), status = 'ok', affected = v_count,
                            details = jsonb_build_object('retention', p_older_than::text)
     where id = v_run;
    return v_count;
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
    insert into app.job_runs (job, finished_at, status, details)
    values (p_job, clock_timestamp(), 'failed', jsonb_build_object('sqlstate', v_state));
    raise warning 'job % failed: sqlstate %', p_job, v_state;
    return -1;
end;
$$;

create function internal.purge_ai_run_outputs(p_older_than interval default interval '90 days')
returns integer
language sql volatile security definer set search_path = ''
as $$ select internal.run_retention('purge_ai_run_outputs', p_older_than) $$;

create function internal.purge_message_bodies(p_older_than interval default interval '365 days')
returns integer
language sql volatile security definer set search_path = ''
as $$ select internal.run_retention('purge_message_bodies', p_older_than) $$;

create or replace function internal.job_health()
returns table (job text, last_started_at timestamptz, last_status text, last_affected integer,
               last_ok_at timestamptz, stale boolean)
language sql stable security definer set search_path = ''
as $$
  select j.job, l.started_at, l.status, l.affected, ok.finished_at,
         ok.finished_at is null or ok.finished_at < now() - interval '36 hours' or l.status = 'failed'
    from (values ('purge_idempotency_keys'), ('purge_ai_request_log'), ('purge_ai_run_outputs'),
                 ('purge_message_bodies')) j(job)
    left join lateral (select * from app.job_runs r where r.job = j.job order by r.id desc limit 1) l on true
    left join lateral (select * from app.job_runs r where r.job = j.job and r.status = 'ok'
                        order by r.id desc limit 1) ok on true;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('aisellia-purge-ai-run-outputs', '35 3 * * *', 'select internal.purge_ai_run_outputs()');
    perform cron.schedule('aisellia-purge-message-bodies', '41 3 * * *', 'select internal.purge_message_bodies()');
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Account purge: conversations, AI runs and policies go with the store.
-- ---------------------------------------------------------------------------------------------
create or replace function internal.purge_due_account_deletions()
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_request app.account_deletion_requests;
  v_count integer := 0;
begin
  perform set_config('aisellia.purge', 'on', true);
  for v_request in
    select * from app.account_deletion_requests
     where status = 'pending' and execute_after <= now()
     order by execute_after
     for update skip locked
  loop
    if v_request.store_id is not null then
      update app.messages set suggestion_id = null where store_id = v_request.store_id;
      delete from app.messages where store_id = v_request.store_id;
      delete from app.reply_suggestions where store_id = v_request.store_id;
      delete from app.ai_runs where store_id = v_request.store_id;
      delete from app.conversations where store_id = v_request.store_id;
      delete from app.store_policies where store_id = v_request.store_id;
      delete from app.ai_requests where store_id = v_request.store_id;
      delete from app.ai_draft_grants where store_id = v_request.store_id;
      delete from app.cod_collections where store_id = v_request.store_id;
      delete from app.return_lines where store_id = v_request.store_id;
      delete from app.order_status_events where store_id = v_request.store_id;
      delete from app.inventory_movements where store_id = v_request.store_id;
      delete from app.order_items where store_id = v_request.store_id;
      delete from app.orders where store_id = v_request.store_id;
      delete from app.product_images where store_id = v_request.store_id;
      delete from app.product_variants where store_id = v_request.store_id;
      delete from app.products where store_id = v_request.store_id;
      delete from app.delivery_zones where store_id = v_request.store_id;
      delete from app.audit_events where store_id = v_request.store_id;
      delete from app.store_members where store_id = v_request.store_id;
      delete from app.stores where id = v_request.store_id;
    end if;
    delete from app.idempotency_keys where user_id = v_request.user_id;
    delete from auth.users where id = v_request.user_id;   -- profiles cascade
    update app.account_deletion_requests
       set status = 'done', executed_at = now()
     where id = v_request.id;
    v_count := v_count + 1;
  end loop;
  perform set_config('aisellia.purge', 'off', true);
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- "Delete this customer" also clears the conversations that led to their orders.
-- ---------------------------------------------------------------------------------------------
create or replace function api.anonymize_customer(p_store_id uuid, p_phone text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_member app.store_members;
  v_phone text := btrim(coalesce(p_phone, ''));
  v_hash text;
  v_result jsonb;
  v_done uuid[];
  v_skipped integer;
  v_id uuid;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  v_member := app.require_permission(p_store_id, 'customers.delete');
  if v_member.role <> 'owner' then
    perform app.fail('FORBIDDEN');
  end if;
  if v_phone !~ '^\+9647[0-9]{9}$' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"phone": "invalid"}}');
  end if;
  -- The request names the customer, so only its hash is kept with the key.
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'phone_hash', app.secret_hash(v_phone)));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'anonymize_customer', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  -- Orders still being handled keep their contact data until they are delivered or closed.
  select count(*) into v_skipped from app.orders
   where store_id = p_store_id and customer_anonymized_at is null
     and (customer_phone = v_phone or customer_phone2 = v_phone)
     and status not in ('delivered', 'rejected', 'cancelled', 'returned');

  select coalesce(array_agg(id order by number), '{}') into v_done from (
    select id, number from app.orders
     where store_id = p_store_id and customer_anonymized_at is null
       and (customer_phone = v_phone or customer_phone2 = v_phone)
       and status in ('delivered', 'rejected', 'cancelled', 'returned')
     order by id for update) s;

  update app.orders set customer_name = null, customer_phone = null, customer_phone2 = null, area = null,
                        landmark = null, address_details = null, customer_note = null,
                        customer_anonymized_at = now(), version = version + 1, updated_at = now()
   where id = any (v_done);
  foreach v_id in array v_done loop
    perform app.order_recompute(v_id);   -- search fields no longer hold the name or phone
  end loop;

  perform set_config('aisellia.redact', 'on', true);
  update app.audit_events
     set before = app.redact_customer(before), after = app.redact_customer(after)
   where store_id = p_store_id and entity_type = 'order' and entity_id = any (v_done);
  perform set_config('aisellia.redact', 'off', true);

  -- Conversations that led to these orders hold the same contact data: their text goes too
  -- (metadata stays, so the order keeps its link).
  update app.messages m set body = null, body_purged_at = now()
    from app.conversations c
   where c.id = m.conversation_id and c.store_id = p_store_id and c.order_id = any (v_done) and m.body is not null;
  update app.reply_suggestions s set text_rendered = null, facts_used = '[]', conflicts = '[]'
    from app.conversations c
   where c.id = s.conversation_id and c.store_id = p_store_id and c.order_id = any (v_done);
  update app.ai_runs r set output_json = null, validation_errors = null, pii_map = null
    from app.conversations c
   where c.id = r.conversation_id and c.store_id = p_store_id and c.order_id = any (v_done);
  update app.conversations set customer_label = null where store_id = p_store_id and order_id = any (v_done);

  -- Stored answers of earlier requests repeat the contact data: they go too.
  delete from app.idempotency_keys
   where response -> 'data' ->> 'id' = any (array(select x::text from unnest(v_done) x))
      or response -> 'data' ->> 'order_id' = any (array(select x::text from unnest(v_done) x));

  perform app.audit(p_store_id, 'customer.anonymize', 'store', p_store_id, null,
                    jsonb_build_object('orders', cardinality(v_done), 'skipped_in_progress', v_skipped));

  v_result := app.ok(jsonb_build_object('anonymized', cardinality(v_done), 'skipped_in_progress', v_skipped,
                                        'order_ids', to_jsonb(v_done)));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'anonymize_customer', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('anonymize_customer', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------
revoke all on function
  app.ai_text(text, text), app.format_money(bigint, text, text), app.western_digits(text), app.normalize_phone(text),
  app.pii_minimise(text, jsonb), app.variant_availability(app.products, app.product_variants),
  app.looks_like_manipulation(text), app.reply_guard(text), app.ai_build_context(app.ai_runs), app.ai_enum(text),
  app.ai_segments_errors(jsonb, text), app.ai_str_ok(jsonb, integer), app.ai_output_errors(jsonb),
  app.ai_render_fact(app.ai_runs, text, text, text), app.ai_render(app.ai_runs, jsonb, text),
  app.ai_write_lines(app.ai_runs, uuid, jsonb), app.ai_merge_draft(app.ai_runs, jsonb, jsonb),
  app.ai_record_meta(uuid, jsonb), app.ai_lock_running_run(uuid), app.suggestion_json(app.reply_suggestions),
  app.order_json_base(uuid), app.order_json(uuid),
  api.request_ai_assist(uuid, uuid, text, uuid), api.ai_claim_run(uuid), api.ai_complete_run(uuid, jsonb, jsonb),
  api.ai_fail_run(uuid, text, text, jsonb), api.ai_run_state(uuid),
  api.copy_suggestion(uuid, uuid, text, uuid), api.mark_message_sent(uuid, uuid), api.dismiss_suggestion(uuid, uuid),
  api.get_ai_run(uuid, uuid), api.ai_usage(uuid, integer), api.delete_conversation(uuid, uuid),
  internal.purge_ai_run_outputs(interval), internal.purge_message_bodies(interval)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker;

grant execute on function
  api.request_ai_assist(uuid, uuid, text, uuid), api.copy_suggestion(uuid, uuid, text, uuid),
  api.mark_message_sent(uuid, uuid), api.dismiss_suggestion(uuid, uuid), api.get_ai_run(uuid, uuid),
  api.ai_usage(uuid, integer), api.delete_conversation(uuid, uuid)
to authenticated;
grant execute on function
  api.ai_claim_run(uuid), api.ai_complete_run(uuid, jsonb, jsonb), api.ai_fail_run(uuid, text, text, jsonb),
  api.ai_run_state(uuid)
to aisellia_ai_worker;
grant execute on function internal.purge_ai_run_outputs(interval), internal.purge_message_bodies(interval) to service_role;
