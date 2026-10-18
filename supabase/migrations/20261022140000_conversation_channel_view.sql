-- Phase 9: what the app needs to show live conversations (read-only additions to existing JSON).
--  * conversation summary: "channel" for live conversations: which connected account, its UI state,
--    whether sending is possible, and whether the customer-service window is open.
--  * message: "send" for messages sent through a channel: the send request's state, error code,
--    attempts and what the seller may do next (cancel a queued send; resolve an unknown outcome).
-- Nothing here exposes credentials, phone numbers or provider ids.

create or replace function app.message_json(m app.messages)
returns jsonb language sql stable
as $$
  select jsonb_build_object('id', m.id, 'direction', m.direction, 'origin', m.origin, 'body', m.body,
                            'state', m.state, 'edited', m.edited, 'suggestion_id', m.suggestion_id,
                            'author', case when m.origin in ('imported', 'channel_in', 'seller_external') then null
                                           else app.actor_label(m.created_by) end,
                            'delivery_state', m.delivery_state,
                            'send', (select jsonb_build_object('id', s.id, 'state', s.state, 'kind', s.kind,
                                                               'error_code', s.error_code, 'attempts', s.attempts,
                                                               'next_attempt_at', s.next_attempt_at,
                                                               'resolution', s.resolution,
                                                               'can_cancel', s.state = 'queued',
                                                               'can_resolve', s.state = 'unknown' and s.resolution is null)
                                       from app.send_requests s where s.message_id = m.id),
                            'created_at', m.created_at, 'body_purged', m.body_purged_at is not null);
$$;

create or replace function app.conversation_summary_json(c app.conversations)
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'id', c.id, 'customer_label', c.customer_label, 'source', c.source, 'is_sandbox', c.is_sandbox,
    'status', c.status, 'escalation_reasons', to_jsonb(c.escalation_reasons), 'ai_paused', c.ai_paused,
    'intent', c.intent, 'missing_fields', to_jsonb(c.missing_fields),
    'last_activity_at', c.last_activity_at, 'created_at', c.created_at, 'version', c.version,
    'last_message', (select jsonb_build_object('direction', m.direction, 'origin', m.origin,
                                               'preview', left(m.body, 120), 'created_at', m.created_at,
                                               'delivery_state', m.delivery_state)
                       from app.messages m where m.conversation_id = c.id order by m.seq desc limit 1),
    'order', (select jsonb_build_object('id', o.id, 'number', o.number, 'status', o.status, 'is_test', o.is_test)
                from app.orders o where o.id = c.order_id),
    'channel', (select jsonb_build_object(
                  'connection_id', k.id, 'provider', k.provider_id, 'provider_name', p.display_name,
                  'account_name', k.display_name, 'ui_state', app.connection_ui_state(k),
                  'can_send', app.connection_ui_state(k) = 'connected',
                  'window_hours', app.provider_capability(k.provider_id, 'reply_window_hours'),
                  'window_open', case when jsonb_typeof(app.provider_capability(k.provider_id, 'reply_window_hours')) = 'number'
                                      then coalesce(t.window_expires_at > now(), false) else true end,
                  'window_expires_at', t.window_expires_at,
                  'templates', p.connect_method = 'whatsapp_signup',
                  'contact_blocked', coalesce(t.blocked, false))
                  from app.connections k join app.providers p on p.id = k.provider_id
                  left join app.contacts t on t.id = c.contact_id
                 where k.id = c.connection_id));
$$;
