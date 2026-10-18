-- Phase 9: WhatsApp message templates, for messages outside the 24-hour customer-service window
-- (official: free-form text only inside the window; approved templates outside it; send with
-- type "template", template.name, template.language.code, components[{type: body, parameters[{type:
-- text, text}]}]; see provider-verification.md).
--
--  * app.message_templates: the templates of a connected WhatsApp number, synced from Meta by the
--    worker (sender role: api.channel_due_template_syncs / api.channel_store_templates). Only APPROVED
--    UTILITY templates with a plain-text body are usable; MARKETING ones are never offered (they need
--    separate opt-in rules and are not part of this version).
--  * api.list_templates / api.send_template: the seller picks a template and fills its parameters; the
--    SERVER renders the exact text, which is authorized like any message: hashed, audited, immutable.
--    Templates skip only the window check; every other rule (permission, blocked or anonymised contact,
--    verified capability, rate limits) applies. Parameters: 1–300 characters, no line breaks or tabs,
--    no run of 4 spaces (WhatsApp's rule), no "{{".
--  * The sender re-renders the template from the stored body and parameters and refuses to submit
--    unless it hashes to the authorized text (the exact-text guarantee for templates).

create table app.message_templates (
  id            uuid primary key default gen_random_uuid(),
  store_id      uuid not null,
  connection_id uuid not null,
  name          text not null check (name ~ '^[a-z0-9_]+$' and char_length(name) <= 512),
  language      text not null check (language ~ '^[a-z]{2,3}(_[A-Z]{2})?$'),
  category      text not null,
  status        text not null,
  body_text     text check (body_text is null or char_length(body_text) between 1 and 1024),
  param_count   integer not null default 0 check (param_count between 0 and 20),
  usable        boolean not null default false,
  synced_at     timestamptz not null default now(),
  unique (store_id, id),
  unique (connection_id, name, language),
  foreign key (store_id, connection_id) references app.connections (store_id, id)
);
alter table app.message_templates enable row level security;
revoke all on app.message_templates from public, anon, authenticated;
alter table app.connections add column templates_synced_at timestamptz;

alter table app.send_requests drop constraint send_requests_kind_check,
  add constraint send_requests_kind_check check (kind in ('reply', 'order_confirmation', 'template')),
  add column template_id uuid references app.message_templates (id) on delete set null,
  add column template_params jsonb check (template_params is null or jsonb_typeof(template_params) = 'array'),
  add constraint send_requests_template check ((kind = 'template') = (template_params is not null));

-- {{1}}..{{n}} replaced by the parameters (no parameter may contain "{{", so the order of
-- replacement cannot matter; the sender renders the same way).
create function app.render_template(p_body text, p_params jsonb)
returns text
language plpgsql immutable
as $$
declare
  v text := p_body;
begin
  for i in 1 .. coalesce(jsonb_array_length(p_params), 0) loop
    v := replace(v, '{{' || i || '}}', p_params ->> (i - 1));
  end loop;
  return v;
end;
$$;

create function app.template_param_ok(p text)
returns boolean
language sql immutable
as $$
  select p is not null and char_length(p) between 1 and 300 and p !~ '[\n\r\t]' and p !~ ' {4}' and position('{{' in p) = 0
$$;

drop function app.channel_authorize_send(uuid, uuid, app.conversations, text, uuid, text, uuid, uuid);
create function app.channel_authorize_send(p_store_id uuid, p_uid uuid, p_conv app.conversations, p_text text,
                                           p_suggestion_id uuid, p_kind text, p_order_id uuid, p_resend_of uuid,
                                           p_template app.message_templates default null, p_params jsonb default null)
returns jsonb
language plpgsql
as $$
declare
  v_conn app.connections;
  v_provider app.providers;
  v_contact app.contacts;
  v_window jsonb;
  v_max jsonb;
  v_limit integer;
  v_sugg app.reply_suggestions;
  v_order app.orders;
  v_msg_id uuid;
  v_req app.send_requests;
  v_count integer;
  v_hash text;
begin
  if p_conv.connection_id is null then
    perform app.fail('NOT_A_LIVE_CONVERSATION');
  end if;
  select * into v_conn from app.connections where id = p_conv.connection_id and store_id = p_store_id;
  if v_conn.state <> 'connected' then
    perform app.fail('CHANNEL_NOT_CONNECTED', jsonb_build_object('state', v_conn.state));
  end if;
  select * into v_provider from app.providers where id = v_conn.provider_id;
  if v_provider.status in ('planned', 'suspended') or (v_provider.status = 'in_development' and not v_conn.is_test) then
    perform app.fail('CHANNEL_UNAVAILABLE', jsonb_build_object('provider_status', v_provider.status));
  end if;
  select * into v_contact from app.contacts where id = p_conv.contact_id and store_id = p_store_id;
  if v_contact.blocked then
    perform app.fail('CONTACT_BLOCKED');
  end if;
  if v_contact.anonymized_at is not null then
    perform app.fail('CONTACT_ANONYMIZED');
  end if;
  -- Capabilities: outbound text must be VERIFIED; the window must be resolved (a number of hours,
  -- or a verified JSON null meaning "no window"). Anything missing or UNRESOLVED blocks sending.
  if app.provider_capability(v_conn.provider_id, 'outbound_text', true) is distinct from 'true'::jsonb then
    perform app.fail('CHANNEL_CAPABILITY_MISSING', '{"capability": "outbound_text"}');
  end if;
  v_window := app.provider_capability(v_conn.provider_id, 'reply_window_hours');
  if v_window is null then
    perform app.fail('CHANNEL_CAPABILITY_MISSING', '{"capability": "reply_window_hours"}');
  end if;
  -- An approved template may be sent outside the window (that is what templates are for).
  if p_template.id is null and jsonb_typeof(v_window) = 'number'
     and (v_contact.window_expires_at is null or v_contact.window_expires_at <= now()) then
    perform app.fail('REPLY_WINDOW_CLOSED', jsonb_build_object('closed_at', v_contact.window_expires_at));
  end if;
  v_max := app.provider_capability(v_conn.provider_id, 'max_text_length');
  v_limit := case when jsonb_typeof(v_max) = 'number' then (v_max #>> '{}')::integer else app.ai_limit('channel_text_max_default') end;
  -- The text is taken exactly as the seller wrote it: never trimmed, normalised or templated.
  if p_text is null or btrim(p_text) = '' or char_length(p_text) > least(v_limit, 4000) then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object('text', 'invalid'), 'max_length', least(v_limit, 4000)));
  end if;
  if coalesce(p_kind, 'reply') not in ('reply', 'order_confirmation', 'template')
     or (coalesce(p_kind, 'reply') = 'template') <> (p_template.id is not null) then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"kind": "invalid"}}');
  end if;
  if coalesce(p_kind, 'reply') = 'order_confirmation' then
    -- Confirmations only for this conversation's order once approved (BR-04), sent by this action.
    select * into v_order from app.orders where id = p_order_id and store_id = p_store_id;
    if not found or p_conv.order_id is distinct from p_order_id then
      perform app.fail('NOT_FOUND');
    end if;
    if v_order.status not in ('approved', 'processing', 'dispatched', 'delivered') then
      perform app.fail('ORDER_NOT_APPROVED', jsonb_build_object('status', v_order.status));
    end if;
    -- The text must be exactly the server's rendering of the order as it is now, in one of the
    -- supported languages: a confirmation can never carry other amounts, items or promises.
    if not exists (select 1 from unnest(array['en', 'ckb', 'ar']) l where app.order_confirmation_text(v_order, l) = p_text) then
      perform app.fail('CONFIRMATION_TEXT_MISMATCH');
    end if;
  elsif p_order_id is not null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"order_id": "only_for_confirmations"}}');
  end if;
  if p_suggestion_id is not null then
    select * into v_sugg from app.reply_suggestions where id = p_suggestion_id and store_id = p_store_id
       and conversation_id = p_conv.id and status in ('suggested', 'copied');
    if not found then
      perform app.fail('NOT_FOUND');
    end if;
  end if;
  select count(*) into v_count from app.send_requests where store_id = p_store_id and created_at > now() - interval '1 minute';
  if v_count >= app.ai_limit('channel_sends_per_store_per_minute') then
    perform app.fail('RATE_LIMITED', '{"scope": "send_minute", "retry_after_seconds": 60}');
  end if;
  select count(*) into v_count from app.send_requests where store_id = p_store_id and created_at > now() - interval '24 hours';
  if v_count >= app.ai_limit('channel_sends_per_store_per_day') then
    perform app.fail('RATE_LIMITED', '{"scope": "send_day", "retry_after_seconds": 3600}');
  end if;

  v_hash := app.sha256_hex(p_text);
  insert into app.messages (store_id, conversation_id, direction, origin, body, state, edited, suggestion_id, created_by,
                            connection_id, delivery_state)
  values (p_store_id, p_conv.id, 'out', 'seller_sent', p_text, 'live',
          v_sugg.id is not null and p_text is distinct from v_sugg.text_rendered, v_sugg.id, p_uid, v_conn.id, 'queued')
  returning id into v_msg_id;
  insert into app.send_requests (store_id, message_id, conversation_id, connection_id, contact_id, authorized_by, text_sha256,
                                 suggestion_id, ai_originated, edited, kind, order_id, resend_of, template_id, template_params)
  values (p_store_id, v_msg_id, p_conv.id, v_conn.id, v_contact.id, p_uid, v_hash, v_sugg.id, v_sugg.id is not null,
          v_sugg.id is not null and p_text is distinct from v_sugg.text_rendered, coalesce(p_kind, 'reply'), p_order_id, p_resend_of,
          p_template.id, case when p_template.id is not null then p_params end)
  returning * into v_req;
  update app.conversations set status = 'waiting', last_activity_at = now(), updated_at = now(), version = version + 1
   where id = p_conv.id and status <> 'needs_you';
  -- The audit names the person and the text's hash, never the text.
  perform app.audit(p_store_id, 'message.send_authorized', 'send_request', v_req.id, null,
                    jsonb_build_object('message_id', v_msg_id, 'conversation_id', p_conv.id, 'text_sha256', v_hash,
                                       'ai_originated', v_req.ai_originated, 'edited', v_req.edited, 'kind', v_req.kind,
                                       'order_id', p_order_id, 'suggestion_id', v_sugg.id, 'resend_of', p_resend_of,
                                       'template', p_template.name));
  return jsonb_build_object('send_request_id', v_req.id, 'message_id', v_msg_id, 'state', v_req.state, 'text_sha256', v_hash);
