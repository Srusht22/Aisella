# Messaging integration architecture

**Phase 3** · Status: **Proposed — pending owner approval** · Decision: [ADR-012](architecture-decision-records/ADR-012-messaging-adapter.md) · Product: Phase 1 §4.3 (Stage A without live channels; D-01, D-02)

> **No live channel is in P0.** Stage A uses clearly labelled manual import and sandbox conversations. This document defines the architecture so the first live channel (Phase 9) does not reshape the data model. Platform facts below come from official documentation located via search on 2026-10-15. They must be **re-verified in Phase 9** together with eligibility for businesses in Iraq, app review and costs.

## 1. Channel landscape (to verify in Phase 9)
| Channel | Account model | Inbound | Webhook authenticity | Reply window | Cost signals | Notable constraints |
|---|---|---|---|---|---|---|
| **Telegram Bot API** | A **bot** owned by the store. Customers must message the bot, not the seller's personal account. | Webhook (`setWebhook`) | `secret_token` echoed in the `X-Telegram-Bot-Api-Secret-Token` header (1–256 characters) | No platform window documented for replies to user-initiated chats *(verify)* | No platform fee found *(verify)* | Lowest build effort; changes customer behaviour (a new contact point) |
| **Instagram Messaging API** | Instagram professional account connected to a Meta app (Instagram Login or Facebook Login variants) | Webhooks (`messages` field) | `X-Hub-Signature-256` = HMAC-SHA256 of the **raw body** with the app secret | 24 h standard window; the `HUMAN_AGENT` tag allows human replies up to 7 days and **requires app review**; automated messages are not allowed under that tag | No per-message fee found *(verify)* | Meta app review and business verification; Graph API host and version differ by login flow |
| **Messenger Platform** | Facebook Page | Webhooks | `X-Hub-Signature-256` | 24 h plus message tags (policy) | *(verify)* | Same Meta review process |
| **WhatsApp Business Platform** | WhatsApp Business Account with a phone number; onboarding for existing WhatsApp Business app users is documented (coexistence; *verify availability*) | Webhooks | `X-Hub-Signature-256` | 24 h customer-service window, reset by each user message; templates outside it | **Per-message pricing** by category and country. Per Meta's docs, service messages are charged **from 2026-10-01**, with 1,000 free service messages per number per month. Iraq rates not retrieved. | Costs, number migration, template approval |

## 2. Channel adapter boundary
```
interface ChannelAdapter {
  verify(request) -> Verified | Rejected            // signature / secret token, raw-body based
  parse(raw) -> NormalizedEvent[]                   // inbound messages, delivery/read receipts, account events
  send(OutboundMessage, connection) -> SendResult   // provider message id | retriable error | permanent error | unknown
  getMessageStatus?(providerMessageId) -> Status    // where the provider supports lookups
  refreshCredentials?(connection) -> Connection     // token renewal where applicable
  describeCapabilities() -> {window, tags, media, receipts, rateLimits}
}
```
Adapters live in Edge Functions (TypeScript). Business logic (conversations, drafts, AI) is channel-agnostic and consumes `NormalizedEvent`.

**Normalised inbound message:** `channel`, `connection_id`, `external_event_id`, `external_message_id`, `external_user_id`, `display_name?`, `timestamp`, `text`, `attachments[]` (kept as references; not processed in P1), `reply_to_external_id?`.

## 3. Connection and authorisation
- **Meta channels:** OAuth through the Meta app. `state` is bound to (user, store, nonce) and verified on callback. Requested scopes are the minimum for messaging. Tokens go into **Supabase Vault**; the table stores only the secret's ID.
- **Telegram:** the seller pastes the bot token created with BotFather into a dedicated, write-only form. The token is stored in Vault, then `setWebhook` is called with a per-connection `secret_token` and a URL path containing the connection ID.
- Only users with `channels.manage` (the owner) can connect or disconnect. Both actions are audited.
- **Connection states:** `connecting → connected → needs_attention (auth error, webhook failures, permission revoked) → disconnected`. The UI never says "Connected" unless the state is `connected` and a verified webhook or test message has round-tripped.

## 4. Webhook ingestion (dedupe first)
1. `POST /functions/v1/channel-webhook-<channel>/<connection_id>`.
2. Verify authenticity on the **raw body**. On failure: 401, a counter increment, and no further processing.
3. `INSERT INTO webhook_events (channel, external_event_id, …) ON CONFLICT DO NOTHING`. A duplicate is acknowledged (200) and nothing more happens.
4. Acknowledge quickly (200) once persisted.
5. Enqueue the event ID on `pgmq` queue `channel_inbound`.
6. The consumer, running every few seconds via `pg_cron` + Edge:
   - normalises the event;
   - resolves the connection and store;
   - upserts the customer identity (`external_user_id` mapped to a customer, created when absent);
   - finds or creates the conversation;
   - inserts the message with U (`connection_id`, `external_message_id`), a second line of deduplication;
   - sets `processing_status = processed`.
7. If the conversation qualifies, a separate `ai_requests` queue item is created, keyed by (`conversation_id`, last `message_id`), so AI runs once per new message batch. The AI writes **only** a suggestion and a draft (internal path); the seller is notified (P1 push).

