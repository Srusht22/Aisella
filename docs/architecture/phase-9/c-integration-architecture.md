# C. Integration architecture

> **Generalized by [L](l-multichannel-architecture.md)** for multiple providers and a public launch.
> - The roles, flows and rules here stay valid.
> - Where they differ, L wins: the provider registry instead of the `channel` check list; provider-neutral table names (`connections`, `contacts`, `delivery_events`, `message_attachments`); per-provider webhook functions; fair queuing.

## 1. Components

```
 Customer ──► Platform (Meta / Telegram)
                 │  webhook (HTTPS, signed)
                 ▼
 ┌──────────────────────────────┐   login role aisellia_channel_ingest
 │ Edge Function channel-webhook │──────────► api.channel_ingest(...)       (1 function)
 │  verify on raw body, then     │             • dedupe event, store raw (14 days)
 │  persist and return 200       │             • nothing else
 └──────────────────────────────┘
                                  pg_cron every 5 s ─► internal.channel_process_batch()
                                     • resolve connection → store (DB lookup, never from the URL)
                                     • upsert contact, find/create live conversation
                                     • insert message (unique per connection + provider id)
                                     • open/extend the reply window
                                     • queue AI suggestion if enabled (debounced, budgeted)
 Seller app ──► api.send_message(...) (seller JWT, permission messages.send)
                 • records the authorization: who, exact text, hash, suggestion link
                 • enqueues one send job
 ┌──────────────────────────────┐   login role aisellia_channel_sender
 │ Edge Function channel-send    │──────────► api.channel_claim_send / complete / fail / state   (4 functions)
 │  calls the provider send API  │             • claim returns the exact authorized text and the token
 └──────────────────────────────┘
 ai-assist (unchanged role aisellia_ai_worker) ── writes suggestions and drafts only; cannot send
```

**Why a separate login role per function:**
- the same pattern as the Phase 8 AI worker;
- each Edge Function holds only the database credential it needs;
- **no Edge Function uses the service-role key**;
- guard test 01 is extended to pin the new roles: no attributes, no table access, an exact function list.

| Role | Can execute | Cannot |
|---|---|---|
| `aisellia_channel_ingest` | `api.channel_ingest(channel, connection_hint, external_event_id, signature_ok, payload)` | Read anything, send, touch orders or AI |
| `aisellia_channel_sender` | `api.channel_claim_send`, `api.channel_complete_send`, `api.channel_fail_send`, `api.channel_send_state` | Create sends, change text, read conversations, touch orders |
| `aisellia_ai_worker` (existing) | Its 4 AI functions | **Any send function** (pinned by test) |
| Seller (`authenticated`) | `api.send_message`, `api.retry_send`, `api.resolve_unknown_send`, `api.connect_channel_*`, `api.disconnect_channel`, list and get functions | Call worker or ingest functions |

## 2. Data model (proposed)

New tables, all with RLS enabled, SELECT policies by membership where the app reads them, and writes through functions only.

