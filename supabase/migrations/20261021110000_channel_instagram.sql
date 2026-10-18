-- Phase 9: Instagram messaging (first provider). Local only; nothing is connected or deployed.
--
-- Webhooks: Meta signs the raw body with the app secret (X-Hub-Signature-256: sha256=<hex>), verified
-- in the database (scheme meta_sha256, Vault aisellia/provider/instagram/app_secret). The body is
-- {"object": "instagram", "entry": [{"id": <IG account id>, "time": …, "messaging": [{sender, recipient,
-- timestamp (ms), message: {mid, text, attachments, is_echo, app_id, is_deleted} | read: {mid}}]}]}.
-- Meta sends no event id: the event id is the SHA-256 of the raw body; messages deduplicate by mid.
--
-- EVIDENCE: the payload and API shapes follow Meta's public Instagram Messaging reference as known on
-- 2026-10-18, but the official pages could not be read from this environment (network policy). The
-- capabilities are therefore recorded as ASSUMPTION, and because sending requires a VERIFIED
-- outbound_text capability, no message can be sent through Instagram until someone reads the official
-- pages and records them as verified (docs/implementation/phase-9).

-- Shared by Instagram and Messenger (same Messenger Platform webhook shape, different "object").
create function app.channel_normalize_meta(p_provider app.providers, p_body jsonb, p_object text)
returns jsonb
language sql stable
as $$
  with app_id as (select app.provider_secret(p_provider.id, 'app_id') as v),
  items as (
    select e, m, eo, mo
      from jsonb_array_elements(case when p_body ->> 'object' = p_object and jsonb_typeof(p_body -> 'entry') = 'array'
                                     then p_body -> 'entry' else '[]' end) with ordinality x(e, eo)
     cross join lateral jsonb_array_elements(case when jsonb_typeof(e -> 'messaging') = 'array'
                                                  then e -> 'messaging' else '[]' end) with ordinality y(m, mo)
     where jsonb_typeof(e) = 'object' and jsonb_typeof(m) = 'object' and e ->> 'id' is not null
  ),
  out as (
    -- Messages and echoes (copies of messages the business sent, from our app or the native app).
    select eo, mo, 0 as k, jsonb_strip_nulls(jsonb_build_object(
      'kind', case when m #>> '{message,is_echo}' = 'true' then 'echo' else 'message' end,
      'account_id', e ->> 'id',
      'external_user_id', case when m #>> '{message,is_echo}' = 'true' then m #>> '{recipient,id}' else m #>> '{sender,id}' end,
      'external_message_id', m #>> '{message,mid}',
      'occurred_at', case when m ->> 'timestamp' ~ '^[0-9]{10,16}$'
                          then to_jsonb(to_timestamp((m ->> 'timestamp')::numeric / 1000)) end,
      'text', case when jsonb_typeof(m #> '{message,text}') = 'string' then m #> '{message,text}' end,
      'attachments', (select jsonb_agg(jsonb_build_object('kind',
                         case a ->> 'type' when 'image' then 'image' when 'video' then 'video' when 'audio' then 'audio'
                                           when 'file' then 'file' when 'location' then 'location' when 'sticker' then 'sticker'
                                           else 'other' end))
                        from jsonb_array_elements(case when jsonb_typeof(m #> '{message,attachments}') = 'array'
                                                       then m #> '{message,attachments}' else '[]' end) a),
      -- Only an echo carrying OUR app id may resolve an unknown send by its text (review O1).
      'sent_by_app', case when m #>> '{message,is_echo}' = 'true'
                          then to_jsonb(coalesce(m #>> '{message,app_id}' = (select v from app_id), false)) end)) as item
      from items
     where jsonb_typeof(m -> 'message') = 'object' and m #>> '{message,mid}' is not null
       and coalesce(m #>> '{message,is_deleted}', 'false') <> 'true'
    union all
    -- Delivery receipts (Messenger): one item per message id.
    select eo, mo, 1, jsonb_build_object('kind', 'delivery', 'account_id', e ->> 'id', 'provider_message_id', d.mid,
                                         'provider_event_key', 'delivery:' || d.mid)
      from items cross join lateral jsonb_array_elements_text(case when jsonb_typeof(m #> '{delivery,mids}') = 'array'
                                                                    then m #> '{delivery,mids}' else '[]' end) d(mid)
    union all
    -- Read receipts that name a message (Instagram). A watermark-only read (Messenger) is ignored.
    select eo, mo, 2, jsonb_build_object('kind', 'read', 'account_id', e ->> 'id', 'provider_message_id', m #>> '{read,mid}',
                                         'provider_event_key', 'read:' || (m #>> '{read,mid}'))
      from items where m #>> '{read,mid}' is not null
  )
  select jsonb_build_object('events', coalesce(jsonb_agg(item order by eo, mo, k), '[]'::jsonb)) from out;
$$;

create function app.channel_normalize_meta_instagram(p_provider app.providers, p_conn app.connections, p_body jsonb)
returns jsonb language sql stable
as $$ select app.channel_normalize_meta(p_provider, p_body, 'instagram') $$;

update app.providers set status = 'in_development', webhook_scheme = 'meta_sha256', payload_format = 'meta_instagram',
                         adapter_version = 'instagram-1', updated_at = now()
 where id = 'instagram';

-- ASSUMPTION rows (see the header). Values as documented publicly; to be verified before staging.
insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
  ('instagram', 'inbound_text', 'true', 'assumption', 'https://developers.facebook.com/docs/instagram-platform/webhooks', null),
  ('instagram', 'outbound_text', 'true', 'assumption', 'https://developers.facebook.com/docs/instagram-platform/instagram-api-with-facebook-login/messaging-api', null),
  ('instagram', 'reply_window_hours', '24', 'assumption', 'https://developers.facebook.com/docs/instagram-platform/instagram-api-with-facebook-login/messaging-api', null),
  ('instagram', 'max_text_length', '1000', 'assumption', 'https://developers.facebook.com/docs/instagram-platform/instagram-api-with-facebook-login/messaging-api', null),
  ('instagram', 'echoes', 'true', 'assumption', 'https://developers.facebook.com/docs/instagram-platform/webhooks', null),
  ('instagram', 'read_receipts', 'true', 'assumption', 'https://developers.facebook.com/docs/instagram-platform/webhooks', null),
  ('instagram', 'delivery_receipts', 'false', 'assumption', 'https://developers.facebook.com/docs/instagram-platform/webhooks', null),
  ('instagram', 'outside_window', '"human_agent_tag_deferred_to_9b"', 'assumption', null, null),
  ('instagram', 'connect_flow', '"oauth_facebook_login"', 'assumption', null, null),
  ('instagram', 'requires_platform_review', 'true', 'assumption', 'https://developers.facebook.com/docs/app-review', null)
on conflict (provider_id, capability) do update set value = excluded.value, evidence = excluded.evidence,
  source_url = excluded.source_url, checked_on = excluded.checked_on, updated_at = now();

revoke all on function app.channel_normalize_meta(app.providers, jsonb, text),
  app.channel_normalize_meta_instagram(app.providers, app.connections, jsonb)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender;

-- The channel-send function submits a send only for a signed-in member of the send's store with
-- messages.send (called with the user's own JWT; other stores' sends are NOT_FOUND).
create function api.check_send_dispatch(p_send_request_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_store uuid;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  select store_id into v_store from app.send_requests where id = p_send_request_id;
  if v_store is null or not exists (select 1 from app.store_members where store_id = v_store and user_id = auth.uid()) then
    perform app.fail('NOT_FOUND');
  end if;
  perform app.require_permission(v_store, 'messages.send');
  return app.ok(jsonb_build_object('store_id', v_store));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('check_send_dispatch', v_state, v_code);
end;
$$;
revoke all on function api.check_send_dispatch(uuid)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender;
grant execute on function api.check_send_dispatch(uuid) to authenticated;
