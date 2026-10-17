# E. Privacy and security

## 1. What the model provider receives

**Sent, per run:**
- the store context described in [C](c-business-data-retrieval.md);
- up to 20 recent messages of one conversation.

**Customer phone numbers and e-mail addresses are replaced by tokens in the database** (`app.pii_minimise`). It recognises Iraqi formats: 07…, +964…, 00964…, spaces, dashes, Eastern Arabic and Persian digits. The provider never receives them. The token map lives on the run row only while it runs, and is erased when the run finishes.

**Sent because they are needed for extraction:** customer names and free-text addresses that appear in the messages.

**Never sent:**
- other customers' or stores' data;
- order history;
- internal notes;
- the seller's account data;
- the store's contact phone;
- secrets.

**Provider retention and processing terms have not been verified here.** Before real customer messages are processed, the owner must review Anthropic's commercial data terms and decide on zero data retention and inference geography (Phase 3 AD-08). This document makes no claim about what the provider retains.

## 2. Secrets

| Secret | Where it lives | Never |
|---|---|---|
| `ANTHROPIC_API_KEY` | Edge Function secrets | In the app, the repository, logs or responses. Provider errors are mapped to codes without their messages (tested). |
| Worker role password (inside `AISELLIA_AI_WORKER_DB_URL`) | Edge Function secrets; set by an operator with `alter role` | Migrations (the role is created without a password), the repository. Tests set a random one for the run and remove it. |
| JWT signing secret | Not used by Phase 8 | — |
| Service-role key | Not used by Phase 8 | — |

The Flutter app calls `functions/v1/ai-assist` with the user's session and holds no provider credential. The pre-commit secret scan of every milestone found none.

## 3. Access control

**Seller functions** require an end user. The store is derived from membership: another store's ids return `NOT_FOUND`.
- Tested: pgTAP 14 (6 functions × 2 ways), pgTAP 15 (9 AI functions), Flutter backend test, Deno end-to-end test.
- The owner only can switch the AI, delete a conversation, and anonymise a customer.

**Worker role `aisellia_ai_worker`:**
- LOGIN, NOINHERIT, no attributes, member of no role, connection limit 20, statement timeout 15 s;
- `USAGE` on `api` only, `EXECUTE` on exactly 4 functions, no table reachable;
- no API role can switch to it. Guard test 01 enforces each of these.

**Tables:** all new tables have RLS enabled with no policies and no grants; definer functions only.

**Audit:** policy changes, the AI switch, conversation status changes, deletion, and AI draft creation and updates (`actor: ai`, run id), with phones masked (Phase 7 hardening).

## 4. Prompt injection

Defences, none of which relies on the prompt alone:
1. **The model has no tools and no write access.** Its output is data validated by the database.
2. **Customer text is delimited** (`<conversation>`), and `<` / `>` are neutralised, so it cannot close the block or open a new one (Deno contract test).
3. **References are limited to the run's own ids.** Another store's id renders nothing and is dropped from drafts (pgTAP 15, end-to-end).
4. **Prices, fees, stock and policies are rendered by the server.** The reply guard removes literal money, discounts, promises and "confirmed / sent" claims.
5. **Manipulation detection.** `app.looks_like_manipulation` checks new customer text in English, Sorani and Arabic and escalates even when the model was fooled (pgTAP 15: a model that "plays along" still produces only a holding reply, no draft and "Needs you").
6. **Approval is impossible from the AI path** ([D §5](d-order-draft-integration.md#5-the-approval-gate-non-negotiable)).

Prompt injection cannot be eliminated. These tests show that permissions, prices and approval stay enforced when the model is manipulated.

## 5. Retention and deletion

| Data | Rule | Mechanism |
|---|---|---|
| Message bodies and suggestion text | 12 months after the conversation's last activity | Daily job `aisellia-purge-message-bodies`; metadata kept |
| AI run outputs (`output_json`) | 90 days | Daily job `aisellia-purge-ai-run-outputs`; metrics kept |
| Phone token map | Until the run ends | Erased by complete, fail or expiry |
| A conversation, on request | Immediately | `api.delete_conversation` (owner) |
| A customer, on request | Delivered or closed orders | `api.anonymize_customer` now also clears the text of the conversations behind those orders (pgTAP 15) |
| Account deletion | With the store | The purge removes conversations, messages, runs, suggestions and policies (pgTAP 15) |

Both jobs are recorded in `app.job_runs` and reported by `internal.job_health()`.
