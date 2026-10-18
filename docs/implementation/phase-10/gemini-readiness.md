# Phase 10: Gemini verification and safe local testing (readiness report)

**Date:** 2026-10-18. **Branch:** `S.H_Branch`. Builds on Phase 9 ([integrations report §7](../phase-9/integrations-report.md)).

**Boundaries kept:**
- nothing deployed;
- no hosted migration or hosted secret touched;
- no real account connected and no message sent;
- no paid API call made: **no Gemini API key was available in this environment**, so no real model response was tested.

## 0. Verdict

**Gemini is ready for isolated local testing as soon as a key is provided.** Everything that can be checked without a key has been checked and passes. The 35-scenario real-model evaluation is prepared, with spending caps, and has **not been run**. Real model behaviour is therefore **not verified**: passing the local Gemini imitation is not evidence that the real model behaves.

## 1. What already worked, what was assumed, what changed

| Area | Before this phase | Now |
|---|---|---|
| Gemini client (`ai-assist/gemini_provider.ts`) | Key in the `x-goog-api-key` header; JSON schema output; `thinkingLevel`; error codes never echo provider text | Unchanged, now confirmed against Google's docs (§2); **retry back-off added** (§4) |
| Model id `gemini-3.8-flash` | Chosen in Phase 9 from search results | Confirmed: an official model page exists for this id |
| Prices in the database | $1.50 / $7.50 per 1M input/output tokens, recorded as an assumption | Confirmed as Google's standard price from 2027-01-01. Until then Google charges half, so the app overestimates cost. Kept on purpose (conservative) |
| Spending caps | Per store and total; unknown costs counted at a reserve; timeouts charged the reserve | **Two defects fixed** (§4): concurrent requests from different stores could exceed the total cap; some failures with an unknown cost were charged nothing |
| Evaluation runner | Real API only with `AISELLIA_EVAL=1` and a key; own cost cap of $5 | **Defect fixed:** it would have hit the per-store "30 runs in 10 minutes" limit at scenario 31 and reported rate-limit refusals as failures. It now spreads scenarios over stores of 20. Default cap lowered to $2 |
| Messaging safeguards | AI output is a suggestion; sending needs the seller's confirmation of the exact text | Re-verified (§5); no change needed |

## 2. Official Gemini documentation: verified facts and open questions

**Source and method:**
- Direct page reads of `ai.google.dev` fail from this environment (DNS).
- Facts were therefore taken from official search results restricted to `ai.google.dev`, on 2026-10-18.
- The Gemini API host itself is reachable: an unauthenticated request returned Google's own `403 PERMISSION_DENIED` ("use an API key").

