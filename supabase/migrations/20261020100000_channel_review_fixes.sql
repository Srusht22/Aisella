-- Phase 9 MC-2 post-implementation security review: fixes for the confirmed defects.
-- Local only; nothing here is deployed. Regression tests: supabase/tests/database/19_channel_review.test.sql.
--   R1 webhook event ids are unique per provider ACCOUNT, not per provider: per-bot providers number
--      their updates per bot, so another seller's event with the same id was dropped as a duplicate.
--   R2 a live (provider) conversation holds only provider messages and a pasted one never holds them:
--      paste-in import, "I sent this" and copied suggestions could be mixed into a live thread and look
--      as if they went through the provider.
--   R3 an order confirmation carries only the server-rendered text of the approved order as it is now:
--      any text was accepted with kind order_confirmation.
--   R4 deleting a live conversation also erases its contact, its messages' delivery events and the
--      stored webhook payload content about that contact.
--   R5 "delivered" or "read" after a provider "failed" report sets the send back to sent.

-- ---- R1 -----------------------------------------------------------------------------------------
alter table app.webhook_events drop constraint webhook_events_provider_id_external_event_id_key;
create unique index webhook_events_event on app.webhook_events (provider_id, (coalesce(account_key, '')), external_event_id);

-- ---- R2 -----------------------------------------------------------------------------------------
create function app.messages_channel_guard()
returns trigger
language plpgsql
as $$
declare
  v_connection_id uuid;
begin
  select connection_id into v_connection_id from app.conversations where id = new.conversation_id;
  if v_connection_id is not null then
    if new.origin not in ('channel_in', 'seller_sent', 'seller_external') then
      perform app.fail('CONVERSATION_IS_LIVE');
    end if;
    if new.connection_id is distinct from v_connection_id then
      perform app.fail('CONNECTION_MISMATCH');
    end if;
  elsif new.origin in ('channel_in', 'seller_sent', 'seller_external') then
    perform app.fail('CONVERSATION_NOT_LIVE');
  end if;
  return new;
end;
$$;
create trigger messages_channel_guard
  before insert or update of conversation_id, origin, connection_id on app.messages
  for each row execute function app.messages_channel_guard();

-- ---- R3 -----------------------------------------------------------------------------------------
-- The order confirmation, rendered from the order record (same content as the Phase 7 template the
-- app copies: greeting, number, lines, delivery, discount, total, cash due, thanks). Names are wrapped
-- in direction isolates (untrusted, mixed direction); the number is isolated left-to-right.
-- The Sorani and Arabic wording needs the native review (Phase 8.5 G2) before customers see it.
create function app.order_confirmation_text(p_order app.orders, p_lang text)
returns text
language sql stable
as $$
  with t(greet, greet_named, confirmed, delivery, discount, total, cod, thanks) as (
    select * from (values
      ('en',  'Hello,', 'Hello %s,', 'your order %s is confirmed:', 'Delivery', 'Discount', 'Total',
              'Please have %s ready for the courier.', 'Thank you!'),
      ('ckb', 'سڵاو،', 'سڵاو %s،', 'داواکارییەکەت %s پشتڕاستکرایەوە:', 'گەیاندن', 'داشکاندن', 'کۆی گشتی',
              'تکایە %s ئامادە بکە بۆ گەیەنەر.', 'سوپاس!'),
      ('ar',  'مرحباً،', 'مرحباً %s،', 'تم تأكيد طلبك %s:', 'التوصيل', 'الخصم', 'المجموع',
              'يرجى تجهيز %s لمندوب التوصيل.', 'شكراً لك!')) v(lang, a, b, c, d, e, f, g, h)
     where v.lang = p_lang)
  select concat_ws(E'\n',
    case when p_order.customer_name is null then t.greet
         else format(t.greet_named, chr(8296) || p_order.customer_name || chr(8297)) end,
    format(t.confirmed, chr(8294) || '#' || p_order.number || chr(8297)),
    (select string_agg('• ' || i.quantity || ' × ' || chr(8296) || i.name_snapshot || chr(8297)
                       || case when i.variant_label_snapshot <> '' then ' · ' || chr(8296) || i.variant_label_snapshot || chr(8297) else '' end
                       || ' — ' || app.format_money(i.quantity::bigint * coalesce(i.approved_unit_price, i.quoted_unit_price, 0),
                                                    p_order.currency, p_lang),
                       E'\n' order by i.position, i.created_at, i.id)
       from app.order_items i where i.order_id = p_order.id and i.store_id = p_order.store_id),
    case when p_order.delivery_fee is not null
         then t.delivery || ': ' || app.format_money(p_order.delivery_fee::bigint, p_order.currency, p_lang) end,
    case when p_order.discount > 0
         then t.discount || ': − ' || app.format_money(p_order.discount::bigint, p_order.currency, p_lang) end,
    t.total || ': ' || app.format_money(p_order.total, p_order.currency, p_lang),
    case when p_order.payment_method = 'cod' then format(t.cod, app.format_money(p_order.cod_due, p_order.currency, p_lang)) end,
    t.thanks)
  from t;
$$;