end;
$$;

create or replace function api.channel_claim_send(p_send_request_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_req app.send_requests;
  v_conn app.connections;
  v_provider app.providers;
  v_contact app.contacts;
  v_text text;
  v_cred text;
  v_tpl app.message_templates;
  v_code text;
  v_detail text;
  v_state text;
begin
  select * into v_req from app.send_requests where id = p_send_request_id for update;
  -- Only queued sends are claimable: `sending` and `unknown` never are (no blind resend).
  if not found or v_req.state <> 'queued' then
    perform app.fail('SEND_NOT_CLAIMABLE', jsonb_build_object('state', v_req.state));
  end if;
  if v_req.next_attempt_at is not null and v_req.next_attempt_at > now() then
    perform app.fail('SEND_NOT_CLAIMABLE', jsonb_build_object('reason', 'backoff', 'retry_at', v_req.next_attempt_at));
  end if;
  select * into v_conn from app.connections where id = v_req.connection_id;
  select * into v_provider from app.providers where id = v_conn.provider_id;
  if v_provider.status = 'suspended' then
    perform app.fail('SEND_NOT_CLAIMABLE', '{"reason": "provider_suspended"}');
  end if;
  if v_conn.state <> 'connected' or v_provider.status = 'planned'
     or (v_provider.status = 'in_development' and not v_conn.is_test) then
    update app.send_requests set state = 'failed', error_code = 'channel_unavailable', updated_at = now() where id = v_req.id;
    update app.messages set delivery_state = 'failed' where id = v_req.message_id;
    return app.err('SEND_NOT_CLAIMABLE', '{"reason": "channel_unavailable"}');
  end if;
  select body into v_text from app.messages where id = v_req.message_id;
  if v_text is null or app.sha256_hex(v_text) <> v_req.text_sha256 then
    update app.send_requests set state = 'failed', error_code = 'text_integrity', updated_at = now() where id = v_req.id;
    update app.messages set delivery_state = 'failed' where id = v_req.message_id;
    return app.err('TEXT_INTEGRITY', '{}'::jsonb);
  end if;
  if v_req.kind = 'template' then
    select * into v_tpl from app.message_templates where id = v_req.template_id;
    if v_tpl.id is null or not v_tpl.usable
       or app.sha256_hex(app.render_template(v_tpl.body_text, v_req.template_params)) <> v_req.text_sha256 then
      update app.send_requests set state = 'failed', error_code = 'template_unavailable', updated_at = now() where id = v_req.id;
      update app.messages set delivery_state = 'failed' where id = v_req.message_id;
      return app.err('SEND_NOT_CLAIMABLE', '{"reason": "template_unavailable"}');
    end if;
  end if;
  select * into v_contact from app.contacts where id = v_req.contact_id;
  if v_conn.credential_ref is not null then
    select decrypted_secret into v_cred from vault.decrypted_secrets where id = v_conn.credential_ref;
  end if;
  update app.send_requests set state = 'sending', attempts = attempts + 1, next_attempt_at = null,
                               claim_expires_at = now() + make_interval(secs => app.ai_limit('channel_send_claim_seconds')),
                               updated_at = now()
   where id = v_req.id;
  update app.messages set delivery_state = 'sending' where id = v_req.message_id;
  return app.ok(jsonb_build_object(
    'send_request_id', v_req.id, 'provider', v_conn.provider_id, 'account_id', v_conn.external_account_id,
    'recipient', v_contact.external_user_id, 'text', v_text, 'text_sha256', v_req.text_sha256,
    'credential', v_cred, 'attempt', v_req.attempts + 1, 'sender_name', v_conn.display_name,
    'template', case when v_tpl.id is not null then jsonb_build_object('name', v_tpl.name, 'language', v_tpl.language,
                                                                        'body_text', v_tpl.body_text, 'params', v_req.template_params) end));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_claim_send', v_state, v_code);
end;
$$;

create or replace function api.resolve_unknown_send(p_store_id uuid, p_send_request_id uuid, p_resolution text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_req app.send_requests;
  v_conv app.conversations;
  v_text text;
  v_hash text;
  v_result jsonb;
  v_new jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'messages.send');
  if p_resolution not in ('mark_sent', 'send_again') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"resolution": "invalid"}}');
  end if;
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'send_request_id', p_send_request_id,
                                                'resolution', p_resolution));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'resolve_unknown_send', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  select * into v_req from app.send_requests where id = p_send_request_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_req.state <> 'unknown' or v_req.resolution is not null then
    perform app.fail('SEND_NOT_UNKNOWN', jsonb_build_object('state', v_req.state));
  end if;
  if p_resolution = 'mark_sent' then
    update app.send_requests set state = 'sent', resolution = 'seller_marked_sent', resolved_by = v_uid, resolved_at = now(),
                                 updated_at = now()
     where id = v_req.id;
    update app.messages set delivery_state = 'sent' where id = v_req.message_id;
    v_new := jsonb_build_object('send_request_id', v_req.id, 'state', 'sent');
  else
    v_conv := app.lock_conversation(p_store_id, v_req.conversation_id);
    select body into v_text from app.messages where id = v_req.message_id;
    if v_text is null or app.sha256_hex(v_text) <> v_req.text_sha256 then
      perform app.fail('TEXT_INTEGRITY');
    end if;
    v_new := app.channel_authorize_send(p_store_id, v_uid, v_conv, v_text, null, v_req.kind, v_req.order_id, v_req.id,
                                        (select t from app.message_templates t where t.id = v_req.template_id and t.usable),
                                        v_req.template_params);
    update app.send_requests set resolution = 'sent_again', resolved_by = v_uid, resolved_at = now(), updated_at = now()
     where id = v_req.id;
  end if;
  perform app.audit(p_store_id, 'message.send_resolved', 'send_request', v_req.id, null,
                    jsonb_build_object('resolution', p_resolution, 'new_send_request_id', v_new ->> 'send_request_id'));
  v_result := app.ok(v_new);
  perform app.idempotency_save(v_uid, p_idempotency_key, 'resolve_unknown_send', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('resolve_unknown_send', v_state, v_code);
end;
$$;

-- Templates the seller can use in a conversation (approved, utility, plain text) and whether the
-- customer-service window is closed (the app offers templates then).
create function api.list_templates(p_store_id uuid, p_conversation_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_conv app.conversations;
  v_contact app.contacts;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'messages.send');
  select * into v_conv from app.conversations where id = p_conversation_id and store_id = p_store_id;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  select * into v_contact from app.contacts where id = v_conv.contact_id;
  return app.ok(jsonb_build_object(
    'window_open', v_contact.window_expires_at is not null and v_contact.window_expires_at > now(),
    'window_expires_at', v_contact.window_expires_at,
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'language', t.language,
                                                           'body_text', t.body_text, 'param_count', t.param_count) order by t.name, t.language)
                         from app.message_templates t
                        where t.connection_id = v_conv.connection_id and t.store_id = p_store_id and t.usable), '[]'::jsonb)));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_templates', v_state, v_code);
