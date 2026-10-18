# MC-2: local multi-channel foundation (implementation report)

**Authorized by the owner** on 2026-10-18, under the [N MC-2](../../architecture/phase-9/n-milestones-public-launch.md#mc-2-local-only-foundation-and-restricted-database-roles) acceptance criteria. **Status: implemented and tested locally; awaiting owner review. MC-3 is not authorized.**

**Boundaries kept:**
- Local development and automated tests only.
- No real provider adapter, account, webhook, deployment, message or provider charge.
- No secret in source code.
- AI replies are not enabled for any live conversation.
- No first provider was selected.
- The MC-1 provider decision is still open. MC-2 is provider-neutral, so it does not depend on it.

| Commit | Contents |
|---|---|
| `601114a` | Migration `20261020090000_channel_foundation.sql`; pgTAP suite 01 extended; new suite 18 |
| `6021791` | `supabase/functions/_channels/`: adapter interface, ingest handler, send pipeline, DB clients, stub provider, conformance kit, tests |
| `dc166c8` | This report and status updates |
| (review) | [Security and acceptance review](mc-2-security-review.md): five defects fixed in `20261020100000_channel_review_fixes.sql`, suite 19 |

## 1. What was built

**Database** (`20261020090000_channel_foundation.sql`):
- **Registry:**
  - `app.providers`, with status `planned` / `in_development` / `pilot` / `available` / `suspended`;
  - `app.provider_capabilities`, where every value carries an evidence label (`verified`, `assumption` or `unresolved`), and a `verified` row must have a source URL and check date;
  - `app.provider_capability()` returns nothing for a missing or UNRESOLVED capability.
- **The six target platforms are seeded as `planned` with no capabilities.** They can neither ingest nor send.
- **New tables** (RLS on, no grants, composite store keys): `connections`, `contacts`, `message_attachments`, `send_requests`, `delivery_events`, `webhook_events`.
  - A provider account can be held by **one store at a time**: a partial unique index on the provider and account id.
  - Credentials are only a Vault reference.
- **Existing tables extended:**
  - `conversations`: `connection_id`, `contact_id`, source `live`. A check stops an imported or sandbox conversation from having a connection.
  - `messages`: origins `channel_in` / `seller_sent` / `seller_external`, `delivery_state`, `external_message_id` (unique per connection).
  - **A trigger makes an authorized message's text immutable.** Only purging it to null is allowed.
  - `stores.ai_live_enabled`: default `false`, with no API to change it.
- **Roles:**

  | Login role (no password) | Can execute |
  |---|---|
  | `aisellia_channel_ingest` | `api.channel_ingest` |
  | `aisellia_channel_sender` | `api.channel_claim_send`, `api.channel_complete_send`, `api.channel_fail_send`, `api.channel_send_state` |

  Neither can read a table. No AI role can execute any of them.
- **Seller API** (signed-in user only):
  - `api.send_message`;
  - `api.cancel_send`;
  - `api.resolve_unknown_send`: "mark sent", or "send again" as a **new** authorization;
  - `api.list_connections`: never returns credentials or account ids.
- **Processing:** `internal.channel_process_batch`, run by pg_cron every 10 s:
  - the store is resolved from the verified account id, and the URL hint can only narrow it;
  - claiming is fair, at most N events per account per cycle;
  - duplicates are dropped at two levels, by event id and by provider message id;
  - stale events (more than 7 days) are ignored;
  - failures back off and are marked failed after 8 attempts;
  - echoes are matched by provider id, or by recipient plus the exact text's hash while a send is in flight;
  - delivery states only move forward.
- **Other jobs and changes:**
  - `internal.channel_replay`, for operators;
  - `internal.channel_expire_send_claims`: a claim that expires mid-send becomes `unknown`, never retried;
  - `internal.purge_webhook_payloads`: 14 days, and added to `job_health`;
  - `api.request_ai_assist` now refuses live conversations unless the store has opted in;
  - `api.delete_conversation` and the account purge cover the new tables, Vault secrets included.

**Deno** (`supabase/functions/_channels/`). This is a shared module; its underscore prefix means it is not deployed as a function.

| File | Contents |
|---|---|
| `adapter.ts` | `ProviderAdapter`, `NormalizedEvent` and `SendResult`. Results are `sent`, `retriable`, `permanent` or `unknown`. |
| `ingest.ts` | Reads the raw bytes once; rejects non-POST (405), non-JSON (415) and bodies over 256 KB (413); verifies before parsing (401 on failure, nothing stored); stores through the ingest role |
| `send.ts` | Claims a send, **re-hashes the exact text it is about to submit, and submits nothing on a mismatch**. Maps the adapter's result to the database. A lost database connection is resolved by reading the state back, never by resending. |
| `db.ts` | Clients for the two roles, with one short-lived connection per call |
| `stub_provider.ts` | **Fixture only.** HMAC-signed webhooks and a JSON send endpoint; refuses any non-loopback URL. |
| `conformance.ts` | The shared kit every adapter must pass (§2) |

## 2. Acceptance criteria (N MC-2)

| # | Criterion | Evidence |
|---|---|---|
| 1 | Guard tests: no attributes, no tables, exact function lists; no AI role can execute a send function | Suite 01, 11 new assertions, including a check that neither AI role can approve, advance, send, resend or confirm |
| 1 | Cross-store isolation and forged routing | Suite 18: one account per store; a hint for another store is ignored and lands nowhere; the store comes from the account; seller B gets `NOT_FOUND` from every channel function on A's data |
| 1 | Two-level deduplication | Suite 18: duplicate event id; same message in another event; replay creates nothing. Deno end-to-end: a redelivered webhook stores one message. |
| 1 | Backoff, failed state, replay | Suite 18 |
| 1 | Send rules | Suite 18 covers each of these:<br>• closed window<br>• missing permission (staff)<br>• blocked contact<br>• UNRESOLVED capability<br>• suspended provider<br>• provider in development with a non-test connection<br>• text length and whitespace<br>• confirmation for an unlinked order, before approval, and after approval<br>• rate limit<br>• idempotent replay and key reuse |
| 1 | An audit row for every authorized send | Suite 18: every send request has a `message.send_authorized` row naming a person, with the hash and not the text |
| 1 | `unknown` never claimed again | Suite 18 (integrity mismatch, timeout, expired claim); Deno unit and end-to-end tests |
| 1 | The capability rule | Suite 18: UNRESOLVED is absent; the target platforms have no capabilities |
| 1 | Retention purges | Suite 18: payload purge, the 1-day minimum, deletion of a live conversation, account purge of connections, contacts and events |
| 2 | Conformance kit green against the stub | `conformance_stub_test.ts`, 8 steps:<br>• signature accept and reject<br>• tampered bytes<br>• a re-serialized escaped body fails<br>• deterministic parsing<br>• inbound Sorani and Arabic bytes<br>• outbound bytes<br>• outcome mapping<br>• no secrets in logs |
| 2 | The stub receives **byte-identical** en / ckb / ar | Conformance kit, `send_test.ts`, and the end-to-end test through PostgREST, the sender role and the stub server. The texts include a zero-width non-joiner, Arabic-Indic digits, diacritics, trailing spaces and a newline. |
| 2 | Timeout → `unknown` | `send_test.ts`, end-to-end |
| 2 | No secrets in logs | The conformance kit, `send_test.ts` and the end-to-end test check the app secret, the Vault credential, the role passwords and the message text |
| 3 | Existing suites green | See §3 |
| 4 | No production change; nothing deployed | No hosted project touched. `config.toml` is unchanged; `_channels` is not a function. |

**Also tested:**
- AI suggestions are refused on live conversations (`live_not_enabled`), and no store has live AI on.
- The AI worker cannot send, claim or approve.
- The PostgREST AI role cannot send.
- The ingest role cannot claim.
- The sender cannot read tables or authorize.
- The authorized text cannot be changed afterwards.
- Order confirmations are created only by the seller's send, never by approval.

## 3. Test results (fresh local database, 2026-10-18)

| Suite | Result |
|---|---|
| pgTAP, 18 suites | **912 assertions, all pass** (808 before; suite 01 +11, new suite 18 has 93) |
| AI-role HTTP checks | 17 / 17 |
| Deno `ai-assist`: fmt, lint, type check, tests including end-to-end | Clean; **56 pass** |
| Deno `_channels`: fmt, lint, type check, tests including end-to-end | Clean; **14 pass** (8 conformance steps, 6 end-to-end steps) |
| Flutter: format, analyze, tokens, imports, directional | Clean |
| Flutter tests with the local backend | **300 / 300 pass**; no app change was needed (parsers fall back safely) |
| Role passwords after the tests | All four `aisellia_*` login roles have no password again (checked) |

**Failures found while building, all fixed before commit:**
- an invalid pg_cron schedule (`1 minute` changed to `* * * * *`);
- an untrimmed customer label that would have violated the label check;
- several test-file mistakes (role context, missing fixture, a status changed by an earlier replay).

**No product test failed.**

## 4. Limitations and remaining risks

1. **No real provider exists.** Adapters, OAuth or connect flows, provider-specific signatures, token refresh, and data-deletion callbacks are MC-3. They depend on the owner's channel decision, after the seller interviews.
2. ~~No server-generated order-confirmation template yet.~~ **Fixed in the [security review](mc-2-security-review.md) (R3):** a confirmation must be the server-rendered text of the approved order.
3. **Contact anonymisation by channel id** is not yet in `anonymize_customer`. It matches by phone, and channel contacts often have none. Deleting a live conversation now also erases its contact, its delivery events and the related webhook payloads ([review](mc-2-security-review.md) R4, O2).
4. ~~Manual paths on live conversations are not blocked.~~ **Fixed in the [security review](mc-2-security-review.md) (R2):** live and pasted conversations can no longer mix message origins.
5. **pg_cron jobs** (processor every 10 s, claim expiry every minute) also run in the local stack, where they do nothing without events. On a hosted project they will run once deployed, which is not authorized.
6. **The capability registry is empty for real providers by design.** Filling it requires the direct verification of official sources (N MC-0 criterion 3).

**Phase 8.5 risks, unchanged and still open:**
- The real-model evaluation has not run, so model quality is unvalidated.
- Native Sorani and Arabic review has not been done.
- No consented conversations have been collected.
- **Non-numeric fabricated promises are not solved.**

MC-2 does not enable AI on any live conversation.