```sql
app.channel_connections (
  id uuid pk, store_id uuid not null,
  channel text check (channel in ('instagram','whatsapp','messenger','telegram')),
  external_account_id text not null,          -- IG user id / WA phone_number_id / page id / bot id
  display_name text, state text check (state in ('connecting','connected','needs_attention','disconnected')),
  token_secret_id uuid,                       -- Supabase Vault secret id; the token itself is never in a table
  webhook_secret_hash text,                   -- Telegram secret_token: only its SHA-256
  token_expires_at timestamptz, scopes text[], capabilities jsonb,
  connected_by uuid, connected_at timestamptz, last_event_at timestamptz, last_send_ok_at timestamptz,
  is_test boolean not null default false,    -- sandbox / test assets (G); cannot serve real customers
  unique (store_id, id)
);
create unique index on app.channel_connections (channel, external_account_id) where state <> 'disconnected';
  -- one provider account can belong to only ONE store at a time (tenant isolation)

app.webhook_events (
  id bigint identity pk, channel text, connection_id uuid null,
  external_event_id text not null,            -- provider id, or SHA-256 of the raw body when none exists
  received_at timestamptz, signature_ok boolean not null,
  payload jsonb,                              -- raw body; purged after 14 days (AD-06)
  status text check (status in ('received','processing','processed','ignored','failed')),
  attempts int, next_attempt_at timestamptz, last_error_code text,
  unique (channel, external_event_id)
);

app.channel_contacts (
  id uuid pk, store_id uuid, connection_id uuid,
  external_user_id text not null,             -- IG-scoped id / WA phone (wa_id) / Telegram user id
  display_name text,                          -- untrusted, length-capped, never sent to the model raw
  phone text,                                 -- WhatsApp only (wa_id): treated like a customer phone (masked in audit, tokenised for AI)
  window_expires_at timestamptz,              -- end of the provider's free reply window
  blocked boolean default false,
  unique (connection_id, external_user_id), unique (store_id, id)
);

app.conversations  + connection_id uuid null, contact_id uuid null
  -- source gains 'live:instagram' … ; check: is_sandbox ⇒ connection_id is null;
  -- connection and conversation must share store_id (composite FK)

app.messages       + external_message_id text null, delivery_state text null
  -- origin gains 'channel_in', 'seller_sent' (sent through Aisellia) and 'seller_external' (echo of a reply the seller sent in the platform's own app)
  -- state gains 'queued','sending','sent','delivered','read','failed','unknown'
  -- unique (store_id, connection_id, external_message_id) where external_message_id is not null

app.send_requests (
  id uuid pk, store_id uuid, message_id uuid unique, connection_id uuid, contact_id uuid,
  authorized_by uuid not null, authorized_at timestamptz not null,
  text_sha256 text not null,                  -- the exact text the seller authorized
  suggestion_id uuid null, ai_originated boolean not null, edited boolean not null,
  kind text check (kind in ('reply','order_confirmation')), order_id uuid null,
  state text check (state in ('queued','sending','sent','failed','unknown','cancelled')),
  attempts int, claim_expires_at timestamptz, provider_message_id text, error_code text,
  idempotency_key uuid not null, unique (store_id, idempotency_key)
);
```

**Permissions** (Phase 1 §5.2, now implemented):
- `channels.manage` is held by the owner only. It covers connect and disconnect.
- `messages.send` is held by the owner, and by staff when staff exists (P1).
- The AI actor holds neither.

## 3. Channel adapter contract (Edge Functions, TypeScript)

This refines the Phase 3 interface and keeps all provider specifics in one module per channel.

```ts
interface ChannelAdapter {
  readonly channel: "instagram" | "whatsapp" | "messenger" | "telegram";
  handshake?(req: Request): Response | null;                  // Meta GET hub.challenge
  verify(rawBody: Uint8Array, headers: Headers, conn?: ConnectionSecrets): VerifyResult;
  accountIds(payload: unknown): string[];                     // provider account ids the event is addressed to
  parse(payload: unknown): NormalizedEvent[];                 // messages, echoes, deliveries, reads, account events
  send(msg: OutboundText, token: string, opts: { timeoutMs: number }): Promise<SendResult>;
  capabilities(): { windowHours: number | null; humanAgentTagDays: number | null;
                    perRecipientMinIntervalMs: number; maxTextLength: number; echoes: boolean };
}
type SendResult =
  | { kind: "sent"; providerMessageId: string }
  | { kind: "retriable"; code: string; retryAfterMs?: number }   // 429, 5xx, before any byte was accepted
  | { kind: "permanent"; code: string }                          // window closed, blocked, invalid recipient
  | { kind: "unknown"; code: string };                           // timeout or reset after the request was sent
```

`NormalizedEvent` contains:
- `channel`, `account_id`, `external_event_id`, `external_message_id`, `external_user_id`, `timestamp`;
- `kind` ∈ message, echo, delivery, read, account;
- `text?`;
- `attachments[]`, as type and reference only, never downloaded in Phase 9;
- `reply_to?`.

The database parses the normalized JSON, never provider payloads. Normalization happens in the Edge Function, after verification and before `api.channel_ingest`; the raw payload is stored alongside for replay.

## 4. Inbound flow

