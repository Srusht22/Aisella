-- Phase 9: provider facts re-checked against official documentation (2026-10-18), recorded in
-- docs/implementation/phase-9/provider-verification.md. The official pages themselves could not be
-- opened from this environment (DNS blocked); the facts below were confirmed through search results
-- returned FROM the official domains. That is weaker than a direct read, so the evidence label stays
-- 'assumption' (sending remains blocked) and only values and source URLs are corrected or added.

-- WhatsApp: per-recipient pacing and number throughput (official error-code and throughput pages).
insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('whatsapp', 'per_recipient_min_interval_ms', '6000', 'assumption',
   'https://developers.facebook.com/documentation/business-messaging/whatsapp/throughput', null),
  ('whatsapp', 'account_rate_limit', '"80 messages per second per business number by default (error 130429 above it)"', 'assumption',
   'https://developers.facebook.com/documentation/business-messaging/whatsapp/throughput', null),
  ('whatsapp', 'max_text_length', '4096', 'assumption',
   'https://developers.facebook.com/documentation/business-messaging/whatsapp/reference/whatsapp-business-phone-number/message-api', null),
  -- Telegram: sendMessage text is 1-4096 characters after entity parsing (official Bot API page).
  ('telegram', 'max_text_length', '4096', 'assumption', 'https://core.telegram.org/bots/api#sendmessage', null),
  -- Viber: a bot can message only users subscribed to it; sender name max 28 characters.
  ('viber', 'outside_window', '"subscribed users only"', 'assumption', 'https://developers.viber.com/docs/api/rest-bot-api/', null),
  -- Messenger: text must be under 2000 characters (Send API reference).
  ('messenger', 'max_text_length', '1999', 'assumption', 'https://developers.facebook.com/docs/messenger-platform/reference/send-api/', null),
  -- Instagram over Facebook Login uses the Messenger Platform's /<PAGE_ID>/messages with the Page token.
  ('instagram', 'outbound_text', 'true', 'assumption',
   'https://developers.facebook.com/documentation/business-messaging/instagram-messaging/get-started', null),
  -- TikTok: the Business Messaging API exists (open beta, incl. METAP; reviews required). Formats of
  -- the direct-message events and of the send body were not found: still unresolved.
  ('tiktok', 'requires_platform_review', 'true', 'assumption',
   'https://business-api.tiktok.com/portal/docs/access-to-business-messaging-api/v1.3', null)
on conflict (provider_id, capability) do update set value = excluded.value, evidence = excluded.evidence,
  source_url = excluded.source_url, checked_on = excluded.checked_on, updated_at = now();
