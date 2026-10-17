-- Aisellia — Phase 8: conversations, messages, written store policies and the AI switch.
--
-- Phase 1 US-020–022, §4.2 and BR-45–49; Phase 3 backend-and-data-model.md §4.3. Rules:
--   * No messaging channel is connected in Phase 8. A conversation is either imported by the
--     seller (pasted from Instagram, WhatsApp, …; labelled with its source) or a sandbox test
--     conversation. Nothing here sends a message to anybody.
--   * Every message records who wrote it: `in` messages are customer text pasted by the seller
--     (origin `imported`); `out` messages are the seller's earlier replies pasted in (`imported`),
--     replies the seller wrote and says they sent (`seller_written`, state `marked_sent`) or AI
--     suggestions the seller copied (`ai_reply_copied`, state `copied` until the seller marks it
--     sent). No message is ever `sent` by the system.
--   * Written policies are the only allowed source for policy answers (Phase 1 §8.2).
--   * Store members only; every function derives access from the caller's membership.

alter table app.stores add column ai_enabled boolean not null default true;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------
create table app.store_policies (
  id         uuid primary key default gen_random_uuid(),
  store_id   uuid not null references app.stores (id),
  topic      text not null check (topic in ('delivery', 'returns', 'exchange', 'payment', 'warranty', 'hours', 'other')),
  body       text not null check (char_length(body) between 1 and 1000 and body = btrim(body)),
  active     boolean not null default true,
  version    integer not null default 1 check (version >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (store_id, id)
);
create index store_policies_store on app.store_policies (store_id, topic);

create table app.conversations (
  id                 uuid primary key default gen_random_uuid(),
  store_id           uuid not null references app.stores (id),
  customer_label     text check (customer_label is null or (char_length(customer_label) between 1 and 60
                                                             and customer_label = btrim(customer_label))),
  source             text not null check (source in ('instagram', 'whatsapp', 'messenger', 'telegram', 'phone', 'other', 'sandbox')),
  is_sandbox         boolean not null default false,
  status             text not null default 'needs_reply' check (status in ('needs_reply', 'needs_you', 'waiting', 'closed')),
  escalation_reasons text[] not null default '{}',
  ai_paused          boolean not null default false,
  -- Structured state kept by the AI pipeline (validated server-side; never trusted as fact).
  intent             text,
  missing_fields     text[] not null default '{}',
  clarify_counts     jsonb not null default '{}'::jsonb,
  order_id           uuid,
  created_by         uuid,
  version            integer not null default 1 check (version >= 1),
  last_activity_at   timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (store_id, id),
  foreign key (store_id, order_id) references app.orders (store_id, id),
  constraint conversations_sandbox check (is_sandbox = (source = 'sandbox'))
);
create index conversations_store_activity on app.conversations (store_id, status, last_activity_at desc);

create table app.messages (
  id              uuid primary key default gen_random_uuid(),
  seq             bigint generated always as identity,
  store_id        uuid not null,
  conversation_id uuid not null,
  direction       text not null check (direction in ('in', 'out')),
  origin          text not null check (origin in ('imported', 'seller_written', 'ai_reply_copied')),
  body            text check (body is null or char_length(body) between 1 and 4000),
  state           text not null check (state in ('imported', 'copied', 'marked_sent')),
  edited          boolean not null default false,
  suggestion_id   uuid,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  body_purged_at  timestamptz,
  unique (store_id, id),
  foreign key (store_id, conversation_id) references app.conversations (store_id, id),
  constraint messages_origin check (
    (direction = 'in' and origin = 'imported' and state = 'imported')
    or (direction = 'out' and origin = 'imported' and state = 'imported')
    or (direction = 'out' and origin = 'seller_written' and state = 'marked_sent')
    or (direction = 'out' and origin = 'ai_reply_copied' and state in ('copied', 'marked_sent'))),
  constraint messages_body_present check ((body is null) = (body_purged_at is not null))
);
create index messages_conversation on app.messages (conversation_id, seq);

alter table app.store_policies enable row level security;
alter table app.conversations enable row level security;
alter table app.messages enable row level security;
-- No policies and no grants: only the definer functions below read or write them.
revoke all on app.store_policies, app.conversations, app.messages from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- Shapes
-- ---------------------------------------------------------------------------------------------
create function app.policy_json(p app.store_policies)
returns jsonb language sql immutable
as $$
  select jsonb_build_object('id', p.id, 'topic', p.topic, 'body', p.body, 'active', p.active,
                            'version', p.version, 'updated_at', p.updated_at);
$$;

create function app.message_json(m app.messages)
returns jsonb language sql stable
as $$
  select jsonb_build_object('id', m.id, 'direction', m.direction, 'origin', m.origin, 'body', m.body,
                            'state', m.state, 'edited', m.edited, 'suggestion_id', m.suggestion_id,
                            'author', case when m.origin = 'imported' then null else app.actor_label(m.created_by) end,
                            'created_at', m.created_at, 'body_purged', m.body_purged_at is not null);
$$;

create function app.conversation_summary_json(c app.conversations)
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'id', c.id, 'customer_label', c.customer_label, 'source', c.source, 'is_sandbox', c.is_sandbox,
    'status', c.status, 'escalation_reasons', to_jsonb(c.escalation_reasons), 'ai_paused', c.ai_paused,
    'intent', c.intent, 'missing_fields', to_jsonb(c.missing_fields),
    'last_activity_at', c.last_activity_at, 'created_at', c.created_at, 'version', c.version,
    'last_message', (select jsonb_build_object('direction', m.direction, 'origin', m.origin,
                                               'preview', left(m.body, 120), 'created_at', m.created_at)
                       from app.messages m where m.conversation_id = c.id order by m.seq desc limit 1),
    'order', (select jsonb_build_object('id', o.id, 'number', o.number, 'status', o.status, 'is_test', o.is_test)
                from app.orders o where o.id = c.order_id));