1. `POST /functions/v1/channel-webhook/<channel>`. Meta uses one URL per app; Telegram uses a URL per connection, `…/telegram/<connection_id>`.
2. Verify ([D §1](d-security.md#1-webhook-verification)). On failure: 401, a counter, nothing stored except a rate-limited aggregate.
3. `api.channel_ingest` inserts into `webhook_events` with `on conflict do nothing`, then the function returns 200. Target: under 1 s, well inside Meta's response time.
4. `internal.channel_process_batch()` runs from `pg_cron` every 5 s and takes up to 100 events with `for update skip locked`:
   - **Resolve the connection by `(channel, account_id)` from the verified payload.** The URL is only a hint. The connection must be `connected`. Otherwise the event is `ignored` with a reason, which covers unknown or disconnected accounts.
   - Upsert the contact, then find or create the **live** conversation for (connection, contact). It is never a sandbox one.
   - Insert the message. The unique `(connection_id, external_message_id)` constraint is the second deduplication.
   - On an inbound message: set `window_expires_at = event time + window`, set the conversation to `needs_reply`, and bump `last_activity_at`.
   - On an echo, delivery or read: update the matching `send_requests` and messages. An unmatched echo or receipt is kept for 24 h for late matching.
   - Mark the event `processed`. A failure increments attempts with exponential backoff ([E §2](e-reliability.md#2-retries-and-failure-recovery)).
5. **AI is optional and gated.** The store setting "Prepare suggestions for new messages" is **off by default**. When it is on:
   - one AI run per conversation per quiet period (debounced 20 s after the last inbound message);
   - none while a run is active;
   - every Phase 8 brake applies: per-store rate, per-store and total cost, AI switch, per-conversation pause;
   - manipulation detection on the new text.

   **The AI's output is a suggestion and possibly a draft. Never a send.**

## 5. Outbound flow (summary; full rules in [F](f-seller-sending-workflow.md))

1. The seller taps **Send** on text they can see. `api.send_message(store, conversation, text, suggestion_id?, idempotency_key)` checks:
   - permission and membership;
   - the conversation is live with a connected connection and an unblocked contact;
   - the window is still open, or an allowed tag applies;
   - the text length;
   - the per-store send rate.

   It then inserts `messages` (`seller_sent`, `queued`) and `send_requests` (who, when, SHA-256 of the text), and audits the authorization.
2. `channel-send` is invoked:
   - immediately, with the request id, from the app's call; the app cannot pass text, only the id;
   - and by `pg_cron` as a sweeper.

   It claims the request: state `sending`, a claim lease of 60 s, attempts + 1. It receives **the stored text** and the decrypted token for that connection only. It sends and reports the outcome.
3. The outcome is one of `sent` (provider id stored), `failed` (reason shown to the seller), or `unknown` (reconciled, never auto-resent; [E §4](e-reliability.md#4-unknown-outcomes-and-reconciliation)).

## 6. Connection lifecycle

| Step | Instagram (first channel) | Telegram (test harness) |
|---|---|---|
| Start | The owner taps "Connect Instagram". `api.connect_channel_start` returns an OAuth URL with `state` = signed (user, store, nonce, expiry 10 min). | The owner pastes a BotFather token into a write-only field, over TLS, sent to an Edge Function and never stored client-side |
| Callback | Edge Function `channel-oauth`: verify `state`, exchange the code for a token server-side, fetch the account id, store the token in Vault, upsert the connection. **The unique index refuses an account already connected to another store.** | Validate with `getMe`, store the token in Vault, `setWebhook` with a random per-connection `secret_token` (hash stored) |
| Verify | `connecting` → `connected` only after a webhook from the account round-trips: subscription confirmed, or a test DM from the owner's own account | Same: a message to the bot from the owner |
| Renew | Scheduled refresh before expiry; on failure → `needs_attention` | Not needed |
| Disconnect | Revoke at the provider (best effort), delete the Vault secret, state `disconnected`; conversations stay, read-only for sending | `deleteWebhook`, delete the secret |
| Deauthorize or data deletion (Meta callback) | Treated as a disconnect, plus a deletion request recorded for the owner to review | — |

## 7. Differences from Phase 3

| Phase 3 | This design | Why |
|---|---|---|
| Webhook functions write with general privileges | Dedicated login roles, one function each | The Phase 8 pattern; least privilege |
| URL path carries the `connection_id` | The URL is a hint only; the connection is resolved from the verified payload's account id | A forged or misrouted URL cannot attribute events to another store |
| AI request queued for every qualifying inbound | AI auto-suggestion **off by default**, debounced and budgeted | Cost and abuse; Phase 8.5 brakes |
| `pgmq` queue | A table-backed queue with `skip locked` and `pg_cron` | One fewer extension. pgmq stays an option if volume needs it. |
| Send function receives the text | Send function receives only an id and reads the **authorized** text | The text cannot change between authorization and sending |
