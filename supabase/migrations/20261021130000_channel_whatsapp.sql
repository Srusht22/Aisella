-- Phase 9: WhatsApp Business (Cloud API). Local only; nothing is connected, deployed or charged.
-- Prerequisite done first: phone-number anonymisation of channel contacts (20261021100000, review O2).
--
-- Webhooks: X-Hub-Signature-256 with the Meta app secret (scheme meta_sha256). Body:
-- {"object": "whatsapp_business_account", "entry": [{"id": <WABA id>, "changes": [{"field": "messages",
--  "value": {"metadata": {"phone_number_id", "display_phone_number"}, "contacts": [{"wa_id", "profile": {"name"}}],
--  "messages": [{"from", "id", "timestamp" (s), "type", "text": {"body"} | "image": {"id", "mime_type", "caption"} | …}],
--  "statuses": [{"id", "status": sent|delivered|read|failed, "timestamp", "recipient_id", "errors": [{"code"}]}]}}]}]}
-- The account is the business phone number id (what we send from). The customer is identified by
-- wa_id, their phone number: it is kept in E.164 form on the contact so api.anonymize_customer finds
-- it. The Cloud API sends no echoes of messages sent elsewhere (coexistence echoes are not handled).
-- EVIDENCE: ASSUMPTION until the official pages are read; sending stays blocked until then. Sending
-- outside the 24-hour customer-service window needs approved templates, which are not implemented.