$$;

-- Validates a list of messages to import: 1–20 items {direction, body}; returns field errors.
create function app.import_errors(p_messages jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
  v_errors jsonb := '{}'::jsonb;
  v_m jsonb;
  v_i integer := 0;
  v_total integer := 0;
begin
  if p_messages is null or jsonb_typeof(p_messages) <> 'array' or jsonb_array_length(p_messages) = 0 then
    return '{"messages": "required"}'::jsonb;
  end if;
  if jsonb_array_length(p_messages) > 20 then
    return '{"messages": "too_many"}'::jsonb;
  end if;
  for v_m in select * from jsonb_array_elements(p_messages) loop
    if jsonb_typeof(v_m) <> 'object' or exists (select 1 from jsonb_object_keys(v_m) k where k not in ('direction', 'body')) then
      v_errors := v_errors || jsonb_build_object('messages.' || v_i, 'invalid');
    elsif coalesce(v_m ->> 'direction', '') not in ('in', 'out') then
      v_errors := v_errors || jsonb_build_object('messages.' || v_i || '.direction', 'invalid');
    elsif jsonb_typeof(v_m -> 'body') <> 'string' or btrim(v_m ->> 'body') = '' then
      v_errors := v_errors || jsonb_build_object('messages.' || v_i || '.body', 'required');
    elsif char_length(btrim(v_m ->> 'body')) > 4000 then
      v_errors := v_errors || jsonb_build_object('messages.' || v_i || '.body', 'too_long');
    else
      v_total := v_total + char_length(btrim(v_m ->> 'body'));
    end if;
    v_i := v_i + 1;
  end loop;
  if v_total > 20000 then
    v_errors := v_errors || '{"messages": "too_long"}'::jsonb;
  end if;
  return v_errors;
end;
$$;

-- Appends validated messages; an inbound message (re)opens the conversation as "Needs reply".
create function app.append_messages(p_conversation app.conversations, p_messages jsonb, p_uid uuid)
returns integer
language plpgsql
as $$
declare
  v_count integer;
  v_inbound boolean;
begin
  insert into app.messages (store_id, conversation_id, direction, origin, body, state, created_by)
  select p_conversation.store_id, p_conversation.id, m ->> 'direction', 'imported', btrim(m ->> 'body'), 'imported', p_uid
    from jsonb_array_elements(p_messages) with ordinality x(m, n)
   order by n;
  get diagnostics v_count = row_count;
  v_inbound := exists (select 1 from jsonb_array_elements(p_messages) m where m ->> 'direction' = 'in');
  update app.conversations
     set last_activity_at = now(), updated_at = now(), version = version + 1,
         status = case when v_inbound and status <> 'needs_you' then 'needs_reply' else status end
   where id = p_conversation.id;
  return v_count;
end;
$$;

-- The caller's conversation in this store, locked; NOT_FOUND otherwise.
create function app.lock_conversation(p_store_id uuid, p_conversation_id uuid)
returns app.conversations
language plpgsql
as $$
declare
  v_c app.conversations;
begin
  select * into v_c from app.conversations where id = p_conversation_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  return v_c;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Conversations
-- ---------------------------------------------------------------------------------------------
create function api.list_conversations(p_store_id uuid, p_filter text default 'open',
                                       p_limit integer default 30, p_offset integer default 0)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 50);
  v_offset integer := least(greatest(coalesce(p_offset, 0), 0), 100000);
  v_items jsonb;
  v_count integer;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  if coalesce(p_filter, 'open') not in ('open', 'needs_reply', 'needs_you', 'waiting', 'closed', 'sandbox', 'all') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"filter": "invalid"}}');
  end if;
  with rows as (
    select c.id, row_number() over (order by c.last_activity_at desc, c.id) as ord
      from app.conversations c
     where c.store_id = p_store_id
       and case coalesce(p_filter, 'open')
             when 'open' then c.status <> 'closed' and not c.is_sandbox
             when 'sandbox' then c.is_sandbox
             when 'all' then true
             else c.status = p_filter and not c.is_sandbox end
  )
  select coalesce(jsonb_agg(app.conversation_summary_json(c) order by r.ord)
           filter (where r.ord > v_offset and r.ord <= v_offset + v_limit), '[]'::jsonb),
         count(*)::integer
    into v_items, v_count
    from rows r join app.conversations c on c.id = r.id;
  return app.ok(jsonb_build_object(
    'items', v_items, 'total', v_count, 'has_more', v_count > v_offset + v_limit,
    'counts', (select jsonb_build_object(
                 'needs_reply', count(*) filter (where status = 'needs_reply' and not is_sandbox),
                 'needs_you', count(*) filter (where status = 'needs_you' and not is_sandbox),
                 'waiting', count(*) filter (where status = 'waiting' and not is_sandbox))
                 from app.conversations where store_id = p_store_id)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_conversations', v_state, v_code);
end;
$$;

-- Full conversation for the conversation screen (Phase 8 AI fields are added by the AI migration).
create function app.conversation_json(p_conversation_id uuid)
returns jsonb language sql stable
as $$
  select app.conversation_summary_json(c) || jsonb_build_object(
    'messages', coalesce((select jsonb_agg(app.message_json(m) order by m.seq)
                            from (select * from app.messages where conversation_id = c.id order by seq desc limit 200) m),
                         '[]'::jsonb),
    'message_count', (select count(*) from app.messages where conversation_id = c.id))
  from app.conversations c where c.id = p_conversation_id;
$$;

create function api.get_conversation(p_store_id uuid, p_conversation_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  if not exists (select 1 from app.conversations where id = p_conversation_id and store_id = p_store_id) then
    perform app.fail('NOT_FOUND');
  end if;
  return app.ok(app.conversation_json(p_conversation_id));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('get_conversation', v_state, v_code);
end;
$$;

-- A new conversation with the customer's first messages (US-020) or a sandbox (US-021).
create function api.create_conversation(p_store_id uuid, p_source text, p_customer_label text, p_messages jsonb,
                                        p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_label text := nullif(btrim(coalesce(p_customer_label, '')), '');
  v_errors jsonb := '{}'::jsonb;
  v_hash text;
  v_result jsonb;
  v_conv app.conversations;
  v_count integer;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  if coalesce(p_source, '') not in ('instagram', 'whatsapp', 'messenger', 'telegram', 'phone', 'other', 'sandbox') then
    v_errors := v_errors || '{"source": "invalid"}';
  end if;
  if v_label is not null and char_length(v_label) > 60 then
    v_errors := v_errors || '{"customer_label": "too_long"}';
  end if;
  v_errors := v_errors || app.import_errors(p_messages);
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;
  -- Message text is customer data: only its hash is kept with the key.
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'source', p_source, 'label', v_label,
                                                'messages', app.secret_hash(p_messages::text)));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'create_conversation', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  perform 1 from app.stores where id = p_store_id for update;
  select count(*) into v_count from app.conversations
   where store_id = p_store_id and created_at > now() - interval '24 hours';
  if v_count >= 500 then
    perform app.fail('RATE_LIMITED', '{"scope": "store", "retry_after_seconds": 3600, "limit": 500}');
  end if;
  insert into app.conversations (store_id, customer_label, source, is_sandbox, created_by)
  values (p_store_id, v_label, p_source, p_source = 'sandbox', v_uid)
  returning * into v_conv;
  v_count := app.append_messages(v_conv, p_messages, v_uid);
  perform app.audit(p_store_id, 'conversation.create', 'conversation', v_conv.id, null,
                    jsonb_build_object('source', p_source, 'messages', v_count));

  v_result := app.ok(jsonb_build_object('id', v_conv.id, 'messages_added', v_count));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'create_conversation', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('create_conversation', v_state, v_code);
end;
$$;

create function api.import_messages(p_store_id uuid, p_conversation_id uuid, p_messages jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_errors jsonb;
  v_hash text;
  v_result jsonb;
  v_conv app.conversations;
  v_count integer;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  v_errors := app.import_errors(p_messages);
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'conversation_id', p_conversation_id,
                                                'messages', app.secret_hash(p_messages::text)));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'import_messages', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  v_conv := app.lock_conversation(p_store_id, p_conversation_id);
  if (select count(*) from app.messages where conversation_id = v_conv.id) + jsonb_array_length(p_messages) > 2000 then
    perform app.fail('LIMIT_EXCEEDED', '{"max_messages": 2000}');
  end if;
  v_count := app.append_messages(v_conv, p_messages, v_uid);
  if v_conv.status = 'closed' and exists (select 1 from jsonb_array_elements(p_messages) m where m ->> 'direction' = 'in') then
    perform app.audit(p_store_id, 'conversation.reopen', 'conversation', v_conv.id, null, null);
  end if;
  v_result := app.ok(jsonb_build_object('id', v_conv.id, 'messages_added', v_count));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'import_messages', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('import_messages', v_state, v_code);
end;
$$;

-- A reply the seller wrote and sent themselves (outside Aisellia): recorded as marked sent by them.
create function api.record_seller_reply(p_store_id uuid, p_conversation_id uuid, p_body text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_body text := btrim(coalesce(p_body, ''));
  v_hash text;
  v_result jsonb;
  v_conv app.conversations;
  v_msg app.messages;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  if v_body = '' or char_length(v_body) > 4000 then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object(
      'body', case when v_body = '' then 'required' else 'too_long' end)));
  end if;
  v_hash := app.request_hash(jsonb_build_object('conversation_id', p_conversation_id, 'body', app.secret_hash(v_body)));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'record_seller_reply', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  v_conv := app.lock_conversation(p_store_id, p_conversation_id);
  insert into app.messages (store_id, conversation_id, direction, origin, body, state, created_by)
  values (p_store_id, v_conv.id, 'out', 'seller_written', v_body, 'marked_sent', v_uid)
  returning * into v_msg;
  update app.conversations
     set status = case when status = 'closed' then status else 'waiting' end,
         last_activity_at = now(), updated_at = now(), version = version + 1
   where id = v_conv.id;
  v_result := app.ok(jsonb_build_object('id', v_msg.id, 'conversation_id', v_conv.id));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'record_seller_reply', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('record_seller_reply', v_state, v_code);
