# MC-2: post-implementation security and acceptance review

**Requested by the owner** on 2026-10-18 for commits `601114a`, `6021791` and `dc166c8`. This is a review of the code as written, not of the [MC-2 report](mc-2-local-foundation.md).

**Status:** five defects were confirmed and fixed locally. **Awaiting owner review. MC-3 is not authorized.**

**Boundaries kept:**
- Local stack and automated tests only.
- No provider implementation, account, webhook, deployment, message or charge.
- No existing safeguard was weakened. The one changed assertion in suite 18 now uses the stricter rule (see R3).

**Method:**
- I read the migration, the role grants, the shared `_channels` modules and the tests.
- I wrote regression suite 19 first and ran it against the unfixed schema. The failures below are the evidence.
- I then wrote a forward-only fix migration and re-ran every suite.

| File | Change |
|---|---|
| `supabase/migrations/20261020100000_channel_review_fixes.sql` | New migration with the fixes |
| `supabase/tests/database/19_channel_review.test.sql` | New suite, 29 assertions |
| `supabase/tests/database/01_catalog_guards.test.sql` | The exact API list now includes `api.order_confirmation_text` |
| `supabase/tests/database/18_channel_foundation.test.sql` | The approved-confirmation assertion sends the server-rendered text |

## 1. Findings

### Defects fixed

| # | Finding | Evidence before the fix (suite 19 on `dc166c8`) | Fix |
|---|---|---|---|
| R1 | **Webhook event ownership.** `webhook_events` was unique on (provider, event id). Providers that number events per bot or account would let one seller's event 1 drop another seller's event 1 as a "duplicate": silent message loss across tenants. | Tests 2 and 4 failed: store B's event was not stored and B received no message | Unique index on (provider, account key, event id). `api.channel_ingest` uses the same conflict target. A true redelivery for the same account is still a duplicate (test 3). |
| R2 | **Mixed origins.** Paste-in import, "I sent this" and copied suggestions were accepted on a live conversation. They would appear in a provider thread as if they came through the provider. Nothing stopped a provider message from landing in a pasted conversation, or a message carrying another connection's id. | Tests 5–10 failed | A `messages_channel_guard` trigger on every insert, and on updates of `conversation_id`, `origin` or `connection_id`:<br>• a live conversation holds only `channel_in`, `seller_sent` and `seller_external` messages, with the conversation's own connection;<br>• a pasted conversation holds none of those.<br>The API functions return `CONVERSATION_IS_LIVE`, `CONVERSATION_NOT_LIVE` or `CONNECTION_MISMATCH`. Pasting into pasted conversations still works (test 11). |
| R3 | **Order-confirmation gap.** `kind = order_confirmation` checked only that the order was linked and approved. **Any text was accepted**, for example "free delivery, total 1,000 IQD", and it would be recorded and audited as the order's confirmation. | The tests could not run: no server template existed (the R3 block aborted) | `app.order_confirmation_text(order, lang)` renders the confirmation from the order record: greeting, number, lines, delivery, discount, total, cash due and thanks, in en, ckb and ar. **`app.channel_authorize_send` refuses a confirmation whose text is not byte-identical to the current rendering** (`CONFIRMATION_TEXT_MISMATCH`). That includes text rendered before the order changed. New read API `api.order_confirmation_text(store, order, lang)`, which requires `messages.send` and an approved order. Tests 12–19. |
| R4 | **Deletion left personal data.** Deleting a live conversation removed messages and sends but kept:<br>• the **contact** (display name, provider user id);<br>• the **delivery events**;<br>• the **webhook payloads** that contain the customer's name and message text, for up to 14 days.<br>Channel contacts usually have no phone number, so `anonymize_customer` cannot reach them. | Tests 15–18 failed | For a live conversation, `api.delete_conversation` now also:<br>• deletes its messages' delivery events;<br>• purges the payload content of every finished webhook event for that account that names the contact or its messages;<br>• deletes the contact.<br>The event rows stay without content, as deduplication keys. Audit rows are kept: they hold only ids and hashes (tests 27–28). The other store is untouched (test 29). |
| R5 | **Delivery state after failure.** A "delivered" or "read" arriving after a provider "failed" report updated the message but left the send `failed`, so the two disagreed. | Test 13 of the reduced run failed | The send returns to `sent` and its error is cleared. This applies only when the failure came from the provider's report (`provider_reported_failed`). |

### PASS