| Fact | Evidence | Status |
|---|---|---|
| Model id `gemini-3.8-flash` exists; thinking levels low / medium / high; 1M-token context; 64k max output | [Model page](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash), [What's new](https://ai.google.dev/gemini-api/docs/whats-new-gemini-3.8), [Thinking](https://ai.google.dev/gemini-api/docs/generate-content/thinking) | Verified (official snippet). One official page labels this id "Gemini 3.6 Flash", probably a documentation error |
| `generateContent` with `responseJsonSchema` requires `responseMimeType`; `thinkingConfig.thinkingLevel`; setting both a level and a budget is an error; "minimal" is not accepted by every model | [API reference](https://ai.google.dev/api/generate-content), [Thinking](https://ai.google.dev/gemini-api/docs/generate-content/thinking) | Verified; the code sends a level only, never "minimal" |
| Authentication: `x-goog-api-key` header on every request; keys never in client code or Git; a backend makes the calls | [API keys](https://ai.google.dev/gemini-api/docs/api-key) | Verified; this is how Aisellia already works |
| Key restrictions: restrict keys to the Gemini API (and by IP or app where possible); Google announced that unrestricted standard keys will be rejected | [API keys](https://ai.google.dev/gemini-api/docs/api-key) | Verified in general; the exact enforcement date is inconsistent between Google pages (**uncertain**) |
| Price, standard paid tier: **$0.75 in / $3.75 out per 1M tokens until 2026-12-31; $1.50 / $7.50 from 2027-01-01**. Output includes thinking tokens. Cached input $0.075, then $0.15. A free tier exists | [Pricing](https://ai.google.dev/gemini-api/docs/pricing) | Verified (snippet of a page updated about 2 days earlier). The free-tier row was compressed in the snippet: re-check on the page |
| Failed requests with an HTTP 400 or 500 error are not charged, but count toward quota | [Billing](https://ai.google.dev/gemini-api/docs/billing) | Verified; used for the accounting fix (§4) |
| Rate limits are per **project** (not per key), in RPM / TPM / RPD; RPD resets at midnight Pacific time. Tiers: Free, Tier 1 (billing linked), Tier 2, Tier 3. Spend limits per rolling 10 minutes ($10 at Tier 1) | [Rate limits](https://ai.google.dev/gemini-api/docs/rate-limits) | Verified. **The per-model numbers for `gemini-3.8-flash` were not found:** read them on the project's rate-limit page in AI Studio |
| Monthly spend caps per project (set in AI Studio) and per billing tier (Tier 1 $250). Project caps are *not hard limits*, and billing data can lag about 10 minutes | [Billing](https://ai.google.dev/gemini-api/docs/billing) | Verified |
| Retry only transient errors (429, 408, 5xx) with exponential back-off; never 400, 402 or 403 | [Troubleshooting](https://ai.google.dev/gemini-api/docs/troubleshooting), [API errors](https://ai.google.dev/gemini-api/docs/api-errors) | Verified; the code now backs off (§4) |
| Finish reasons `SAFETY`, `PROHIBITED_CONTENT`, `MAX_TOKENS`; `promptFeedback.blockReason`; `usageMetadata.thoughtsTokenCount` | [API reference](https://ai.google.dev/api/generate-content) | Verified; mapped in `parseGeminiResponse` |
| An empty text with `MAX_TOKENS` means the thinking used up the output budget | [Long decode](https://ai.google.dev/gemini-api/docs/generate-content/long-decode) | Verified. The risk is low at `AI_EFFORT=low` with 8,000 output tokens; such a run is retried once, then fails as invalid output and is charged its usage |
| **Free tier:** prompts and responses may be used to improve Google's products and read by human reviewers; on paid (billing-enabled) use they are not | [Terms](https://ai.google.dev/gemini-api/terms), [Pricing](https://ai.google.dev/gemini-api/docs/pricing), [Logs policy](https://ai.google.dev/gemini-api/docs/logs-policy) | Verified. **Never send real customer data with a free-tier key**; the 35 synthetic scenarios are acceptable on the free tier |
| Languages: Arabic and Central Kurdish appear in Google's language tables for the audio and Live features; no general text-language list was found for `gemini-3.8-flash` | [Live API](https://ai.google.dev/gemini-api/docs/live-api/capabilities), [TTS](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-tts) | **Uncertain** for text generation in Sorani: only the real evaluation and a native review can establish quality |

## 3. Safe local access (Task 3)

**How to provide a key (no key was provided):**
- Add it in this cloud environment's settings, as the environment variable `GEMINI_API_KEY`.
- Never paste it into chat, a tracked file, or `supabase/functions/.env`. That file is ignored by Git, but the environment variable is the safer place.
- A new session picks it up.

**Recommended key setup:**
- a dedicated Google Cloud / AI Studio project for testing only;
- a key restricted to the Gemini API;
- a monthly project spend cap set in AI Studio;
- no other services enabled.

**How the key is protected** (verified by tests):
- it is read only by server-side code: the Edge Function or the evaluation runner;
- it is sent only in the request header, never in a URL;
- it never appears in logs or reports (new assertion in `gemini_e2e_local_test.ts`);
- the Flutter app has no provider key.

**Limits that apply locally:**
- Application (database, per day): $2.00 per store and $20.00 across all stores; 30 runs per store per 10 minutes; 300 runs per store per day. Unknown costs count at a reserve of $0.15 per run.
- Evaluation runner: stops once the recorded cost reaches `--max-cost-usd` (default **$2**, overshoot at most one scenario).
- Google side (the owner sets these): the project spend cap, the billing tier cap and the free-tier quotas. These are separate from the application's caps, and the application cannot see or enforce them.

**Estimated cost of one full evaluation** (an estimate, not a measurement):
- per run: about 4–8k input and 0.5–2k output tokens, at most 2 attempts;
- at the current price: about **$0.10–$1.00** in total;
- the app records twice that, because it uses the 2027 price, which still fits the $2 cap.
- On a free-tier key: no charge, within its quota.

**Command, once the key is in the environment:**

```
cd supabase/functions/ai-assist
deno run --allow-net --allow-env --allow-read --allow-write=./eval/out eval/run_eval.ts --plan   # free, prints what will run
AISELLIA_EVAL=1 SUPABASE_TEST_URL=http://127.0.0.1:54321 SUPABASE_TEST_PUBLISHABLE_KEY=... SUPABASE_TEST_JWT_SECRET=... \
  deno run --allow-net --allow-env --allow-read --allow-write=./eval/out eval/run_eval.ts --max-cost-usd=2
```

- **No messaging provider is involved.** The scenarios are pasted conversations on test stores in the local database; no channel is connected.
- **Where results go:** `eval/out/`, which Git ignores. The results include the model's replies for native review.
- **Free key check:** `ops/staging_check.ts --check-provider` can confirm the key works without spending tokens (a model lookup).

## 4. Spending and retry protections (Task 5)

| Requirement | Result | Evidence |
|---|---|---|
| Failed and timed-out requests count toward the daily limit | Timeouts were already charged the reserve. **Fixed:** a connection lost after sending, an unreadable 2xx answer, an unexpected error, or a failure without an HTTP status were charged $0. They now cost the reserve. HTTP 4xx/5xx answers, 429s and "no key" stay at $0 (Google does not bill them) | `20261023090000_ai_budget_hardening.sql`; pgTAP suite 16 section 8 (8 new assertions) |
| Concurrent requests cannot exceed the limit | Per store: already serialised by the store row. **Defect found and fixed:** requests of *different* stores could both pass the all-stores check. That check is now serialised by a transaction-scoped advisory lock | New `tests/budget_race_local_test.ts`: it failed before the fix and passes after it; the second store waits, then is refused (`budget_total`) |
| Rejected before calling Gemini when the budget is exhausted | Yes: the database refuses the run (`RATE_LIMITED`, `budget_store` / `budget_total`) before any provider call; each request must leave room for its own reserve | Suite 16 sections 6–7 |
| Conservative accounting when the cost is unknown | Runs in flight, or expired after possibly reaching the model, count at the reserve. Unknown models are costed at the highest known price. Prices are recorded at twice today's price | Suite 16; §2 |
| No uncontrolled retry loop | At most 2 HTTP calls per provider request (one retry, after 1 s, or 2 s for a 429, or the answer's Retry-After, and only if at least 3 s of budget remain). At most 2 provider requests per run (the second only for truncated or invalid output). Runs are created only by a seller action and limited per store | New test "retries are bounded and back off"; the app replays a lost answer with the same idempotency key, so no new model call |
| A retry cannot send a customer message | `ai-assist` contains no send call; the AI roles cannot execute any send, claim or template function; live conversations get no AI (`ai_live_enabled` false in all 28 local stores, no API can set it) | Suites 01, 18, 22, 24; database query on the local stack |
| Logs contain no key, message text or personal data | Logs carry run ids, statuses, codes, token counts and latency only. The customer's phone number is tokenised before anything is sent to Google | New assertions in `gemini_e2e_local_test.ts`; existing `pipeline_test.ts` check |

**Residual risk:** if a connection is lost after Google processed a request and the retry then succeeds, the first call may be billed but is not recorded. This is bounded at one extra call per request, and the doubled price margin covers it in practice.

## 5. Messaging safeguards (Task 6)

- **AI replies stay suggestions.** In live conversations, "Use this reply" only fills the reply box; every send needs the seller's confirmation of the exact text (Phase 9).
- **All six providers remain unable to send:**
  - Instagram, Messenger, WhatsApp, Telegram, Viber: `in_development`, with sending recorded as an `assumption`;
  - TikTok: `unresolved`.
- **Nothing scheduled or connected:** the background sender is not scheduled, nothing is deployed, and no real account is connected.

## 6. Results

**6.1 Offline tests passed** (fresh local database):
- pgTAP: 24 suites, **1,130 assertions** (+8);
- AI-role HTTP checks: 17/17;
- Deno `ai-assist`: **74 tests** (+2), including the Gemini end to end against a local imitation (8 steps: grounded price, invented price caught, Sorani price held back, English delivery guarantee held back, Arabic false confirmation kept as a draft, Sorani injection escalated, key only in the header, no personal data in logs);
- Deno `_channels`: 55 tests, 112 steps;
- all six Edge Functions type-check;
- Flutter: format and analyze clean, **323/323** tests;
- evaluation plan mode: 35 scenarios (en 20, ckb 8, ar 7), refused without a key.

**6.2 Real Gemini API tests passed:** **none.** No key was available.

**6.3 Tests that failed, and why:**
- The race test failed against the previous code, as designed, which proved the defect. It passes after the fix.
- No other failures.

**6.4 Tests blocked by missing credentials:**
- the 35-scenario evaluation with the real model: correctness, language match, invented prices, discounts and delivery promises, false confirmations, unsupported policies, prompt injection;
- real malformed or empty responses, and real API errors, timeouts and rate limits (only imitated so far);
- the free key check (`staging_check.ts --check-provider`);
- the actual token usage and cost per scenario;
- the project's real rate limits;
- native review of the Sorani and Arabic replies.

**6.5 Pricing:**

| | Status |
|---|---|
| `gemini-3.8-flash` standard price | **Confirmed:** $0.75 / $3.75 per 1M tokens until 2026-12-31; $1.50 / $7.50 from 2027-01-01 |
| What the app records | The 2027 price (conservative) |
| Actual cost per scenario | **Unresolved** (needs a real run) |
| Free-tier eligibility and quota for this project | **Unresolved** |
| Whether the price row should follow the introductory rate | **Owner decision:** recommend keeping the conservative rate |

**6.6 Remaining security risks:**
1. A free-tier key sends prompts to Google for product improvement: use synthetic data only on it.
2. Google's spend caps are not hard limits and lag about 10 minutes: keep the application caps as the primary brake.
3. One possibly billed but unrecorded call per lost connection (§4).
4. Real-model behaviour on fabricated non-numeric promises is still unmeasured (open since Phase 8.5).
5. Sorani and Arabic quality is unreviewed.
6. Key enforcement dates are inconsistent in Google's docs: use a restricted key.

**6.7 Recommended next steps:**
1. Create a dedicated test project and a key restricted to the Gemini API, set an AI Studio spend cap, and add `GEMINI_API_KEY` to this environment.
2. Run `staging_check.ts --check-provider`, then the evaluation with `--max-cost-usd=2`.
3. Have native speakers review the Sorani and Arabic replies in `eval/out/`.
4. Fix the prompts or rules only against measured failures.
5. Re-check the pricing and rate-limit pages directly before any hosted use.

## 7. Changes in this phase

- `supabase/migrations/20261023090000_ai_budget_hardening.sql`: the total-cap lock, and reserve charging for unknown-cost failures. **Local only; not applied to any hosted database.**
- `ai-assist/gemini_provider.ts`: bounded back-off before the single retry.
- `ai-assist/eval/run_eval.ts`, `eval/summary.ts`: scenarios spread over stores of 20; default cap $2.
- Tests:
  - `tests/budget_race_local_test.ts` (new);
  - `tests/gemini_provider_test.ts` (back-off);
  - `tests/gemini_e2e_local_test.ts` (logs and phone);
  - `tests/eval_summary_test.ts`;
  - pgTAP suite 16 section 8.
