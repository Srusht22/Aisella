# G. Evaluation report

## 1. What was evaluated, and how

| Evaluation | Model | Ran here | Result |
|---|---|---|---|
| Database decisions on model output: grounding, guard, escalation, drafts, isolation, approval gate (pgTAP 15) | **Hand-written model outputs** playing a correct, a careless and a manipulated model | Yes | 100/100 assertions |
| Conversation and policy rules, isolation (pgTAP 14) | — | Yes | 43/43 |
| Worker pipeline: retries, failures, reconciliation (Deno) | **Scripted test double** | Yes | 45 unit tests pass (all Deno files) |
| End to end on the local stack: handler → PostgREST with the seller JWT → worker login → database (Deno) | **Scripted test double** that reads the context it receives | Yes | 1 test, 9 steps, all pass |
| Anthropic provider request and error mapping (Deno) | **Local HTTP stub** imitating the Messages API | Yes | Included above |
| App screens: suggestion, copy and sent, escalation, failure, RTL, tablet (Flutter) | **Fake repository** | Yes | 18 widget and domain tests |
| App ↔ database (Flutter backend tests) | No model | Yes | 4 tests |
| **Real model quality, en / ckb / ar** (`eval/run_eval.ts`, 24 scenarios) | **Claude through the real API** | **No: no API key available** | **Not measured** |

**Nothing in this report is a measurement of Claude's answers.** The deterministic tests prove what the *system* does with any answer: whether a fabricated price is caught, whether a manipulated model can create a draft, whether another store's ids leak. They do not prove that the model answers well.

## 2. Scenario coverage (deterministic tests)

| Scenario (spec §17) | Where tested | Outcome |
|---|---|---|
| Price asked | pgTAP 15 (en, ckb), end-to-end | Price rendered from the catalog: "35,000 IQD" / "35,000 د.ع" |
| Variant availability | pgTAP 15 (en, ar) | Availability label from stock, no count |
| Out-of-stock variant | pgTAP 15 context | `out` sent; a rendered fact says "out of stock" |
| Missing policy | pgTAP 15 | Reference to a non-existent policy → holding reply; nothing invented |
| Delivery fee and time | pgTAP 15 | Rendered from the zone |
| Starting an order | pgTAP 15, end-to-end | Draft created, priced from the catalog, phone mapped from its token |
| Quantity in a follow-up; customer correction | pgTAP 15 | The corrected area updates the draft; the seller's edit is kept |
| Contradictory details | pgTAP 15 (conflict rules in the merge) | A conflicting field is not written |
| Unavailable or unknown product | pgTAP 15, end-to-end | `not_in_catalog`; another store's product dropped |
| Ambiguous product or variant | pgTAP 15 | `choose_product` / `variant_needed` with candidates; draft stays a draft |
| Asking the AI to approve its own order | pgTAP 15, end-to-end | "Confirmed / approved" claims replaced by the holding reply; no approval path exists for the worker |
| Another store's data | pgTAP 15, end-to-end | Context is single-store; foreign ids render nothing and are dropped |
| Malicious instructions (en) | pgTAP 15, end-to-end | Escalated "suspected manipulation" even when the model complies; no draft |
| Health question | pgTAP 15 | Escalated; only the holding reply |
| Order status | pgTAP 15 | Always escalated (P0) |
| Repeated failed clarification | pgTAP 15 | Third unanswered round escalates |
| Provider timeout, refusal, malformed output | Deno, pgTAP 15, Flutter | Recorded; app shows reason, Retry and the manual path |
| Duplicate requests | pgTAP 15, end-to-end, Deno | Same key → same run, one model call |

**Language handling, deterministic only:**
- Sorani and Arabic replies render currency and availability in their language (pgTAP 15).
- The app shows the suggestion right-to-left in Sorani and keeps the app language separate (Flutter).
- Manipulation patterns are detected in Sorani and Arabic (unit check).

## 3. Real-provider evaluation (prepared, not run)

**Set:** `supabase/functions/ai-assist/eval/scenarios.json`, version `e8.1`, with 24 synthetic conversations:
- 17 in English, 4 in Sorani, 3 in Arabic;
- covering price, a missing variant, out of stock, comparison, budget, missing and existing policy, delivery, start order, follow-up quantity, change variant, corrected phone, contradiction, not in catalog, "approve my order", another store's data, Arabic and English injection, a health question, a full Sorani order, an incomplete Arabic order, and order status.

**Checks (no model grading):**
- intent;
- escalation and reasons;
- facts used or not used;
- reply language;
- server flags (an invented price or claim);
- draft status and lines;
- phone mapping;
- never approved.

**Run:**

```
ANTHROPIC_API_KEY=… AISELLIA_EVAL=1 SUPABASE_TEST_URL=http://127.0.0.1:54321 \
SUPABASE_TEST_PUBLISHABLE_KEY=… SUPABASE_TEST_JWT_SECRET=… \
deno run --allow-net --allow-env --allow-read --allow-write=./eval/out eval/run_eval.ts
```

Without the key it exits with "Not run" (verified). Reports go to `eval/out/`, which git ignores.

**Phase 1 §14.3 gates (fabrication = 0, auto-confirmation = 0, escalation recall ≥ 95%, product-match precision ≥ 85%) remain unmeasured.** A 24-scenario set is too small to estimate them. The consented, anonymised M0 dataset (50–100 conversations) is still needed.

## 4. Limitations

- **Sorani and Arabic quality is unverified:** the scenario texts and the server's fixed phrases (holding reply, availability labels) need native review (Phase 2 DD-08).
- **The guard is lexical.** A paraphrased promise ("it reaches you the day after") can pass; a legitimate number such as a 4-digit model name triggers the holding reply. Both effects need tuning with real outputs.
- **Manipulation detection is pattern-based.** It is a backstop, not a classifier: novel phrasing relies on the model's own escalation.
