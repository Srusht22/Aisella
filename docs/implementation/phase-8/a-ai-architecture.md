# A. AI architecture

## 1. Components and flow

```
Flutter app ──(seller JWT)──▶ Edge Function ai-assist (Deno)
                                │ 1. POST /rest/v1/rpc/request_ai_assist with the seller's own JWT
                                │    → database checks membership, AI switch, pause, quotas, idempotency
                                │    → a run is queued (app.ai_runs)
                                │ 2. connects as aisellia_ai_worker (own login role)
                                │    api.ai_claim_run(run) → context built by the database for that store
                                │ 3. AnthropicProvider → Claude (Messages API, structured JSON output)
                                │ 4. api.ai_complete_run(run, output, usage) → database validates and persists
                                ▼
                    reply_suggestions · conversations · orders (draft / pending_approval only)
Flutter app re-reads the conversation (api.get_conversation) and shows the result.
```

| Component | Where | Responsibility |
|---|---|---|
| Inbox, conversation and AI settings screens | `lib/features/inbox/` | Paste messages; ask for help; show suggestions, facts, escalation and the draft; copy and mark sent |
| `ai-assist` Edge Function | `supabase/functions/ai-assist/` | Forwards the seller's request, runs one model call, hands the output to the database. It holds no business rule. |
| `AiProvider` / `AnthropicProvider` | `provider.ts`, `anthropic_provider.ts` | The only provider-specific code |
| Prompt `p8.1` | `prompt.ts` | Fixed rules, the store context and the conversation as delimited data |
| Output contract | `output_schema.ts` and `app.ai_output_errors` | The same strict shape is checked in both places |
| Run pipeline | `pipeline.ts` | Claim, call the model (with one retry on invalid output), complete or fail; reconciliation |
| Database decisions | `supabase/migrations/20261018100000_ai_assist.sql` | Context, phone tokens, validation, fact rendering, reply guard, escalation, draft merge, quotas, cost |
| Conversations | `supabase/migrations/20261018090000_conversations.sql` | Conversations, messages, policies, AI switch |

**Principle: the model proposes and the database decides** (Phase 3 AI §1).
- The model has no tool that changes anything and never sees an id outside the run's context.
- Every value a customer could rely on (price, fee, stock, delivery time, policy) is inserted by `app.ai_render_fact` from current rows.

## 2. Where this differs from Phase 3

Phase 3 planned for the Edge Function to write results *with the seller's JWT* (`api.record_ai_result`). The pre-Phase 8 hardening required that the AI never act with the seller's token. Resolved in favour of the stronger boundary:
- **Writes are made by `aisellia_ai_worker`.** This login role has `EXECUTE` on exactly four functions (claim, complete, fail, state) and no table access.
  - A worker credential cannot approve, read orders, act as a seller, or reach another store's data except through runs that a seller of that store queued in the last minute.
  - Guard test 01 and the end-to-end test check this.
- **No JWT signing secret** is needed anywhere: the worker logs in to Postgres directly.
- **The seller cannot forge AI output.** `ai_complete_run` is not executable by `authenticated`, so a seller cannot create drafts attributed to the AI.
- **The grant-based `api.ai_upsert_draft` path** from the hardening milestone stays available for a future external worker. The in-app assistant does not use it.

## 3. Provider and model

| Setting | Value | Where |
|---|---|---|
| Provider | Anthropic Claude through `@anthropic-ai/sdk@0.131.0` (pinned) | `deno.json` |
| Model | `claude-opus-5-5` (`AI_MODEL`) | Function environment |
| Effort | `low` (`AI_EFFORT`: low, medium or high). Thinking is adaptive and always on for this model. | Function environment |
| Output | `output_config.format` = JSON schema (`OUTPUT_SCHEMA`); strict re-validation server-side | `output_schema.ts` |
| `max_tokens` | 8,000 (`AI_MAX_TOKENS`) | Function environment |
| Timeouts | 30 s per provider call (`AI_TIMEOUT_MS`); 45 s budget per request (`AI_BUDGET_MS`) | Function environment |
| Retries | SDK: 1 retry on 429/5xx/connection errors; pipeline: 1 retry on invalid output, only within the budget | `anthropic_provider.ts`, `pipeline.ts` |
| Caching | System rules and store context are marked `cache_control: ephemeral` | `anthropic_provider.ts` |
| Base URL | Fixed to `https://api.anthropic.com`, so an ambient environment variable cannot redirect data | `anthropic_provider.ts` |

Another provider can be added behind `AiProvider`. Phase 3 AD-07 says the evaluation set must pass before any provider, model or effort change.

## 4. Configuration and deployment (not performed)

Nothing was deployed. To deploy:
1. **Apply the migrations** `20261018090000_conversations.sql` and `20261018100000_ai_assist.sql`.
2. **Give the worker role a strong password**, outside version control:
   `alter role aisellia_ai_worker password '<generated>';`
3. **Set the function secrets** with `supabase secrets set`:
   - `ANTHROPIC_API_KEY`;
   - `AISELLIA_AI_WORKER_DB_URL`: the worker's connection string. Through the pooler, the user is `aisellia_ai_worker.<project-ref>`; use transaction mode (`prepare: false` is already set).
   - Optional: `AI_MODEL`, `AI_EFFORT`, `AI_MAX_TOKENS`, `AI_TIMEOUT_MS`, `AI_BUDGET_MS`, `AI_ALLOWED_ORIGINS`.
   - `SUPABASE_URL` and `SUPABASE_ANON_KEY` are provided by the platform.
4. **Deploy the function** with `supabase functions deploy ai-assist`. `verify_jwt = true` is set in `supabase/config.toml`.
5. **Decide on provider data terms** (AD-08) and set a provider spend limit before real customer messages are processed.
6. **Run the evaluation** ([G](g-evaluation-report.md)) with the real key and review the report before the pilot.

The app needs no configuration change: it calls `functions/v1/ai-assist` with the signed-in seller's session.
