# A. Current architecture and what live channels need

## 1. What exists (Phases 5–8.5)

| Area | Today | Relevant to Phase 9 |
|---|---|---|
| Backend | Supabase (Postgres 15+, PostgREST, Auth, Storage, Edge Functions on Deno), region proposal Frankfurt (AD-02) | Webhooks and senders are Edge Functions; state and rules stay in Postgres |
| Write path | **Functions only** (ADR-002): every mutation is an `api.*` security-definer function with permission checks, idempotency keys (ADR-005) and audit. RLS is SELECT-only; the app has no table writes. | New channel operations follow the same pattern |
| Tenancy | Every row carries `store_id`; composite foreign keys `(store_id, id)`; membership-derived authorization; pgTAP isolation suites 02, 07, 10, 14 and 15 | A channel account must map to exactly one store |
| Conversations | `app.conversations` (`source` ∈ instagram, whatsapp, messenger, telegram, phone, other, sandbox; immutable `is_sandbox`); `app.messages` with `direction`, `origin` ∈ imported / seller_written / ai_reply_copied, `state` ∈ imported / copied / marked_sent | Must gain live origins and send states, without breaking the manual and sandbox paths |
| AI | `ai-assist` Edge Function. The seller's JWT queues a run; the worker connects as login role `aisellia_ai_worker` with 4 functions. The database renders facts, guards replies, escalates, merges drafts and enforces cost brakes. | Inbound live messages feed the same pipeline. The AI path stays unable to send. |
| Orders | AI drafts are `draft` / `pending_approval` only. Approval is seller-only, re-checks stock and is idempotent. | Order confirmations (BR-04) become sendable only after approval |
| Privacy | Phone and e-mail tokenised before the model; retention jobs (messages 12 months, AI outputs 90 days); customer anonymisation including notes (Phase 8.5) | Must extend to channel contact ids, webhook payloads and send records |
| Background work | `pg_cron` jobs with `app.job_runs` and `internal.job_health()` (ADR-008) | Queue consumers, reconciliation and token renewal reuse this |
| Secrets | Edge Function secrets (Anthropic key, worker DB URL); worker password set by an operator | Per-store provider tokens need **Supabase Vault**, which is not yet used |
| App | Flutter: inbox, conversation, suggestion card with "Copy" and "I sent this", AI settings; Sorani RTL first | The composer gains "Send", a window indicator and send states |

## 2. Gaps a live channel creates

1. **Inbound without a user session.** Webhooks arrive unauthenticated, from the platform. Today every write has a signed-in seller. A new **ingest role** with one function is needed (like `aisellia_ai_worker`), plus request authentication by signature or secret.
2. **An external identity map.** A provider account maps to a connection and a store. A customer's provider id maps to a contact. Neither exists today.
3. **Outbound sending.** No table records an authorization to send, a provider message id or a delivery state, and no code calls a provider send API.
4. **Per-store credentials.** OAuth tokens (Meta) or bot tokens (Telegram) must be stored encrypted, rotated and revoked.
5. **Volume and abuse.** Today's inbound is pasted by sellers (at most 20 messages per import). A live channel lets anyone flood a store. Rate limits and AI debounce are needed before an inbound message can trigger AI work.
6. **Platform time windows.** Meta channels allow free-form replies only within a window after the customer's last message. The app must know and show it.
7. **Asynchronous outcomes.** Sends can time out with an unknown result; deliveries and reads arrive later as events.
8. **Operational visibility.** Connection health, webhook backlog, signature failures and token expiry need monitoring.

## 3. What does not change

- The AI boundary ([ADR-007](../phase-3/architecture-decision-records/ADR-007-ai-integration-boundary.md), Phase 7 I, Phase 8):
  - no tools;
  - output validated by the database;
  - facts rendered by the server;
  - drafts only;
  - no approval.
- Manual import and the sandbox stay available and clearly labelled. Sandbox conversations can never be attached to a live connection.
- Approval, stock, pricing and order rules (Phase 7).
- Functions-only writes, SELECT-only RLS, idempotency keys, audit.