end;
$$;

create function api.send_template(p_store_id uuid, p_conversation_id uuid, p_template_id uuid, p_params jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_hash text;
  v_result jsonb;
  v_conv app.conversations;
  v_tpl app.message_templates;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'messages.send');
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'conversation_id', p_conversation_id,
                                                'template_id', p_template_id, 'params', p_params));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'send_template', v_hash);
  if v_result is not null then
    return v_result;
  end if;
  v_conv := app.lock_conversation(p_store_id, p_conversation_id);
  select * into v_tpl from app.message_templates
   where id = p_template_id and store_id = p_store_id and connection_id = v_conv.connection_id and usable;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if jsonb_typeof(p_params) is distinct from 'array' or jsonb_array_length(p_params) <> v_tpl.param_count
     or exists (select 1 from jsonb_array_elements(p_params) x where jsonb_typeof(x) <> 'string' or not app.template_param_ok(x #>> '{}')) then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object('params', 'invalid'), 'param_count', v_tpl.param_count));
  end if;
  v_result := app.ok(app.channel_authorize_send(p_store_id, v_uid, v_conv, app.render_template(v_tpl.body_text, p_params), null,
                                                'template', null, null, v_tpl, p_params));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'send_template', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('send_template', v_state, v_code);
end;
$$;

-- Worker (sender role): WhatsApp numbers whose templates are older than 6 hours, with the token to
-- read them; and storing what Meta returned.
create function api.channel_due_template_syncs()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  return app.ok(jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object('connection_id', c.id, 'provider', c.provider_id, 'waba_id', c.provider_meta ->> 'waba_id',
                                        'credential', (select decrypted_secret from vault.decrypted_secrets where id = c.credential_ref)))
      from (select c.* from app.connections c join app.providers p on p.id = c.provider_id
             where p.connect_method = 'whatsapp_signup' and c.state = 'connected' and c.provider_meta ? 'waba_id'
               and (c.templates_synced_at is null or c.templates_synced_at < now() - interval '6 hours')
             order by c.templates_synced_at nulls first limit 10) c), '[]'::jsonb)));
