# G. Phase 8.5 validation report

**Branch:** `S.H_Branch`. **Date:** 2026-10-17.
- Not deployed.
- No live channel connected.
- No customer contacted.
- No provider setting changed and no paid API call made.

**Waiting for owner approval. Phase 9 has not started.**

## 1. Verified (ran here, on the local stack)

| What | Evidence |
|---|---|
| No Anthropic key and no staging credentials in the environment | Presence checks only; no value printed ([A §1](a-key-configuration.md#1-what-was-checked-2026-10-17), [D §1](d-staging-readiness.md#1-status-hosted-validation-is-blocked)) |
| The Phase 8 reply guard let 19 of 30 unsafe phrasings through and flagged 1 safe one | Re-run of the Phase 8 function in a rolled-back transaction ([B §1](b-red-team-and-safety-fixes.md#1-failures-found-in-the-phase-8-reply-guard)) |
| After the fix: all 30 unsafe phrasings flagged and all 17 safe ones pass; model-written numbers outside the catalog and the customer's messages are held back | pgTAP 16 |
| No AI order without buying intent, no AI approval, stock re-checked at approval, single-store context, no cross-store lines or zones, no order path for the worker | pgTAP 16 (with Phase 8 suites 11 and 15) |
| Spending brakes per store and in total; Sonnet, Haiku and US-only costing | pgTAP 16 |
| Customer anonymisation redacts name and number in all order notes, history notes and audit rows; nothing deleted; history still append-only | pgTAP 17 |
| Retention jobs for AI outputs and message bodies | pgTAP 17 |
| `inference_geo` sent only when configured; served region recorded | Deno tests against a local HTTP stub of the API |
| Evaluation report logic per language; spending cap; refusal without a key; refusal of a scenario file inside the repository; `--plan` | Deno unit tests and manual runs |
| Staging preflight: every database check passes against the local worker role, and the output never contains the password | Deno test on the local stack |

**Final regression on a freshly reset local database:**

| Suite | Result |
|---|---|
| pgTAP, 17 suites | **808 assertions, all pass** (688 before; +78 in suite 16, +42 in suite 17; suite 13 expectations updated) |
| AI-role HTTP checks | 17 / 17 |
| Deno: fmt, lint, type check | Clean |
| Deno tests, including end-to-end on the local stack | **56 pass** (46 before); the worker password is cleared afterwards (verified) |
| Flutter: format, analyze, tokens, import boundaries, directional geometry | Clean |
| Flutter tests with the local backend | **300 / 300 pass** |

## 2. Not tested, and why

| Item | Why not | What it needs |
|---|---|---|
| **The real-model evaluation** (24 scenarios, en / ckb / ar): grounded accuracy, fabrication, escalation, latency and cost per language | No API key | A staging key ([A §2](a-key-configuration.md#2-how-to-configure-a-key-securely)), then about USD 0.5–1 |
| **Language quality** in Sorani and Arabic | Needs the model's replies and a native reviewer. A passing script would not prove it. | The evaluation, then native review |
| How often the real model writes number-free promises or claims, which the lexical guard can miss ([B §2.2](b-red-team-and-safety-fixes.md#22-lexical-guard-widened-in-three-languages-appreply_guard)) | No model | The evaluation; the `fabrication.shown_to_seller` measure |
| Hosted staging: migrations applied, pooler login, TLS, function boot in the edge runtime, deployed endpoint, provider key check | No credentials or project; deployment not authorized; the edge runtime cannot boot in this sandbox | [D §4](d-staging-readiness.md#4-staging-checklist-for-when-deployment-is-authorized) |
| Phase 1 §14.3 gates on real conversations | No consented samples | [F](f-consented-samples.md) |
| Provider retention terms beyond the public docs | The privacy-center article could not be fetched; the commercial agreement was not reviewed | Owner review ([C §1](c-provider-data-and-cost.md#1-what-the-provider-retains-and-where-it-processes)) |
| Devices and screen readers; native review of the 156 Phase 8 strings | Unchanged from Phase 8 | As in Phase 8 H §8 |

## 3. Safety failures found, and their fixes

| # | Failure | Severity | Fix | Test |
|---|---|---|---|---|
| 1 | Free delivery, discounts, "cheaper" and BOGO passed the guard (6 phrasings in en / ckb / ar) | High: a seller copying it commits to a price the catalog does not hold | Lexical guard widened; numbers structurally checked | pgTAP 16 |
| 2 | Delivery-time promises passed: "arrive in 2 days", same day, by Friday, next week, Sorani and Arabic day counts (7 phrasings) | High | Guard widened; a number of days must come from the catalog or the customer, otherwise the reply is held | pgTAP 16 |
| 3 | Order-state claims passed: "placed", "booked", "all set", "on the way", "طلبك مؤكد", "داواکارییەکەت ئامادەیە و دەینێرین" (6 phrasings) | High: tells the customer an order exists that the seller never approved | Guard widened | pgTAP 16 |
| 4 | Any number written as a bare digit passed the guard, for example "That one is 45 for you" or "We still have 3" | High | `app.reply_number_check` (structural) | pgTAP 16 |
| 5 | "Would you like it delivered to Erbil?" was held back as a claim | Low (false positive) | Claim pattern narrowed | pgTAP 16 |
| 6 | Customer anonymisation left the name and phone in order notes, history notes and audit notes | Medium (privacy; open since Phase 7) | `20261019100000_customer_notes_redaction.sql` | pgTAP 17 |
| 7 | No limit on what a store, or all stores, can spend per day | Medium (cost) | 24-hour cost brakes | pgTAP 16 |

**No failure was found in:**
- cross-store isolation;
- unauthorized order creation;
- AI approval;
- fabricated prices on order lines.

These were already structural in Phase 8, and new tests now pin them.

**Residual risk:** number-free paraphrased promises and claims can still pass the lexical guard. Examples: "It reaches you the day after", "Nothing to pay for delivery". The seller sees every suggestion before sending it, and nothing is sent automatically. That stays true until Phase 9 changes it.

## 4. Recommendation on Phase 9

**Not ready to begin Phase 9 as a live-channel phase yet.** The parts this environment could check are sound. What decides Phase 9's safety has not been measured:

1. **The real model has never been called.** Phase 9 connects real customers, and AD-07 says the evaluation set must pass first. Fabrication shown to the seller must be 0 in every language. Escalation must be caught in every case the set expects.
2. **Sorani and Arabic quality is unknown.** A native reviewer must read the evaluation replies.
3. **Staging has not run.** The pooler login, the edge-runtime boot and the deployed endpoint are unverified, and live messaging depends on them.
4. **AD-07 and AD-08 are open:** the model tier, the spend limits, ZDR and the inference region ([C](c-provider-data-and-cost.md)).
5. **No consented conversations.** The Phase 1 gates cannot be estimated.

**Proposed order, each step needing the owner's go-ahead:**
1. Configure a staging key and a Console spend limit. Run the evaluation (about USD 1) and review it, including native review.
2. If any fabrication reaches the seller, consider a second-pass check before Phase 9. Options: a stricter prompt (p8.2) or a cheap classifier call; either needs its own evaluation.
3. Authorize a staging deployment and run the [D §4](d-staging-readiness.md#4-staging-checklist-for-when-deployment-is-authorized) checklist.
4. Decide AD-07 and AD-08. Collect the consented M0 set.
5. Then begin Phase 9. Keep "suggest, the seller sends" as its first step, before any automatic sending.

The Phase 9 design work could start in parallel without connecting a channel, if the owner prefers. Implementation that reaches real customers should wait for steps 1–3.
