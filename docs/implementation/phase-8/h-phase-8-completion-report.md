# H. Phase 8 completion report

**Branch:** `S.H_Branch`.

**Status:** implemented and tested on the local Supabase stack. **Not deployed.** The real model provider was **not called**: no API key was available. **Waiting for owner approval before Phase 9.**

## 1. Features

- **Conversations** (US-020–022): paste a customer's messages with their source, or open a sandbox.
  - Messages record their origin: pasted, written and marked sent by the seller, or AI reply copied.
  - Inbox with statuses, "Needs you" reasons, filters and counts; tablet list-detail layout.
- **AI suggested reply** (US-023):
  - one structured model call per request;
  - facts rendered by the database from current records;
  - the facts used are shown to the seller;
  - the reply is in the customer's language (ckb / ar / en);
  - labelled "Suggested reply — not sent".
- **Copy and mark sent** (US-024): the copied (optionally edited) text is recorded as "copied — not confirmed as sent", then "Marked as sent by you". Nothing is ever "sent" by Aisellia.
- **Escalation** (US-025): the model's reasons are combined with database checks (manipulation in three languages, order status, repeated clarification). Escalated runs produce only a holding reply and no draft.
- **AI draft** (US-026/027):
  - created or updated from the conversation on buying intent or "Prepare draft order";
  - validated field by field; seller edits win;
  - unresolved lines with candidates;
  - one order per conversation;
  - draft or pending approval only, and approval stays the seller's.
- **AI unavailable** (US-028): a clear reason, Retry, the manual path; everything else works.
- **Settings:** store-wide AI switch (owner), per-conversation pause, written policies.
- **Accountability and limits:**
  - the AI is named in order history;
  - usage, tokens and estimated cost per run;
  - quotas;
  - retention jobs;
  - customer deletion and account purge cover conversations.

## 2. Known risks from the hardening report, and how this phase addresses them

| Risk (Phase 7 doc I §5) | Now |
|---|---|
| Production AI token issuance | Resolved: no JWT is minted. The worker uses its own Postgres login role with 4 functions; its password is an operator-set secret. |
| AI shown as "System" in history | Resolved: events and audit name "the AI assistant" |
| Refused calls count toward the rate | Unchanged for the grant path. The in-app path counts queued runs, including failed ones. |
| Notes not redacted on anonymisation | Unchanged for order notes. Conversation text behind anonymised orders is now cleared. |
| No UI for grants / customer deletion | AI settings UI added. Grants are not needed by the app path. Customer deletion is still API-only. |

## 3. Files

**Database**
- `supabase/migrations/20261018090000_conversations.sql`
- `supabase/migrations/20261018100000_ai_assist.sql`
- `supabase/tests/database/14_conversations.test.sql` (43 assertions)
- `supabase/tests/database/15_ai_assist.test.sql` (100 assertions)
- `supabase/tests/database/01_catalog_guards.test.sql`: API surface plus 7 worker-role guards (31 assertions)

**Edge Function** (`supabase/functions/ai-assist/`)
- `index.ts`, `handler.ts`, `pipeline.ts`, `provider.ts`, `anthropic_provider.ts`, `prompt.ts`, `output_schema.ts`, `worker_db.ts`, `seller_api.ts`, `config.ts`, `deno.json`, `deno.lock`
- `tests/`: contract, pipeline, handler, provider (local stub), end-to-end (local stack), fixtures, `local_stack.ts`
- `eval/`: `scenarios.json`, `run_eval.ts`

**App**
- `lib/features/inbox/`: domain, data, application, presentation (inbox, conversation, sheets, AI settings, texts)
- `lib/features/common/order_labels.dart`
- `lib/features/orders/`: domain and presentation, for AI attribution and unresolved lines
- `lib/core/backend/api.dart`: AI error codes
- `lib/app/router.dart`, `lib/app/route_guard.dart`, `lib/features/settings/store_menu_screen.dart`
- `lib/l10n/app_en.arb`, `lib/l10n/app_ckb.arb`: 156 strings

**Tests and configuration**
- `test/inbox/inbox_test.dart`, `test/backend/inbox_backend_test.dart`, `test/helpers/inbox_fakes.dart`, plus small changes to `test/helpers/test_app.dart` and `test/helpers/order_fakes.dart`
- `supabase/config.toml`: `[functions.ai-assist] verify_jwt = true`
- `.gitignore`: evaluation reports

**Documents:** `docs/implementation/phase-8/` (this set).

## 4. Migrations

