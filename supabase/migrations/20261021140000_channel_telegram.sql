-- Phase 9: Telegram (Bot API). Local only; nothing is connected or deployed.
--
-- Webhooks: one URL per bot, /channel-webhook/telegram/<connection id>; Telegram echoes the secret
-- token set with setWebhook in X-Telegram-Bot-Api-Secret-Token, compared in the database with that
-- connection's Vault secret (scheme telegram_token); every event is bound to that bot's account.
-- The token authenticates the sender, not the body (Telegram does not sign bodies): a changed body
-- cannot be detected; TLS protects it in transit. A leaked secret token is rotated with setWebhook.
-- Body: an Update {"update_id", "message": {"message_id", "from": {"id", "is_bot", "first_name",
-- "last_name"}, "chat": {"id", "type"}, "date" (s), "text" | "caption" | "photo" | "voice" | …}}.
-- Only private chats with people; edited messages, channel posts and group chats are ignored.
-- Message ids are unique per chat only, so the external id is "<chat id>:<message id>" (the sender
-- uses the same form for sent messages). The event id is the update_id (unique per bot: events are
-- deduplicated per account since review R1).
-- EVIDENCE: ASSUMPTION until the official Bot API page is read; sending stays blocked until then.

create function app.channel_normalize_telegram_bot(p_provider app.providers, p_conn app.connections, p_body jsonb)
returns jsonb
language sql stable
as $$
  with u as (
    select p_body -> 'message' as m
     where jsonb_typeof(p_body -> 'message') = 'object'
       and p_body #>> '{message,chat,type}' = 'private'
       and coalesce(p_body #>> '{message,from,is_bot}', 'false') <> 'true'
       and p_body #>> '{message,chat,id}' ~ '^-?[0-9]{1,20}$'
       and p_body #>> '{message,message_id}' ~ '^[0-9]{1,20}$'
  ),
  k as (
    select m, case when m ? 'photo' then 'image' when m ? 'video' or m ? 'video_note' then 'video' when m ? 'voice' then 'voice'
                   when m ? 'audio' then 'audio' when m ? 'document' then 'file' when m ? 'sticker' then 'sticker'
                   when m ? 'location' or m ? 'venue' then 'location' when m ? 'contact' then 'contact'
                   when m ? 'text' then null else 'other' end as kind
      from u
  )
  select jsonb_build_object(
    'event_id', case when p_body ->> 'update_id' ~ '^[0-9]{1,20}$' then p_body ->> 'update_id' end,
    'events', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'kind', 'message',
      'account_id', p_conn.external_account_id,
      'external_user_id', m #>> '{chat,id}',
      'external_message_id', (m #>> '{chat,id}') || ':' || (m ->> 'message_id'),
      'display_name', nullif(btrim(concat_ws(' ', m #>> '{from,first_name}', m #>> '{from,last_name}')), ''),
      'occurred_at', case when m ->> 'date' ~ '^[0-9]{9,12}$' then to_jsonb(to_timestamp((m ->> 'date')::bigint)) end,
      'text', case when jsonb_typeof(m -> 'text') = 'string' then m -> 'text'
                   when jsonb_typeof(m -> 'caption') = 'string' then m -> 'caption' end,
      -- A file id to fetch later with the bot token; the shared contact's phone is never stored.
      'attachments', case when kind is not null then jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'kind', kind,
        'ref', case kind when 'image' then m #> '{photo,-1,file_id}' when 'video' then coalesce(m #> '{video,file_id}', m #> '{video_note,file_id}')
                         when 'voice' then m #> '{voice,file_id}' when 'audio' then m #> '{audio,file_id}'
                         when 'file' then m #> '{document,file_id}' when 'sticker' then m #> '{sticker,file_id}' end,
        'mime_type', coalesce(m #> '{voice,mime_type}', m #> '{audio,mime_type}', m #> '{document,mime_type}', m #> '{video,mime_type}')))) end)))
      from k), '[]'::jsonb));
$$;

update app.providers set status = 'in_development', webhook_scheme = 'telegram_token', payload_format = 'telegram_bot',
                         adapter_version = 'telegram-1', updated_at = now()
 where id = 'telegram';

insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('telegram', 'inbound_text', 'true', 'assumption', 'https://core.telegram.org/bots/api#message', null),
  ('telegram', 'outbound_text', 'true', 'assumption', 'https://core.telegram.org/bots/api#sendmessage', null),
  -- No customer-service window: a bot can answer anyone who started it (JSON null = no window).
  ('telegram', 'reply_window_hours', 'null', 'assumption', 'https://core.telegram.org/bots/api#sendmessage', null),
  ('telegram', 'max_text_length', '4096', 'assumption', 'https://core.telegram.org/bots/api#sendmessage', null),
  ('telegram', 'echoes', 'false', 'assumption', null, null),
  ('telegram', 'delivery_receipts', 'false', 'assumption', null, null),
  ('telegram', 'read_receipts', 'false', 'assumption', null, null),
  ('telegram', 'account_rate_limit', '"about 30 messages per second per bot; 1 per second per chat"', 'assumption', 'https://core.telegram.org/bots/faq', null),
  ('telegram', 'connect_flow', '"bot_token"', 'assumption', 'https://core.telegram.org/bots/api#setwebhook', null),
  ('telegram', 'per_message_cost', '0', 'assumption', null, null),
  ('telegram', 'requires_platform_review', 'false', 'assumption', null, null),
  ('telegram', 'region_restrictions', '"availability in Iraq varies (2026 suspension reported); verify before pilot"', 'assumption', null, null)
on conflict (provider_id, capability) do update set value = excluded.value, evidence = excluded.evidence,
  source_url = excluded.source_url, checked_on = excluded.checked_on, updated_at = now();

revoke all on function app.channel_normalize_telegram_bot(app.providers, app.connections, jsonb)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender;
