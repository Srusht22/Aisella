-- Phase 9: the background send worker. Sends the seller authorized (api.send_message) are submitted by
-- the channel-worker Edge Function, which runs short cycles with the aisellia_channel_sender role:
-- api.channel_due_sends picks what is due, fairly; each send is then claimed, re-hashed, submitted and
-- reported exactly as before (api.channel_claim_send / complete / fail). Retry limits and backoff stay
-- in api.channel_fail_send (3 attempts; 5 s, 30 s, 2 min or the provider's retry-after); an unknown
-- outcome is never selected again; expired claims become unknown (internal.channel_expire_send_claims).
--
-- Selection rules:
--   * due: queued, past its backoff, connection connected, provider not suspended;
--   * order: a send waits while an earlier send of the same conversation is still queued or sending,
--     so a customer never receives replies out of order (and at most one per conversation per cycle);
--   * per-recipient pacing: where the provider sets per_recipient_min_interval_ms (WhatsApp: 6 s), a
--     send waits until that long after the last send to the same contact;
--   * fairness: at most channel_sends_per_connection_per_cycle per connection, interleaved across
--     connections (round robin by position, oldest first).
-- Triggering: channel-send submits each send right after the seller authorizes it; the channel-worker
-- Edge Function (POST with its secret) handles everything else (retries after backoff, sends whose
-- immediate dispatch failed) and is called by an external scheduler every few seconds. pg_net is NOT
-- installed: Supabase's own setup grants its HTTP functions to the API roles and its tables to every
-- role (guard tests 01), which would give AI roles an outgoing-HTTP path.

insert into app.ai_limits (name, value) values ('channel_sends_per_connection_per_cycle', 5) on conflict (name) do nothing;

create function api.channel_due_sends(p_limit integer)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_ids jsonb;
begin
  with due as (
    select s.id, s.connection_id, s.created_at,
           row_number() over (partition by s.connection_id order by s.created_at, s.id) as rn
      from app.send_requests s
      join app.connections c on c.id = s.connection_id
      join app.providers p on p.id = c.provider_id
     where s.state = 'queued'
       and (s.next_attempt_at is null or s.next_attempt_at <= now())
       and c.state = 'connected' and p.status <> 'suspended'
       and not exists (select 1 from app.send_requests e
                        where e.conversation_id = s.conversation_id and e.id <> s.id
                          and e.state in ('queued', 'sending') and (e.created_at, e.id) < (s.created_at, s.id))
       and not exists (select 1 from app.send_requests r
                        where r.contact_id = s.contact_id and r.id <> s.id and r.attempts > 0
                          and r.updated_at > now() - make_interval(secs => coalesce(
                                (app.provider_capability(c.provider_id, 'per_recipient_min_interval_ms') #>> '{}')::numeric, 0) / 1000.0))
  )
  select coalesce(jsonb_agg(id order by rn, created_at, id), '[]'::jsonb) into v_ids
    from (select id, rn, created_at from due
           where rn <= app.ai_limit('channel_sends_per_connection_per_cycle')
           order by rn, created_at, id
           limit least(greatest(coalesce(p_limit, 50), 1), 200)) x;
  return app.ok(jsonb_build_object('ids', v_ids));
end;
$$;

revoke all on function api.channel_due_sends(integer)
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker, aisellia_channel_ingest, aisellia_channel_sender,
     aisellia_channel_connector;
grant execute on function api.channel_due_sends(integer) to aisellia_channel_sender;