-- R1
create or replace function api.channel_ingest(p_provider text, p_external_event_id text, p_connection_hint text,
                                   p_events jsonb, p_raw_sha256 text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_status text;
  v_id bigint;
  v_code text;
  v_detail text;
  v_state text;
begin
  select status into v_status from app.providers where id = p_provider;
  if not found or v_status = 'planned' then
    perform app.fail('UNKNOWN_PROVIDER');
  end if;
  if p_external_event_id is null or char_length(p_external_event_id) not between 1 and 200
     or p_raw_sha256 is null or p_raw_sha256 !~ '^[0-9a-f]{64}$'
     or (p_connection_hint is not null and char_length(p_connection_hint) > 100)
     or jsonb_typeof(p_events) is distinct from 'array' or jsonb_array_length(p_events) not between 1 and 100
     or octet_length(p_events::text) > 262144 then
    perform app.fail('VALIDATION_FAILED');
  end if;
  insert into app.webhook_events (provider_id, external_event_id, connection_hint, account_key, raw_sha256, payload)
  values (p_provider, p_external_event_id, p_connection_hint, left(p_events -> 0 ->> 'account_id', 200), p_raw_sha256, p_events)
  on conflict (provider_id, (coalesce(account_key, '')), external_event_id) do nothing
  returning id into v_id;
  return app.ok(jsonb_build_object('stored', v_id is not null, 'duplicate', v_id is null));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_ingest', v_state, v_code);
end;
$$;

-- R4
create or replace function api.delete_conversation(p_store_id uuid, p_conversation_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_member app.store_members;
  v_conv app.conversations;
  v_conn app.connections;
  v_contact app.contacts;
  v_ids text[];
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
  if exists (select 1 from app.send_requests where conversation_id = v_conv.id and state in ('queued', 'sending')) then
    perform app.fail('SEND_IN_PROGRESS');
  end if;
  -- A live conversation: also the delivery events of its messages, its contact (name and provider
  -- user id) and the content of the stored webhook payloads about that contact. The event rows stay,
  -- without content, as deduplication keys; the audit rows keep only ids and hashes.
  if v_conv.connection_id is not null then
    select * into v_conn from app.connections where id = v_conv.connection_id and store_id = p_store_id;
    select * into v_contact from app.contacts where id = v_conv.contact_id and store_id = p_store_id;
    select coalesce(array_agg(x), '{}') into v_ids from (
      select provider_message_id x from app.send_requests where conversation_id = v_conv.id and provider_message_id is not null
      union select external_message_id from app.messages where conversation_id = v_conv.id and external_message_id is not null) s;
    delete from app.delivery_events where connection_id = v_conn.id and provider_message_id = any (v_ids);
    update app.webhook_events w set payload = null, payload_purged_at = now()
     where w.provider_id = v_conn.provider_id and w.payload is not null and w.status in ('processed', 'ignored', 'failed')
       and (w.store_id = p_store_id or w.store_id is null)
       and exists (select 1 from jsonb_array_elements(w.payload) i
                    where i ->> 'account_id' = v_conn.external_account_id
                      and (i ->> 'external_user_id' = v_contact.external_user_id
                           or i ->> 'external_message_id' = any (v_ids) or i ->> 'provider_message_id' = any (v_ids)));
  end if;
  update app.messages set suggestion_id = null where conversation_id = v_conv.id;
  delete from app.send_requests where conversation_id = v_conv.id;
  delete from app.message_attachments a using app.messages m where m.id = a.message_id and m.conversation_id = v_conv.id;
  delete from app.messages where conversation_id = v_conv.id;
  delete from app.reply_suggestions where conversation_id = v_conv.id;
  delete from app.ai_runs where conversation_id = v_conv.id;
  delete from app.conversations where id = v_conv.id;
  delete from app.contacts where id = v_conv.contact_id and store_id = p_store_id;
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

-- R5
create or replace function app.channel_apply_delivery(p_connection_id uuid, p_provider_message_id text)
returns void
language plpgsql
as $$
declare
  v_best text;
begin
  select case when bool_or(state = 'read') then 'read' when bool_or(state = 'delivered') then 'delivered'
              when bool_or(state = 'sent') then 'sent' when bool_or(state = 'failed') then 'failed' end
    into v_best
    from app.delivery_events where connection_id = p_connection_id and provider_message_id = p_provider_message_id;
  if v_best is null then
    return;
  end if;
  if not exists (select 1 from app.send_requests where connection_id = p_connection_id
                   and provider_message_id = p_provider_message_id) then
    return;   -- unmatched for now: applied when the send completes
  end if;
  if v_best = 'failed' then
    update app.send_requests set state = 'failed', error_code = 'provider_reported_failed', updated_at = now()
     where connection_id = p_connection_id and provider_message_id = p_provider_message_id and state in ('sending', 'unknown', 'sent');
  else
    -- Delivered or read is proof it went out, also after a provider "failed" report (another device).
    update app.send_requests
       set state = 'sent', resolution = case when state = 'unknown' then 'evidence' else resolution end,
           resolved_at = case when state = 'unknown' then now() else resolved_at end,
           error_code = case when state = 'failed' then null else error_code end, updated_at = now()
     where connection_id = p_connection_id and provider_message_id = p_provider_message_id
       and (state in ('sending', 'unknown') or (state = 'failed' and error_code = 'provider_reported_failed'));
  end if;
  update app.messages m set delivery_state = v_best
    from app.send_requests s
   where s.connection_id = p_connection_id and s.provider_message_id = p_provider_message_id and m.id = s.message_id
     and (case v_best when 'read' then 4 when 'delivered' then 3 when 'sent' then 2 else 1 end)
         > (case m.delivery_state when 'read' then 4 when 'delivered' then 3 when 'sent' then 2
                                  when 'failed' then 1 else 0 end);
  update app.delivery_events set applied = true
   where connection_id = p_connection_id and provider_message_id = p_provider_message_id and not applied;
end;
$$;

-- R3 (uses app.order_confirmation_text above)
create or replace function app.channel_authorize_send(p_store_id uuid, p_uid uuid, p_conv app.conversations, p_text text,
                                           p_suggestion_id uuid, p_kind text, p_order_id uuid, p_resend_of uuid)
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
  -- Capabilities: outbound text must be VERIFIED; the window must be resolved (a number of hours,
  -- or a verified JSON null meaning "no window"). Anything missing or UNRESOLVED blocks sending.
  if app.provider_capability(v_conn.provider_id, 'outbound_text', true) is distinct from 'true'::jsonb then
    perform app.fail('CHANNEL_CAPABILITY_MISSING', '{"capability": "outbound_text"}');
  end if;
  v_window := app.provider_capability(v_conn.provider_id, 'reply_window_hours');
  if v_window is null then
    perform app.fail('CHANNEL_CAPABILITY_MISSING', '{"capability": "reply_window_hours"}');
  end if;
  if jsonb_typeof(v_window) = 'number' and (v_contact.window_expires_at is null or v_contact.window_expires_at <= now()) then
    perform app.fail('REPLY_WINDOW_CLOSED', jsonb_build_object('closed_at', v_contact.window_expires_at));
  end if;
  v_max := app.provider_capability(v_conn.provider_id, 'max_text_length');
  v_limit := case when jsonb_typeof(v_max) = 'number' then (v_max #>> '{}')::integer else app.ai_limit('channel_text_max_default') end;
  -- The text is taken exactly as the seller wrote it: never trimmed, normalised or templated.
  if p_text is null or btrim(p_text) = '' or char_length(p_text) > least(v_limit, 4000) then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object('text', 'invalid'), 'max_length', least(v_limit, 4000)));
  end if;
  if coalesce(p_kind, 'reply') not in ('reply', 'order_confirmation') then
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
                                 suggestion_id, ai_originated, edited, kind, order_id, resend_of)
  values (p_store_id, v_msg_id, p_conv.id, v_conn.id, v_contact.id, p_uid, v_hash, v_sugg.id, v_sugg.id is not null,
          v_sugg.id is not null and p_text is distinct from v_sugg.text_rendered, coalesce(p_kind, 'reply'), p_order_id, p_resend_of)
  returning * into v_req;
  update app.conversations set status = 'waiting', last_activity_at = now(), updated_at = now(), version = version + 1
   where id = p_conv.id and status <> 'needs_you';
  -- The audit names the person and the text's hash, never the text.
  perform app.audit(p_store_id, 'message.send_authorized', 'send_request', v_req.id, null,
                    jsonb_build_object('message_id', v_msg_id, 'conversation_id', p_conv.id, 'text_sha256', v_hash,
                                       'ai_originated', v_req.ai_originated, 'edited', v_req.edited, 'kind', v_req.kind,
                                       'order_id', p_order_id, 'suggestion_id', v_sugg.id, 'resend_of', p_resend_of));
  return jsonb_build_object('send_request_id', v_req.id, 'message_id', v_msg_id, 'state', v_req.state, 'text_sha256', v_hash);
end;
$$;

-- The confirmation text the seller may send for an approved order (read only; sending still needs
-- api.send_message with exactly this text).
create function api.order_confirmation_text(p_store_id uuid, p_order_id uuid, p_lang text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_order app.orders;
  v_text text;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, 'messages.send');
  if p_lang is null or p_lang not in ('en', 'ckb', 'ar') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"lang": "invalid"}}');
  end if;
  select * into v_order from app.orders where id = p_order_id and store_id = p_store_id;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_order.status not in ('approved', 'processing', 'dispatched', 'delivered') then
    perform app.fail('ORDER_NOT_APPROVED', jsonb_build_object('status', v_order.status));
  end if;
  v_text := app.order_confirmation_text(v_order, p_lang);
  return app.ok(jsonb_build_object('text', v_text, 'text_sha256', app.sha256_hex(v_text), 'lang', p_lang,
                                   'order_version', v_order.version));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('order_confirmation_text', v_state, v_code);
end;
$$;

revoke all on function app.messages_channel_guard(), app.order_confirmation_text(app.orders, text),
  api.order_confirmation_text(uuid, uuid, text)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender;
grant execute on function api.order_confirmation_text(uuid, uuid, text) to authenticated;