create function app.channel_normalize_whatsapp_cloud(p_provider app.providers, p_conn app.connections, p_body jsonb)
returns jsonb
language sql stable
as $$
  with vals as (
    select c -> 'value' as v, eo, co
      from jsonb_array_elements(case when p_body ->> 'object' = 'whatsapp_business_account' and jsonb_typeof(p_body -> 'entry') = 'array'
                                     then p_body -> 'entry' else '[]' end) with ordinality x(e, eo)
     cross join lateral jsonb_array_elements(case when jsonb_typeof(e -> 'changes') = 'array' then e -> 'changes' else '[]' end)
                        with ordinality y(c, co)
     where c ->> 'field' = 'messages' and jsonb_typeof(c -> 'value') = 'object'
       and c #>> '{value,metadata,phone_number_id}' is not null
  ),
  msgs as (
    select v, eo, co, m, mo, m ->> 'type' as t, m -> (m ->> 'type') as part
      from vals cross join lateral jsonb_array_elements(case when jsonb_typeof(v -> 'messages') = 'array' then v -> 'messages' else '[]' end)
                                   with ordinality z(m, mo)
     where jsonb_typeof(m) = 'object' and m ->> 'id' is not null and m ->> 'from' ~ '^[0-9]{3,20}$'
       and m ->> 'type' in ('text', 'image', 'video', 'audio', 'document', 'sticker', 'location', 'contacts', 'button', 'interactive')
  ),
  out as (
    select eo, co, 0 as k, mo, jsonb_strip_nulls(jsonb_build_object(
      'kind', 'message',
      'account_id', v #>> '{metadata,phone_number_id}',
      'external_user_id', m ->> 'from',
      'phone', case when m ->> 'from' ~ '^[1-9][0-9]{7,14}$' then '+' || (m ->> 'from') end,
      'display_name', (select ct #>> '{profile,name}' from jsonb_array_elements(case when jsonb_typeof(v -> 'contacts') = 'array'
                                                                                  then v -> 'contacts' else '[]' end) ct
                        where ct ->> 'wa_id' = m ->> 'from' limit 1),
      'external_message_id', m ->> 'id',
      'occurred_at', case when m ->> 'timestamp' ~ '^[0-9]{9,12}$' then to_jsonb(to_timestamp((m ->> 'timestamp')::bigint)) end,
      'text', case t when 'text' then part -> 'body'
                     when 'button' then part -> 'text'
                     when 'interactive' then coalesce(part #> '{button_reply,title}', part #> '{list_reply,title}')
                     when 'image' then part -> 'caption' when 'video' then part -> 'caption' when 'document' then part -> 'caption' end,
      'attachments', case when t in ('image', 'video', 'audio', 'document', 'sticker', 'location', 'contacts') then jsonb_build_array(
                       jsonb_strip_nulls(jsonb_build_object(
                         'kind', case t when 'document' then 'file' when 'contacts' then 'contact'
                                        when 'audio' then case when part ->> 'voice' = 'true' then 'voice' else 'audio' end else t end,
                         -- A media id to fetch later with the connection's token; never a URL.
                         'ref', case when t in ('image', 'video', 'audio', 'document', 'sticker') then part -> 'id' end,
                         'mime_type', part -> 'mime_type'))) end)) as item
      from msgs
    union all
    select eo, co, 1, so, jsonb_strip_nulls(jsonb_build_object(
      'kind', case s ->> 'status' when 'delivered' then 'delivery' else s ->> 'status' end,
      'account_id', v #>> '{metadata,phone_number_id}',
      'provider_message_id', s ->> 'id',
      'provider_event_key', (s ->> 'status') || ':' || (s ->> 'id'),
      'provider_status', case when s ->> 'status' = 'failed' then to_jsonb(left(s #>> '{errors,0,code}', 20)) end,
      'occurred_at', case when s ->> 'timestamp' ~ '^[0-9]{9,12}$' then to_jsonb(to_timestamp((s ->> 'timestamp')::bigint)) end))
      from vals cross join lateral jsonb_array_elements(case when jsonb_typeof(v -> 'statuses') = 'array' then v -> 'statuses' else '[]' end)
                                   with ordinality z(s, so)
     where jsonb_typeof(s) = 'object' and s ->> 'id' is not null and s ->> 'status' in ('delivered', 'read', 'failed')
  )
  select jsonb_build_object('events', coalesce(jsonb_agg(item order by eo, co, k, mo), '[]'::jsonb)) from out;
$$;

update app.providers set status = 'in_development', webhook_scheme = 'meta_sha256', payload_format = 'whatsapp_cloud',
                         adapter_version = 'whatsapp-1', updated_at = now()
 where id = 'whatsapp';

insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('whatsapp', 'inbound_text', 'true', 'assumption', 'https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/components', null),
  ('whatsapp', 'inbound_media_types', '["image", "video", "audio", "document", "sticker", "location", "contacts"]', 'assumption',
   'https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/components', null),
  ('whatsapp', 'outbound_text', 'true', 'assumption', 'https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages', null),
  ('whatsapp', 'reply_window_hours', '24', 'assumption', 'https://developers.facebook.com/docs/whatsapp/pricing', null),
  ('whatsapp', 'max_text_length', '4096', 'assumption', 'https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages', null),
  ('whatsapp', 'delivery_receipts', 'true', 'assumption', 'https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/components', null),
  ('whatsapp', 'read_receipts', 'true', 'assumption', 'https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/components', null),
  ('whatsapp', 'echoes', 'false', 'assumption', null, null),
  ('whatsapp', 'outside_window', '"approved_templates_only_not_implemented"', 'assumption', 'https://developers.facebook.com/docs/whatsapp/pricing', null),
  ('whatsapp', 'per_message_cost', '"service_window_replies_free_templates_charged"', 'assumption', 'https://developers.facebook.com/docs/whatsapp/pricing', null),
  ('whatsapp', 'requires_payment_method', 'true', 'assumption', 'https://developers.facebook.com/docs/whatsapp/pricing', null),
  ('whatsapp', 'connect_flow', '"embedded_signup"', 'assumption', 'https://developers.facebook.com/docs/whatsapp/embedded-signup', null),
  ('whatsapp', 'requires_platform_review', 'true', 'assumption', 'https://developers.facebook.com/docs/app-review', null)
on conflict (provider_id, capability) do update set value = excluded.value, evidence = excluded.evidence,
  source_url = excluded.source_url, checked_on = excluded.checked_on, updated_at = now();

revoke all on function app.channel_normalize_whatsapp_cloud(app.providers, app.connections, jsonb)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender;
