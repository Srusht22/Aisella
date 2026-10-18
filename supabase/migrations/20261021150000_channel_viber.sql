-- Phase 9: Viber (Viber Chatbot / REST Bot API). Local only; nothing is connected, deployed or charged.
--
-- Webhooks: one URL per bot, /channel-webhook/viber/<connection id>; Viber signs the raw body with
-- the bot's auth token (X-Viber-Content-Signature: hex HMAC-SHA256), verified in the database with
-- that connection's Vault credential (scheme viber_sha256); every event is bound to that bot.
-- Body: {"event": "message" | "delivered" | "seen" | "failed" | "subscribed" | "unsubscribed" |
-- "conversation_started" | "webhook", "timestamp" (ms), "message_token" (64-bit integer), "sender":
-- {"id", "name"} (message) | "user_id" (statuses), "message": {"type", "text", "media", …}, "desc"}.
-- message_token exceeds JavaScript's exact integers: it is read here, from jsonb, exactly (and the
-- sender reads it from the raw response text), so sent and delivered tokens match.
-- The send claim now also returns the connection's display name: Viber requires a sender name.
-- EVIDENCE: ASSUMPTION until the official pages are read (including Viber's chatbot fees, which
-- apply to commercial bots); sending stays blocked until then.

create function app.channel_normalize_viber_bot(p_provider app.providers, p_conn app.connections, p_body jsonb)
returns jsonb
language sql stable
as $$
  with b as (
    select p_body ->> 'event' as ev, (p_body ->> 'message_token') as tok,
           case when p_body ->> 'timestamp' ~ '^[0-9]{10,16}$' then to_jsonb(to_timestamp((p_body ->> 'timestamp')::numeric / 1000)) end as at
     where jsonb_typeof(p_body) = 'object' and p_body ->> 'message_token' ~ '^[0-9]{1,25}$'
  ),
  m as (
    select b.*, p_body -> 'message' as msg, p_body #>> '{message,type}' as t from b
     where ev = 'message' and jsonb_typeof(p_body -> 'message') = 'object' and coalesce(p_body #>> '{sender,id}', '') <> ''
  )
  select jsonb_build_object(
    'event_id', (select ev || ':' || tok || ':' || coalesce(p_body #>> '{sender,id}', p_body ->> 'user_id', '') from b),
    'events', coalesce(
      (select jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
         'kind', 'message',
         'account_id', p_conn.external_account_id,
         'external_user_id', p_body #>> '{sender,id}',
         'display_name', p_body #> '{sender,name}',
         'external_message_id', tok,
         'occurred_at', at,
         'text', case when t in ('text', 'url') and jsonb_typeof(msg -> 'text') = 'string' then msg -> 'text'
                      when t in ('picture', 'video', 'file') and jsonb_typeof(msg -> 'text') = 'string' then msg -> 'text'
                      when t = 'url' then msg -> 'media' end,
         -- Media URLs from Viber are temporary and may expire: only the kind is kept. A shared
         -- contact's phone number is never stored.
         'attachments', case when t in ('picture', 'video', 'file', 'sticker', 'location', 'contact') then jsonb_build_array(
           jsonb_build_object('kind', case t when 'picture' then 'image' else t end)) end)))
         from m),
      (select jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
         'kind', case ev when 'delivered' then 'delivery' when 'seen' then 'read' else 'failed' end,
         'account_id', p_conn.external_account_id,
         'provider_message_id', tok,
         'provider_event_key', ev || ':' || tok,
         'provider_status', case when ev = 'failed' then '"failed"'::jsonb end,
         'occurred_at', at)))
         from b where ev in ('delivered', 'seen', 'failed')),
      '[]'::jsonb));
$$;

update app.providers set status = 'in_development', webhook_scheme = 'viber_sha256', payload_format = 'viber_bot',
                         adapter_version = 'viber-1', updated_at = now()
 where id = 'viber';

insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('viber', 'inbound_text', 'true', 'assumption', 'https://developers.viber.com/docs/api/rest-bot-api/#callbacks', null),
  ('viber', 'outbound_text', 'true', 'assumption', 'https://developers.viber.com/docs/api/rest-bot-api/#send-message', null),
  -- Subscribed users can be messaged without a window (JSON null); see per_message_cost.
  ('viber', 'reply_window_hours', 'null', 'assumption', 'https://developers.viber.com/docs/api/rest-bot-api/#send-message', null),
  ('viber', 'max_text_length', '7000', 'assumption', 'https://developers.viber.com/docs/api/rest-bot-api/#send-message', null),
  ('viber', 'echoes', 'false', 'assumption', null, null),
  ('viber', 'delivery_receipts', 'true', 'assumption', 'https://developers.viber.com/docs/api/rest-bot-api/#callbacks', null),
  ('viber', 'read_receipts', 'true', 'assumption', 'https://developers.viber.com/docs/api/rest-bot-api/#callbacks', null),
  ('viber', 'per_message_cost', '"chatbot fees for commercial bots; verify the current price list"', 'assumption', null, null),
  ('viber', 'requires_payment_method', 'true', 'assumption', null, null),
  ('viber', 'connect_flow', '"bot_token"', 'assumption', 'https://developers.viber.com/docs/api/rest-bot-api/#setting-a-webhook', null),
  ('viber', 'requires_platform_review', 'true', 'assumption', null, null)
on conflict (provider_id, capability) do update set value = excluded.value, evidence = excluded.evidence,
  source_url = excluded.source_url, checked_on = excluded.checked_on, updated_at = now();

-- The claim also returns the connection's display name (Viber's required sender name).
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
    'credential', v_cred, 'attempt', v_req.attempts + 1, 'sender_name', v_conn.display_name));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('channel_claim_send', v_state, v_code);
end;
$$;

revoke all on function app.channel_normalize_viber_bot(app.providers, app.connections, jsonb)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender;
