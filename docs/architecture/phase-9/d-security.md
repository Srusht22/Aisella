# D. Security design

## 1. Webhook verification

| Rule | Detail |
|---|---|
| **Verify on the raw bytes** | Read `await req.arrayBuffer()` once and compute the signature on those bytes **before** JSON parsing. Re-serialized JSON breaks signatures, because Meta escapes non-ASCII and Sorani and Arabic text is non-ASCII. |
| **Meta (Instagram, Messenger, WhatsApp)** | `X-Hub-Signature-256: sha256=<hex>`: HMAC-SHA256 of the raw body keyed with the **app secret** (an Edge Function secret, never in the database or the app). Constant-time comparison. Reject a missing or malformed header. |
| **Meta subscription handshake** | `GET` with `hub.mode=subscribe`, `hub.verify_token`, `hub.challenge`. Answer the challenge only if the verify token matches a long random secret (constant-time); otherwise 403. |
| **Telegram** | Compare `X-Telegram-Bot-Api-Secret-Token` with the connection's secret, as a constant-time comparison of SHA-256 hashes. The secret is random per connection, 64 characters from [A–Za–z0–9_-], and set by us in `setWebhook`. |
| **Body limits** | Refuse bodies over 256 KB (413) and any content type other than JSON. |
| **Replay** | Deduplication by event id ([E §1](e-reliability.md#1-deduplication)) makes replays harmless. Events with timestamps older than 7 days are stored but not processed into conversations (`ignored: stale`). |
| **Failures** | 401 with no body detail. A per-channel counter feeds an alert (more than 10 per hour). Invalid requests are not stored, apart from a minute-level aggregate. |
| **Transport** | HTTPS only (Supabase functions). Platform IP allow-listing is not relied on, because the ranges change; the signature is the control. |
| **Auth gate** | `channel-webhook` is deployed with `verify_jwt = false`, because platforms send no Supabase JWT. **It is the only function without the JWT gate**, and its only database right is `api.channel_ingest`. |

## 2. Tenant isolation

1. **One provider account, one store:**
   - a partial unique index on `(channel, external_account_id)` for non-disconnected connections;
   - connecting an account another store holds fails with `CHANNEL_ACCOUNT_IN_USE`, which reveals nothing about the other store.
2. **Store resolution only from verified data.** The processor maps the verified payload's recipient account id to a connection. The URL path or query is never trusted for attribution.
3. **Composite foreign keys** `(store_id, …)` on every new table make it impossible to link:
   - a contact, conversation, message or send of store A;
   - to a connection of store B.
4. **Sends are bound twice.** `send_requests.connection_id` must equal the conversation's connection, and the sender gets only that connection's token. pgTAP: a forged request with another store's conversation fails.
5. **Sandbox separation:**
   - `is_sandbox` conversations cannot have a `connection_id` (check constraint);
   - test connections (`is_test`) are flagged, and their orders are test orders (BR-50).
6. **Seller reads** go through membership-scoped functions. New isolation pgTAP suites mirror suites 02, 10 and 14.

## 3. Secrets and tokens

| Secret | Store | Who can read it |
|---|---|---|
| Meta app secret, webhook verify token | Edge Function secrets | `channel-webhook`, `channel-oauth` |
| Per-store OAuth or bot tokens | **Supabase Vault** (encrypted); the table holds only the secret id | `api.channel_claim_send`, a definer function, returns the decrypted token of the one connection being sent on, only to `aisellia_channel_sender`. `channel-oauth` writes it. Nobody else; not the app, not the seller API. |
| Telegram per-connection webhook secret | Only its SHA-256 in the table; the plain value is sent once to Telegram | Nobody |
| Ingest and sender role passwords | Inside their connection strings in Edge Function secrets; set by an operator | — |

**Logging:** event names, connection ids, provider message ids, status codes and counts only. Never tokens, message text or raw payloads (tested, as for `ai-assist`).

**Token handling:** tokens are kept in memory for one request and never written to logs or errors. Provider errors are mapped to codes, as `toProviderError` does for Anthropic.

## 4. Prompt injection through incoming messages

Inbound live messages are more exposed than pasted ones: anyone can write to the store, at any volume, with crafted text. Defences, none of which relies on the prompt:

1. **The AI cannot act.**
   - It has no send function, no approval and no tools.
   - Its output is validated data: suggestions and drafts only.
   - **No automatic sending exists in Phase 9.** An injected instruction can at worst produce a bad *suggestion*, which a seller must read and authorize.
2. **Untrusted fields are data:**
   - message text, display names, profile names, captions and quoted replies are delimited, with `<` and `>` neutralised (as in Phase 8);
   - display names are length-capped, and **they are not given to the model**; it sees "the customer";
   - attachments, links and stickers are passed as typed placeholders such as `[image]` and `[link]`. Nothing is fetched or OCR'd in Phase 9.
3. **Manipulation detection** (`app.looks_like_manipulation`, en / ckb / ar) runs on every new inbound batch. A hit escalates to "Needs you" and suppresses AI drafting.
4. **Grounding and guards:** every Phase 8 / 8.5 control applies to live conversations unchanged:
   - server-rendered facts;
   - the number allow-list;
   - the reply guard;
   - single-store context.
5. **Cost-abuse protection:**
   - AI auto-suggestion is off by default;
   - when on: debounced; one run per conversation at a time; per-store rate and cost brakes; a per-contact cap of 10 AI runs per day;
   - a contact sending more than 30 messages in 10 minutes is muted for AI and flagged.
6. **Order drafts from live chats** are drafts only, owner-approved, with stock and price re-checked (Phase 7).
7. **The residual risk is non-numeric fabrication** ([Phase 8.5 H §4](../../implementation/phase-8.5/h-validation-gates-and-review.md#4-open-risk-non-numeric-fabricated-promises-not-solved)). Live sending makes it more consequential. Controls are in [F §3](f-seller-sending-workflow.md#3-reducing-rubber-stamping).

## 5. Threat table

| Threat | Control | Test |
|---|---|---|
| Forged webhook injects messages into a store | Signature or secret on the raw body; constant-time comparison; unknown account → ignored | Deno: wrong signature, re-serialized body, missing header, wrong Telegram secret |
| Webhook routed to the wrong store by URL tampering | Store resolved from the verified account id | pgTAP: event for account X with a hint of connection Y → attributed to X's store, or ignored |
| Seller connects another seller's account | OAuth proves control; unique active account | pgTAP: second store connecting the same account → `CHANNEL_ACCOUNT_IN_USE` |
| AI or injected text causes a send | No send function for AI roles; sends require a seller JWT with `messages.send` | Guard test 01: `aisellia_ai_worker` cannot execute any send function |
| Text altered after authorization | The sender reads stored text; SHA-256 recorded; the app passes only ids | pgTAP: the claim returns the authorized text; Deno: the sender has no text input |
| Duplicate send by retry | One send per `send_requests` row; idempotency key; `unknown` is never auto-resent | Deno and pgTAP ([E](e-reliability.md)) |
| Token theft from the app or logs | Tokens only in Vault, read by one definer function for one role | Guard test; log scan test |
| Flooding a store to burn AI budget | AI off by default; debounce; per-contact and per-store caps; cost brakes | pgTAP: the 11th AI run of a contact in a day is refused |
| Personal data in webhook payloads kept too long | 14-day purge; anonymisation covers contacts and payloads | pgTAP: purge job; anonymisation extended |
| Malicious attachment or link | Not downloaded or opened; placeholders only | Deno: parse yields placeholders |