| Migration | Contents |
|---|---|
| `20261018090000_conversations` | `stores.ai_enabled`; `store_policies`, `conversations`, `messages` (RLS on, no grants); 10 seller functions (list, get, create, import, record reply, update, policies, AI switch) |
| `20261018100000_ai_assist` | Role `aisellia_ai_worker` (LOGIN, no password); `ai_runs`, `reply_suggestions`, `ai_model_prices`; `order_items.candidate_variant_ids`; limits; context builder, phone tokens, output validation, fact rendering, reply guard, manipulation check, lenient draft merge; seller functions (request, copy, mark sent, dismiss, run, usage, delete); worker functions (claim, complete, fail, state); `order_json` with conversation and candidates; retention jobs (AI outputs 90 days, message bodies 12 months); account purge and `anonymize_customer` extended |

Both apply cleanly with `supabase db reset`. **Neither has been applied to any hosted project.**

## 5. Tests actually run (final regression, on a freshly reset local database)

| Suite | Command | Result |
|---|---|---|
| pgTAP, 15 suites | `bash supabase/tests/run_db_tests.sh` | **683 assertions, all pass** (01: 31, 14: 43, 15: 100, earlier suites unchanged) |
| AI-role HTTP checks (hardening) | `python3 -I supabase/tests/api/ai_role_api_test.py` | 17/17 pass |
| Deno: format, lint, type check | `deno fmt --check`, `deno lint`, `deno check` | Clean |
| Deno unit and end-to-end (scripted model, real local stack) | `deno test --allow-net=127.0.0.1 --allow-env tests/` with `AISELLIA_E2E=1` | 46 tests (end-to-end with 9 steps), all pass; worker password removed afterwards |
| Flutter format, analyze, tokens, imports, directional | Project gates | Clean |
| Flutter with the local backend | `flutter test` with `SUPABASE_TEST_*` | **300 pass** (278 before plus 22 new) |
| Flutter without a backend | `flutter test` | 275 pass, 25 backend tests skipped |
| Real-provider evaluation | `eval/run_eval.ts` | **Not run (no key)**; refuses cleanly without one |

**Bugs found and fixed during this phase:**
- regex syntax and precedence in the reply guard;
- an Arabic currency pattern that matched "الفستان" (the dress);
- timestamp ties in run ordering;
- double-encoded jsonb parameters from the worker (caught by the end-to-end test);
- a cross-feature import boundary;
- test-order and eager-future issues in the new tests.

## 6. Commits

| Commit | Milestone | Remote verified |
|---|---|---|
| `2ca6860` | Conversations, policies and the AI run pipeline (database, pgTAP) | Yes (local = origin) |
| `ecea2a0` | `ai-assist` Edge Function, Anthropic provider, tests, evaluation set | Yes |
| `99db2f4` | App: inbox, conversation, suggestions, AI drafts, settings, tests | Yes |
| (this commit) | Phase 8 documents A–H | See the final report |

## 7. Not verified / limitations

1. **No real model call.** Answer quality, latency and cost per conversation are not measured, and neither is language quality in Sorani and Arabic. The evaluation is ready to run with a key.
2. **The edge-runtime container did not boot** in this sandbox: its npm downloads were blocked by the TLS-intercepting egress proxy. The same code ran under Deno 2.9.6 against the real local database.
3. **No deployment and no hosted project.** The pooler login of the worker role on hosted Supabase is untested.
4. **Provider data terms (AD-08)** and a provider spend limit are owner decisions not yet taken.
5. **Guard and manipulation detection are lexical** (see G §4).
6. **No devices:** no physical-device or screen-reader pass of the new screens; no new golden images.
7. **Sorani strings** (156 new) await native review.
8. **Customer deletion has no app UI** (API only); order notes are not redacted on anonymisation.
9. **No live channel.** Everything is paste-in. Phase 9 owns channels, webhooks and sending.

## 8. Recommended next steps before Phase 9

1. Provide an Anthropic key for a non-production project, then run `eval/run_eval.ts` and review the report. Tune prompt `p8.1`, the guard and effort on the results.
2. Collect the consented M0 conversation set (Sorani first) and extend the evaluation set to measure the Phase 1 §14.3 gates.
3. Owner decisions:
   - AD-08 (data retention and geography);
   - AD-07 (model and effort, daily caps);
   - provider spend limit.
4. Deploy to a staging project: migrations, worker password, function secrets; verify the pooler login and function boot; repeat the end-to-end test there.
5. Native review of the Sorani and Arabic texts.
6. Device pass (TalkBack/VoiceOver, 200% text) on the inbox and conversation screens.
