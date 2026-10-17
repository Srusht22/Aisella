# F. Cost and reliability

## 1. Usage and cost metrics

Every run records in `app.ai_runs`:
- model and served model, prompt version, effort;
- stop reason, provider request id, correlation id, attempts;
- latency;
- input, output, cache-read and cache-write tokens;
- an **estimated** cost from `app.ai_model_prices`.

The cost formula, in micro-USD, is `(in × input + out × output + cache_read × cache_read_price + cache_write × cache_write_price) / 10⁶`.

| Model | Input | Output | Cache read | Cache write |
|---|---|---|---|---|
| claude-opus-5-5 | $4 / MTok | $20 / MTok | $0.20 / MTok | $5 / MTok |

These prices come from the Phase 3 cost estimate, so they are only as good as that estimate. Operators must verify them before relying on the figures.

`api.ai_usage(store, days)` reports calls, successes, failures, escalations, tokens and estimated cost per day. No message content is logged to compute usage. Function logs carry only event names, run ids, statuses, token counts and correlation ids.

**Not measured:**
- real per-store cost;
- latency against the real provider (no API key was available).

## 2. Limits

| Limit | Default | Error |
|---|---|---|
| AI requests per store per 10 minutes | 30 | `RATE_LIMITED` (scope `store_10min`, `Retry-After`) |
| AI requests per store per day | 300 | `RATE_LIMITED` (scope `store_day`) |
| New AI orders per store per day | 50 | Draft not created; flag `draft_quota_reached` |
| Runs per conversation at a time | 1 | `AI_BUSY` |
| Claim window / run duration | 60 s / 120 s | Run expires |
| Context | 20 messages, 12,000 chars; full catalog up to 400 variants, otherwise top 40 | — |
| Output | `max_tokens` 8,000; reply ≤ 4,000 chars; ≤ 40 segments; ≤ 20 lines | Invalid output |
| Messages | ≤ 4,000 chars each, ≤ 20 per import, ≤ 2,000 per conversation; ≤ 500 new conversations per store per day | `VALIDATION_FAILED` / `LIMIT_EXCEEDED` / `RATE_LIMITED` |

The limits are in `app.ai_limits`; operators can change them, not the app.

**Cost control.**
- One model call per request, plus at most one retry on invalid output, and only within the time budget.
- Cached prompt prefix: rules and store context.
- Bounded context.
- No agent loop.

## 3. Failure handling

| Failure | Behaviour | Tested |
|---|---|---|
| Provider timeout (30 s) | Run `timeout`; app: "The AI took too long", Retry, manual path | Deno pipeline, provider stub, end-to-end; Flutter |
| Provider 429 / 529 / 5xx / connection | SDK retries once with backoff, then `rate_limited` or `provider_error` | Provider stub tests |
| Refusal | Run `refused`; conversation "Needs you"; no suggestion | Pipeline, pgTAP 15 |
| Truncated or invalid JSON | One retry, then `invalid_output`; nothing persisted | Pipeline, pgTAP 15 |
| Database connection lost after writing | `ai_run_state` reconciles; completion written at most once | Pipeline |
| Client timeout (60 s) | Same key replayed once; the server returns the existing run; the app explains and offers refresh | Flutter (fake) |
| AI switched off or paused | Refused before any call (`AI_DISABLED`, `AI_PAUSED`) | pgTAP 15, end-to-end, Flutter backend test |
| AI service not running | `request_ai_assist` refused; catalog, orders and manual replies keep working | Flutter backend test |

Core navigation never depends on the model. The inbox, conversations, orders and catalog load without the function.

## 4. Known operational constraints

- **Function boot in the edge runtime is unverified.** In this sandbox, the Supabase edge-runtime container (v1.77.4) could not download npm packages through the environment's TLS-intercepting proxy. The function was therefore exercised with Deno 2.9.6 directly, against the real local database and PostgREST, but not inside the edge-runtime container.
- **The worker password must be rotated by an operator.** There is no automatic rotation.
- **Alerts are not wired.** Phase 3's thresholds (store over its cap, organisation spend, invalid-output rate above 5%) can be computed from `ai_runs` / `api.ai_usage`, but nothing pages anyone.
