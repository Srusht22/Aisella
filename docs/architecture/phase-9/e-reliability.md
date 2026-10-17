# E. Reliability: deduplication, retries, rate limits, recovery, audit

Platforms deliver webhooks **at least once, possibly out of order**, and retry for days (Meta: up to 7 days, per third-party docs, to be verified). Sends can fail or time out. Every step is therefore idempotent.

## 1. Deduplication

| Layer | Key | Effect of a duplicate |
|---|---|---|
| Webhook event | `unique (channel, external_event_id)`. The provider's event id where one exists (Telegram `update_id` + bot id); otherwise SHA-256 of the raw body (Meta payloads) | Acknowledged with 200; nothing else happens |
| Message | `unique (store_id, connection_id, external_message_id)` (Meta `mid`, WhatsApp `wamid`, Telegram chat + message id) | A second event carrying the same message, for example in a different batch, inserts nothing |
| Echo of our own send | Matched to `send_requests.provider_message_id` | Updates state; never creates an inbound message |
| AI run | One active run per conversation (existing `AI_BUSY`), plus a debounce keyed by (conversation, last inbound message) | At most one suggestion per new batch |
| Order draft | One open AI draft per conversation (Phase 8) | Updated, not duplicated |
| Send authorization | `unique (store_id, idempotency_key)` on `send_requests`; one `send_requests` row per outbound message | A double tap or client retry returns the same request |

## 2. Retries and failure recovery

**Inbound processing:**
- An event in processing that fails is retried with exponential backoff and jitter: 5 s, 30 s, 2 min, 10 min, 30 min, then hourly. That is at most 8 attempts over about 6 hours.
- Then it becomes `failed`: the alert fires and the connection shows "needs attention" with a count.
- A crash mid-batch is safe. Rows are claimed with a lease, and an expired lease returns the event to the queue.
- **Replay:** an operator-only `internal.channel_replay(event_ids)` reprocesses stored payloads (kept 14 days) after a fix. It is idempotent because of the deduplication above.

**Outbound sending:**
- Only `retriable` results are retried: 429, 5xx, and connection errors before the request was sent. The retry honours `retry-after`, at most 3 attempts within 5 minutes, then `failed: provider_unavailable`.
- `permanent` results are never retried: window closed, recipient blocked, invalid token, text too long.
- `unknown` results are reconciled (§4).

**Connection-level failures:**

| Signal | Action |
|---|---|
| Token rejected (401 or 190-type errors) | State `needs_attention`; sends paused for that connection; the owner is notified |
| No webhook events for 24 h on an active connection | Informational health warning, not an error |
| Signature failures above 10 per hour | Alert; possible secret rotation or attack |
| Webhook backlog above 500 or oldest event over 5 min | Alert; processing lag shown in health |

## 3. Rate limits

| Limit | Value (initial) | Where |
|---|---|---|
| Inbound events per connection | 600 per minute processed. The excess stays queued; nothing is dropped. | Processor batch size |
| AI runs per contact | 10 per day | `app.ai_limits` |
| Messages per contact before AI mute | 30 per 10 minutes | `app.ai_limits` |
| Seller sends per store | 60 per minute, 2,000 per day | `api.send_message` (`RATE_LIMITED`) |
| Provider pacing per recipient | WhatsApp: 1 message per 6 s to the same user; Instagram: per-thread throttling. A per-(connection, contact) token bucket enforces it. | `channel-send`, from adapter capabilities |
| Provider pacing per account | Below each provider's documented limit (Instagram Send API 300/s; WhatsApp 80/s) | Per-connection token bucket |
| Webhook request size | 256 KB | `channel-webhook` |

Limits live in `app.ai_limits`, renamed `app.limits` or a sibling table. Operators change them; sellers cannot.

## 4. Unknown outcomes and reconciliation

A timeout or reset **after** the request left gives state `unknown`. The rule from Phase 3 stands: **never resend automatically**, because a duplicate message to a customer is worse than a delay.

1. Wait up to 5 minutes for evidence:
   - an echo or `message_echoes` event carrying our text and recipient (Meta);
   - a delivery receipt referencing a provider id we can match;
   - Telegram's later updates.
2. If the provider offers a status lookup, use it once.
3. With no evidence, the message shows **"Sending status unknown"** with two choices:
   - **Check later**;
   - **Send again**, which is a new, explicitly confirmed authorization with a new `send_requests` row linked to the first.
4. `unknown` sends count toward a health metric. More than 5% in an hour raises an alert.

## 5. Ordering

- Messages are displayed by provider timestamp, then received time.
- Late events insert in place.
- The AI always runs on the conversation as it stands.
- A delivery receipt that arrives before its send's completion is stored and applied when the send completes.

## 6. Audit logging

Audit rows go to `app.audit_events`, which is append-only. Phone numbers are masked, and **no message bodies or tokens** are written.

| Action | Recorded |
|---|---|
| `channel.connect_start`, `channel.connect`, `channel.disconnect`, `channel.needs_attention`, `channel.token_refreshed` | Actor, store, channel, connection, external account id (not a token) |
| `message.send_authorized` | Actor, conversation, message id, text SHA-256, whether AI-originated, whether edited, suggestion id, kind (reply / confirmation), order id |
| `message.send_result` | Message id, state (sent / failed / unknown), provider message id, error code, attempt |
| `message.send_resolved` | Who resolved an unknown send, and how |
| `channel.webhook_rejected` | Aggregated per minute: channel, count, reason code (no payload) |
| `contact.blocked`, `contact.unblocked` | Actor, contact |
| `channel.event_replayed` | Operator, event ids |

The audit is the evidence for the rule "**no customer message was sent without a seller's authorization**". Every provider message id we produced maps to a `message.send_authorized` row with a human actor (pgTAP check).

## 7. Retention

| Data | Retention |
|---|---|
| Webhook payloads | Purged after 14 days (AD-06); the event row stays without its payload |
| Messages | 12 months after last activity (existing job) |
| Contacts | Kept while the connection exists. `anonymize_customer` is extended to contacts: by WhatsApp phone, or by contact for Instagram and Telegram, where there is no phone. A conversation-level "Delete this customer" action is added for non-phone channels. |
| Send records | Metadata kept with the message; text hash only |