| Area | Evidence |
|---|---|
| Restricted roles | Suite 01:<br>• the ingest and sender roles have no attributes and no table privileges;<br>• each has exactly its function list;<br>• neither AI role can execute a send, claim, approve or confirm function.<br>After the tests, all four `aisellia_*` roles have no password (checked with `pg_authid`). |
| Tenant isolation | Suite 18:<br>• the store comes from the verified account id; a URL hint for another store lands nowhere;<br>• seller B gets `NOT_FOUND` from `send_message`, `cancel_send`, `resolve_unknown_send` and `list_connections` on A's data;<br>• suite 19 test 17: B cannot read A's confirmation text. |
| Duplicate handling | Event level (now scoped per account, R1) and provider-message level (unique per connection). Replay creates nothing (suite 18). |
| Retry behaviour | Backoff, failed after 8 attempts, a 60 s lease. Replay is only of finished events that still have their payload (suite 18). |
| Send authorization | A signed-in end user with `messages.send`. The audit row names the person, with the text hash and never the text (suite 18; suite 19 test 28). |
| Immutable authorized text | The trigger refuses changes to a `seller_sent` body (only purging to null is allowed). The sender re-hashes before submitting and submits nothing on a mismatch (suite 18, `send_test.ts`). |
| Unknown outcomes | Never re-claimed: claim expiry, timeout and integrity mismatch all become `unknown`. "Send again" is a new authorization (suite 18, Deno unit and end-to-end tests). |
| Conversation creation | `api.create_conversation` refuses source `live`. The `conversations_live` constraint ties `live` to a connection. |
| AI on live conversations | Refused unless `stores.ai_live_enabled` is on. No API can change that setting. |
| Account purge | Covers connections, contacts, events, sends, attachments and Vault secrets (suite 18). |

### OPEN RISK (not fixed; outside a narrow fix, or MC-3 work)

| # | Risk | Why open |
|---|---|---|
| O1 | **Echo matching by text hash.** When a send's outcome is `unknown`, an echo with the same recipient and identical text marks it sent. If the seller typed the identical text in the native app, that echo would resolve Aisellia's send. | The result is "sent", never a false delivery, and the alternative is leaving it unknown. To revisit per provider in MC-3, where echo ids exist. |
| O2 | **`anonymize_customer` does not cover `contacts.phone`.** There is also no store-wide "erase this channel contact" action besides deleting the conversation. | No MC-2 code fills `contacts.phone` (`app.channel_contact` stores only the user id and name), so nothing is reachable today. Required before a phone-bearing provider (WhatsApp) in MC-3. |
| O3 | **Unprocessed events about a deleted contact keep their payload.** They are purged once processed (after 14 days at most). If the customer writes again, a new contact and conversation are created. | Deleting events that are not yet processed would lose new messages. Documented behaviour. |
| O4 | **Free-text replies** (`kind = reply`) can still state prices or promises. Only confirmations are templated. | Seller-authored text, attributed to the seller in the audit. Same open question as Phase 8.5 G3. |
| O5 | **The confirmation template's Sorani and Arabic wording is unreviewed.** The Arabic strings are new. In the existing copy flow (pasted conversations), the app still lets the seller edit the confirmation. A live composer must fetch `api.order_confirmation_text`; the server enforces this already. | Native review is Phase 8.5 G2. The app change belongs to MC-3. |
| O6 | **A leaked ingest credential** could insert events for any account of that provider. | Inherent. Mitigated by signature verification in the Edge Function, by store routing from the account id, and by the role's single function. Credentials are server-side only. |
| O7 | **The account key is the first item's account.** A multi-account batch (Meta-style) deduplicates by its first account. | Such providers use globally unique event ids, so no collision is expected. To confirm against official documentation in MC-3. |

**Phase 8.5 risks, unchanged and open:**
- real-model quality untested;
- no native Sorani or Arabic review;
- no consented conversations;
- **non-numeric fabricated promises not solved.**

## 2. Migration implications

- **Forward-only.** `20261020090000_channel_foundation.sql` is not edited. The new migration runs after it and has not been applied to any hosted project.
- **Schema:**
  - drops the unique constraint `webhook_events_provider_id_external_event_id_key`;
  - adds the expression index `webhook_events_event`;
  - adds the trigger `messages_channel_guard`;
  - adds `app.order_confirmation_text` and `api.order_confirmation_text`, both revoked from every role except `authenticated` on the API.
- **Functions replaced in place** (grants kept): `api.channel_ingest`, `api.delete_conversation`, `app.channel_apply_delivery`, `app.channel_authorize_send`.
- **Behaviour changes:**
  - order confirmations on live conversations now need the exact server text;
  - live conversations refuse manual message paths.
- **No backfill.** No hosted data exists. On a database with data, the trigger checks only new writes.
- **Rollback**, if ever needed:
  - drop the trigger and the two functions;
  - restore the four previous function bodies from `20261020090000`;
  - re-create the old unique constraint (possible only if no event id repeats across accounts).

## 3. Test results (fresh local database, 2026-10-18)

| Suite | Result |
|---|---|
| pgTAP, 19 suites | **941 assertions, all pass** (912 before, plus 29 in the new suite 19) |
| Suite 19 against the unfixed schema | 11 failures (R1, R2, R4, R5) and R3 not runnable. These are recorded above as the evidence. |
| AI-role HTTP checks | 17 / 17 |
| Deno `ai-assist`: fmt, lint, check, tests including end-to-end | Clean; 56 pass |
| Deno `_channels`: fmt, lint, check, tests including end-to-end | Clean; 14 pass |
| Flutter: format, analyze, tokens, imports, directional | Clean |
| Flutter tests with the local backend | 300 / 300 |
| Role passwords after the tests | None set on any `aisellia_*` role |