end;
$$;

create function api.channel_store_templates(p_connection_id uuid, p_templates jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_conn app.connections;
  v_count integer;
begin
  select * into v_conn from app.connections where id = p_connection_id and state = 'connected' for update;
  if not found or jsonb_typeof(p_templates) is distinct from 'array' or jsonb_array_length(p_templates) > 500 then
    return app.err('VALIDATION_FAILED', '{}');
  end if;
  -- Templates no longer at Meta are not usable any more (the upsert below restores those present).
  update app.message_templates m set usable = false, status = 'MISSING'
   where m.connection_id = v_conn.id
     and not exists (select 1 from jsonb_array_elements(p_templates) t where t ->> 'name' = m.name and t ->> 'language' = m.language);
  with incoming as (
    select t ->> 'name' as name, t ->> 'language' as language, upper(coalesce(t ->> 'category', '')) as category,
           upper(coalesce(t ->> 'status', '')) as status,
           (select c ->> 'text' from jsonb_array_elements(case when jsonb_typeof(t -> 'components') = 'array' then t -> 'components' else '[]' end) c
             where upper(c ->> 'type') = 'BODY' limit 1) as body,
           -- Only plain bodies: no header, button or media component (not supported in this version).
           not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(t -> 'components') = 'array' then t -> 'components' else '[]' end) c
                        where upper(c ->> 'type') <> 'BODY') as plain
      from jsonb_array_elements(p_templates) t
     where t ->> 'name' ~ '^[a-z0-9_]+$' and char_length(t ->> 'name') <= 512 and t ->> 'language' ~ '^[a-z]{2,3}(_[A-Z]{2})?$'
  ), upserted as (
    insert into app.message_templates (store_id, connection_id, name, language, category, status, body_text, param_count, usable, synced_at)
    select v_conn.store_id, v_conn.id, name, language, left(category, 40), left(status, 40), left(body, 1024),
           coalesce((select max(m[1]::integer) from regexp_matches(coalesce(body, ''), '\{\{([0-9]{1,2})\}\}', 'g') m), 0),
           status = 'APPROVED' and category = 'UTILITY' and plain and body is not null and char_length(body) <= 1024
             and (select count(distinct m[1]) from regexp_matches(coalesce(body, ''), '\{\{([0-9]{1,2})\}\}', 'g') m)
                 = coalesce((select max(m[1]::integer) from regexp_matches(coalesce(body, ''), '\{\{([0-9]{1,2})\}\}', 'g') m), 0),
           now()
      from incoming
    on conflict (connection_id, name, language) do update
      set category = excluded.category, status = excluded.status, body_text = excluded.body_text,
          param_count = excluded.param_count, usable = excluded.usable, synced_at = now()
    returning 1)
  select count(*) into v_count from upserted;
  update app.connections set templates_synced_at = now() where id = v_conn.id;
  return app.ok(jsonb_build_object('templates', v_count));
end;
$$;

revoke all on function app.render_template(text, jsonb), app.template_param_ok(text),
  app.channel_authorize_send(uuid, uuid, app.conversations, text, uuid, text, uuid, uuid, app.message_templates, jsonb),
  api.list_templates(uuid, uuid), api.send_template(uuid, uuid, uuid, jsonb, uuid),
  api.channel_due_template_syncs(), api.channel_store_templates(uuid, jsonb)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender,
     aisellia_channel_connector;
grant execute on function api.list_templates(uuid, uuid), api.send_template(uuid, uuid, uuid, jsonb, uuid) to authenticated;
grant execute on function api.channel_due_template_syncs(), api.channel_store_templates(uuid, jsonb) to aisellia_channel_sender;