**Ordering:** messages are ordered by provider timestamp, then by received time. Late or out-of-order events insert in place; AI runs use the conversation as it stands. Receipts for unknown messages are stored and matched later.

**Why a duplicate cannot create a duplicate order:**
- unique event IDs and unique message IDs;
- one AI request per (conversation, last message);
- one open AI draft per conversation, updated rather than duplicated ([data model §6.1](backend-and-data-model.md#61-draft-creation-ai-or-manual));
- approval by the owner only.

## 5. Processing state and retries
- `webhook_events.processing_status`: `received → processing → processed | failed | ignored`.
- A visibility timeout (60 s) means failed or timed-out consumers are retried automatically with exponential backoff (attempts ≤ 8 over about 1 h). After that the event goes to `failed`, which raises an alert and shows the connection as "needs attention".
- The payload is retained for 14 days to allow replay after a fix.

## 6. Seller intervention
- P1 default: **no auto-send.** Every outbound message is a seller tap (Phase 1 D-06).
- Escalations, failed or unknown sends, and expiring reply windows are surfaced in Today ("Needs you") and in the conversation.
- **Reply-window awareness:** each adapter reports the window. The composer shows "Reply window closes in 3 h" and disables sending when the window has expired, with an explanation and any allowed alternative such as a tag (only where policy permits and app review has been completed).

## 7. Rate limits and backoff
- Each adapter declares the provider's limits.
- `channel-send` uses a per-connection token bucket, honours `429` or `retry-after`, and applies exponential backoff with jitter.
- Retries are only for errors the adapter classifies as retriable.

## 8. Outbound messages and unknown outcomes
1. The seller taps Send. `api.request_send(message_id, idempotency_key)` creates the outbound message in state `sending` and enqueues a send job keyed by `message_id`.
2. `channel-send` calls the provider with the provider's idempotency mechanism where one exists *(verify per channel)*.
   - Success: store `provider_message_id`, state `sent`.
   - Permanent error: `failed`, with a reason the seller can act on.
3. **Timeout or connection reset before a response** gives state **`unknown`**. **Do not resend automatically.** Reconcile instead:
   - (a) wait for a delivery or echo webhook carrying our message (for example a Meta message echo, or a Telegram `message_id` in later updates);
   - (b) use the adapter's status lookup if available;
   - (c) after a reconciliation window (5 min) with no evidence, show "Sending status unknown — Check" and let the seller decide: *Resend* creates a new send attempt and is explicitly user-confirmed, or *Mark as sent*.
4. **Customer confirmations** are server-generated from an approved order (BR-04). They are only sendable when the order is `approved` or later **and** the connection is `connected`.

## 9. Token renewal and disconnection
- Meta long-lived tokens are refreshed by a scheduled job before expiry *(verify the lifetimes)*. Refresh failures move the connection to `needs_attention`.
- A Telegram bot token does not expire. Revocation is detected through API errors.
- **Disconnect:** best-effort revocation at the provider, delete the Vault secret, remove the webhook (Telegram `deleteWebhook`), set the state to `disconnected`. Existing conversations remain, marked read-only for that channel.

## 10. Health and troubleshooting
`v_channel_health` per connection shows:
- last event received;
- last successful send;
- signature failures in the last 24 h;
- failed or unknown sends;
- token expiry;
- webhook backlog.

Alerts fire on no events for 24 h on an active channel (informational), signature failures above 10 per hour, a failed-queue count above 0, or token expiry under 7 days. A seller-facing troubleshooting page explains each state.

## 11. Privacy and retention
- Message content is retained as in [data model §7](backend-and-data-model.md#7-data-lifecycle-retention-and-privacy).
- Webhook payloads are kept for 14 days.
- Platform terms on storage and usage must be reviewed per channel before launch (legal question 5 there).
- Attachments are not downloaded in P1 (only references kept) unless a feature requires them.

## 12. Real channels versus sandbox and manual import
| Kind | `conversations.source` | UI label | Can send? | Creates real orders? |
|---|---|---|---|---|
| Manual import (P0) | `manual:<platform>` | "{Platform} · imported manually" | No (copy only) | Yes |
| Sandbox (P0) | `sandbox` (`is_sandbox = true`) | "Sandbox — test only" | No | Test orders only (BR-50) |
| Live channel (P1) | `live:<channel>` + `channel_connection_id` | "{Platform}" with a health indicator | Yes (seller tap) | Yes |

These are separated at the data level (immutable `source` and `is_sandbox`), so a sandbox conversation can never be attached to a live connection.

## 13. Phase 9 verification list
1. Eligibility of Iraqi businesses and verification requirements for each Meta product; app-review scopes; timelines.
2. WhatsApp per-message rates for Iraq (rate card); coexistence with the WhatsApp Business app; template needs.
3. Instagram and Messenger message tags and human-agent rules after review; echo events for reconciliation.
4. Telegram: whether pilot sellers' customers will message a shop bot.
5. Idempotency or deduplication support on each send API.
6. Token lifetimes and refresh flows.
