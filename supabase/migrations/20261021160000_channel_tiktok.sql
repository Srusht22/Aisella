-- Phase 9: TikTok (Business Messaging). Local only; BLOCKED for real use: API access needs TikTok's
-- partner approval, and the direct-message formats could not be verified (official pages unreachable
-- from this environment, and the messaging API is not fully public).
--
-- What is implemented, and on what evidence:
--  * Webhook authenticity (scheme tiktok_sha256, ASSUMPTION from TikTok for Developers webhooks):
--    TikTok-Signature: t=<unix seconds>,s=<hex HMAC-SHA256 of "<t>.<raw body>" with the client secret>,
--    checked in the database with a 5-minute replay window (20261021100000).
--  * Envelope (ASSUMPTION, same source): {"client_key", "event", "create_time", "user_openid",
--    "content": "<JSON-encoded string>"}.
--  * Direct-message content (UNRESOLVED): read here as {"conversation_id", "message_id", "text",
--    "create_time"} with the sender in user_openid and the business account in client_key's mapping
--    (the connection's external_account_id). This single function is the only place to correct once
--    the official format is read.
-- The capabilities are recorded as UNRESOLVED, which counts as absent: TikTok can neither be offered
-- nor send (the adapter additionally refuses until an operator configures the send endpoint).

create function app.channel_normalize_tiktok_bm(p_provider app.providers, p_conn app.connections, p_body jsonb)
returns jsonb
language plpgsql stable
as $$
declare
  v_content jsonb;
begin
  if jsonb_typeof(p_body) <> 'object' or p_body ->> 'event' is distinct from 'direct_message.receive'
     or coalesce(p_body ->> 'user_openid', '') = '' or jsonb_typeof(p_body -> 'content') <> 'string' then
    return jsonb_build_object('events', '[]'::jsonb);
  end if;
  begin
    v_content := (p_body ->> 'content')::jsonb;
  exception when others then
    return jsonb_build_object('events', '[]'::jsonb);
  end;
  if jsonb_typeof(v_content) <> 'object' or coalesce(v_content ->> 'message_id', '') = '' then
    return jsonb_build_object('events', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'event_id', 'dm:' || (v_content ->> 'message_id'),
    'events', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'kind', 'message',
      -- The business account the client key maps to: resolved through the connection whose
      -- external_account_id equals client_key (one TikTok app per business account, ASSUMPTION).
      'account_id', p_body ->> 'client_key',
      'external_user_id', p_body ->> 'user_openid',
      'external_message_id', v_content ->> 'message_id',
      'occurred_at', case when coalesce(v_content ->> 'create_time', p_body ->> 'create_time') ~ '^[0-9]{9,12}$'
                          then to_jsonb(to_timestamp(coalesce(v_content ->> 'create_time', p_body ->> 'create_time')::bigint)) end,
      'text', case when jsonb_typeof(v_content -> 'text') = 'string' then v_content -> 'text' end))));
end;
$$;

update app.providers set status = 'in_development', webhook_scheme = 'tiktok_sha256', payload_format = 'tiktok_bm',
                         adapter_version = 'tiktok-0-unresolved', updated_at = now()
 where id = 'tiktok';

insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('tiktok', 'inbound_text', 'true', 'unresolved', null, null),
  ('tiktok', 'outbound_text', 'true', 'unresolved', null, null),
  ('tiktok', 'reply_window_hours', '48', 'unresolved', null, null),
  ('tiktok', 'connect_flow', '"oauth_tiktok_business"', 'unresolved', null, null),
  ('tiktok', 'requires_platform_review', 'true', 'assumption', null, null)
on conflict (provider_id, capability) do update set value = excluded.value, evidence = excluded.evidence,
  source_url = excluded.source_url, checked_on = excluded.checked_on, updated_at = now();

revoke all on function app.channel_normalize_tiktok_bm(app.providers, app.connections, jsonb)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender;
