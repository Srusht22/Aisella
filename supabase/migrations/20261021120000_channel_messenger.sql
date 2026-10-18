-- Phase 9: Facebook Messenger (Page messaging). Local only; nothing is connected or deployed.
-- Same Messenger Platform webhook as Instagram with "object": "page" and the Page id as the account;
-- delivery receipts list the delivered mids; read receipts carry only a watermark (ignored here: a
-- read cannot be tied to one message). Signature: X-Hub-Signature-256 with the Meta app secret.
-- EVIDENCE: as for Instagram, ASSUMPTION until the official pages are read; sending stays blocked.

create function app.channel_normalize_meta_messenger(p_provider app.providers, p_conn app.connections, p_body jsonb)
returns jsonb language sql stable
as $$ select app.channel_normalize_meta(p_provider, p_body, 'page') $$;

update app.providers set status = 'in_development', webhook_scheme = 'meta_sha256', payload_format = 'meta_messenger',
                         adapter_version = 'messenger-1', updated_at = now()
 where id = 'messenger';

insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('messenger', 'inbound_text', 'true', 'assumption', 'https://developers.facebook.com/docs/messenger-platform/webhooks', null),
  ('messenger', 'outbound_text', 'true', 'assumption', 'https://developers.facebook.com/docs/messenger-platform/reference/send-api', null),
  ('messenger', 'reply_window_hours', '24', 'assumption', 'https://developers.facebook.com/docs/messenger-platform/policy/policy-overview', null),
  ('messenger', 'max_text_length', '2000', 'assumption', 'https://developers.facebook.com/docs/messenger-platform/reference/send-api', null),
  ('messenger', 'echoes', 'true', 'assumption', 'https://developers.facebook.com/docs/messenger-platform/reference/webhook-events/message-echoes', null),
  ('messenger', 'delivery_receipts', 'true', 'assumption', 'https://developers.facebook.com/docs/messenger-platform/reference/webhook-events/message-deliveries', null),
  ('messenger', 'read_receipts', 'false', 'assumption', 'https://developers.facebook.com/docs/messenger-platform/reference/webhook-events/message-reads', null),
  ('messenger', 'outside_window', '"human_agent_tag_deferred_to_9b"', 'assumption', null, null),
  ('messenger', 'connect_flow', '"oauth_facebook_login"', 'assumption', null, null),
  ('messenger', 'requires_platform_review', 'true', 'assumption', 'https://developers.facebook.com/docs/app-review', null)
on conflict (provider_id, capability) do update set value = excluded.value, evidence = excluded.evidence,
  source_url = excluded.source_url, checked_on = excluded.checked_on, updated_at = now();

revoke all on function app.channel_normalize_meta_messenger(app.providers, app.connections, jsonb)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender;