end;
$$;

-- Seller-controlled conversation settings and status. p_fields: customer_label, ai_paused, status
-- (needs_reply | waiting | closed). Leaving "Needs you" clears the escalation reasons.
create function api.update_conversation(p_store_id uuid, p_conversation_id uuid, p_expected_version integer,
                                        p_fields jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_conv app.conversations;
  v_errors jsonb := '{}'::jsonb;
  v_label text;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'conversations.manage');
  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"fields": "required"}}');
  end if;
  select coalesce(jsonb_object_agg(k, 'unknown'), '{}'::jsonb) into v_errors
    from jsonb_object_keys(p_fields) k where k not in ('customer_label', 'ai_paused', 'status');
  if p_fields ? 'customer_label' then
    v_label := nullif(btrim(coalesce(p_fields ->> 'customer_label', '')), '');
    if v_label is not null and char_length(v_label) > 60 then
      v_errors := v_errors || '{"customer_label": "too_long"}';
    end if;
  end if;
  if p_fields ? 'ai_paused' and jsonb_typeof(p_fields -> 'ai_paused') <> 'boolean' then
    v_errors := v_errors || '{"ai_paused": "invalid"}';
  end if;
  if p_fields ? 'status' and coalesce(p_fields ->> 'status', '') not in ('needs_reply', 'waiting', 'closed') then
    v_errors := v_errors || '{"status": "invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;
  v_conv := app.lock_conversation(p_store_id, p_conversation_id);
  if p_expected_version is null or v_conv.version <> p_expected_version then
    perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_conv.version));
  end if;
  update app.conversations set
    customer_label = case when p_fields ? 'customer_label' then v_label else customer_label end,
    ai_paused = case when p_fields ? 'ai_paused' then (p_fields ->> 'ai_paused')::boolean else ai_paused end,
    status = coalesce(p_fields ->> 'status', status),
    escalation_reasons = case when p_fields ? 'status' then '{}' else escalation_reasons end,
    version = version + 1, updated_at = now()
  where id = v_conv.id;
  if p_fields ? 'status' and p_fields ->> 'status' is distinct from v_conv.status then
    perform app.audit(p_store_id, 'conversation.status', 'conversation', v_conv.id,
                      jsonb_build_object('status', v_conv.status, 'escalation_reasons', to_jsonb(v_conv.escalation_reasons)),
                      jsonb_build_object('status', p_fields ->> 'status'));
  end if;
  return app.ok(app.conversation_json(v_conv.id));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('update_conversation', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Written policies (the only allowed source for policy answers)
-- ---------------------------------------------------------------------------------------------
create function api.list_policies(p_store_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  return app.ok(jsonb_build_object(
    'items', coalesce((select jsonb_agg(app.policy_json(p) order by p.topic, p.created_at)
                         from app.store_policies p where p.store_id = p_store_id), '[]'::jsonb),
    'ai_enabled', (select ai_enabled from app.stores where id = p_store_id)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_policies', v_state, v_code);
end;
$$;

create function api.upsert_policy(p_store_id uuid, p_policy_id uuid, p_expected_version integer, p_topic text,
                                  p_body text, p_active boolean, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_body text := btrim(coalesce(p_body, ''));
  v_errors jsonb := '{}'::jsonb;
  v_hash text;
  v_result jsonb;
  v_old app.store_policies;
  v_new app.store_policies;
  v_count integer;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'settings.manage');
  if coalesce(p_topic, '') not in ('delivery', 'returns', 'exchange', 'payment', 'warranty', 'hours', 'other') then
    v_errors := v_errors || '{"topic": "invalid"}';
  end if;
  if v_body = '' then
    v_errors := v_errors || '{"body": "required"}';
  elsif char_length(v_body) > 1000 then
    v_errors := v_errors || '{"body": "too_long"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'policy_id', p_policy_id, 'version', p_expected_version,
                                                'topic', p_topic, 'body', v_body, 'active', coalesce(p_active, true)));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'upsert_policy', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  if p_policy_id is null then
    perform 1 from app.stores where id = p_store_id for update;
    select count(*) into v_count from app.store_policies where store_id = p_store_id;
    if v_count >= 30 then
      perform app.fail('LIMIT_EXCEEDED', '{"max_policies": 30}');
    end if;
    insert into app.store_policies (store_id, topic, body, active)
    values (p_store_id, p_topic, v_body, coalesce(p_active, true))
    returning * into v_new;
    perform app.audit(p_store_id, 'policy.create', 'store_policy', v_new.id, null, app.policy_json(v_new));
  else
    select * into v_old from app.store_policies where id = p_policy_id and store_id = p_store_id for update;
    if not found then
      perform app.fail('NOT_FOUND');
    end if;
    if p_expected_version is null or v_old.version <> p_expected_version then
      perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_old.version));
    end if;
    update app.store_policies
       set topic = p_topic, body = v_body, active = coalesce(p_active, true), version = version + 1, updated_at = now()
     where id = v_old.id
    returning * into v_new;
    perform app.audit(p_store_id, 'policy.update', 'store_policy', v_new.id, app.policy_json(v_old), app.policy_json(v_new));
  end if;
  v_result := app.ok(app.policy_json(v_new));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'upsert_policy', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('upsert_policy', v_state, v_code);
end;
$$;

create function api.delete_policy(p_store_id uuid, p_policy_id uuid, p_expected_version integer)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_old app.store_policies;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'settings.manage');
  select * into v_old from app.store_policies where id = p_policy_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if p_expected_version is null or v_old.version <> p_expected_version then
    perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_old.version));
  end if;
  delete from app.store_policies where id = v_old.id;
  perform app.audit(p_store_id, 'policy.delete', 'store_policy', v_old.id, app.policy_json(v_old), null);
  return app.ok(jsonb_build_object('id', v_old.id, 'deleted', true));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('delete_policy', v_state, v_code);
end;
$$;

-- The store-wide AI switch (owner). Off: no AI run starts; everything else keeps working.
create function api.set_ai_enabled(p_store_id uuid, p_enabled boolean)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_member app.store_members;
  v_old boolean;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  v_member := app.require_permission(p_store_id, 'ai.manage');
  if v_member.role <> 'owner' then
    perform app.fail('FORBIDDEN');
  end if;
  if p_enabled is null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"enabled": "required"}}');
  end if;
  select ai_enabled into v_old from app.stores where id = p_store_id for update;
  if v_old is distinct from p_enabled then
    update app.stores set ai_enabled = p_enabled, updated_at = now() where id = p_store_id;
    perform app.audit(p_store_id, 'store.ai_enabled', 'store', p_store_id,
                      jsonb_build_object('ai_enabled', v_old), jsonb_build_object('ai_enabled', p_enabled));
  end if;
  return app.ok(jsonb_build_object('ai_enabled', p_enabled));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('set_ai_enabled', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------
revoke all on function
  app.policy_json(app.store_policies), app.message_json(app.messages), app.conversation_summary_json(app.conversations),
  app.import_errors(jsonb), app.append_messages(app.conversations, jsonb, uuid), app.lock_conversation(uuid, uuid),
  app.conversation_json(uuid),
  api.list_conversations(uuid, text, integer, integer), api.get_conversation(uuid, uuid),
  api.create_conversation(uuid, text, text, jsonb, uuid), api.import_messages(uuid, uuid, jsonb, uuid),
  api.record_seller_reply(uuid, uuid, text, uuid), api.update_conversation(uuid, uuid, integer, jsonb),
  api.list_policies(uuid), api.upsert_policy(uuid, uuid, integer, text, text, boolean, uuid),
  api.delete_policy(uuid, uuid, integer), api.set_ai_enabled(uuid, boolean)
from public, anon, authenticated, aisellia_ai;

grant execute on function
  api.list_conversations(uuid, text, integer, integer), api.get_conversation(uuid, uuid),
  api.create_conversation(uuid, text, text, jsonb, uuid), api.import_messages(uuid, uuid, jsonb, uuid),
  api.record_seller_reply(uuid, uuid, text, uuid), api.update_conversation(uuid, uuid, integer, jsonb),
  api.list_policies(uuid), api.upsert_policy(uuid, uuid, integer, text, text, boolean, uuid),
  api.delete_policy(uuid, uuid, integer), api.set_ai_enabled(uuid, boolean)
to authenticated;
