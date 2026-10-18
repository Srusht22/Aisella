# Final pre-publication checklist

**Purpose:** everything that must be verified **immediately before publication**. It covers the items deliberately deferred during development (no paid calls, no real accounts, no hosted changes).

**Rules:**
- Each item needs the owner's explicit approval before it starts, because most cost money, touch hosted resources or reach real people.
- Tick an item only with evidence: a report file, a commit, or the date and the person who checked it.
- A mocked or local test never ticks an item that says "real".

**Related:**
- [K. Staging setup](../architecture/phase-9/k-staging-setup-checklist.md) (accounts, secrets by name, steps);
- [MC-6 public-launch criteria](../architecture/phase-9/n-milestones-public-launch.md#mc-6-public-launch-readiness-and-operational-scaling);
- [Phase 8.5 open gates](phase-8.5/h-validation-gates-and-review.md);
- [project status](project-status.md).

## A. Gemini API key and real-model evaluation (deferred by the owner; nothing done yet)

- [ ] A1. A dedicated Google Cloud / AI Studio project, with a key **restricted to the Gemini API**. Prefer a billing-enabled project: on the free tier, Google may use prompts to improve its products and human reviewers may read them, so a free-tier key must only ever receive synthetic data.
- [ ] A2. A monthly project spend cap set in AI Studio; budget alerts in Cloud Billing. Both are Google-side controls, separate from Aisellia's caps.
- [ ] A3. The key is stored only as a secret: the environment variable `GEMINI_API_KEY` for local runs, or `supabase secrets set` for staging. Never in chat, Git, the Flutter app or logs.
- [ ] A4. The key check passes: `ops/staging_check.ts --check-provider` (a free model lookup).
- [ ] A5. The **35-conversation evaluation** has run with the real model:
  - command: `eval/run_eval.ts --max-cost-usd=2` ([readiness report §3](phase-10/gemini-readiness.md));
  - it covers 20 English, 8 Sorani and 7 Arabic conversations;
  - results are saved in `eval/out/` (ignored by Git) and summarised in a report.
- [ ] A6. Real behaviour reviewed, per language:
  - invented prices, discounts and delivery promises;
  - false order confirmations and unsupported policies;
  - prompt injection;
  - malformed or empty responses.
  Every failure is fixed or recorded with a decision. The evaluation's safety requirements are **not** relaxed to pass.
- [ ] A7. Native speakers have reviewed the real Sorani and Arabic replies ([protocol](phase-8.5/h-validation-gates-and-review.md)).
- [ ] A8. The Phase 1 §14.3 gates are measured on the 50–100 consented, anonymised conversations. Otherwise AI suggestions launch **disabled**.
- [ ] A9. The non-numeric fabricated-promise risk is measured on real outputs, and accepted or mitigated.

## B. API pricing, quotas, budget protections and error handling

- [ ] B1. The pricing page has been re-read directly ([pricing](https://ai.google.dev/gemini-api/docs/pricing)), and `app.ai_model_prices` reflects the decision. Today the app records the 2027 price, deliberately conservative.
- [ ] B2. The project's real rate limits (RPM, TPM, RPD) have been read in AI Studio and compared with Aisellia's limits:
  - 30 runs per store per 10 minutes;
  - 300 runs per store per day;
  - $2 per store and $20 overall per day.
- [ ] B3. The observed cost per run (from the evaluation) has been compared with the reserve of $0.15 per run and the daily caps; the values are adjusted if needed.
- [ ] B4. Real 429, 5xx and timeout behaviour has been observed: one retry after a back-off, the seller sees a clear message, and nothing loops.
- [ ] B5. The concurrency and unknown-cost protections still pass on staging: `budget_race_local_test.ts` and pgTAP suite 16.
- [ ] B6. A retry can never send a customer message: the AI roles have no send privileges (suite 01), and `ai_live_enabled` stays false unless the owner decides otherwise.

## C. English, Sorani and Arabic quality

- [ ] C1. Native review of all app strings:
  - `app_ckb.arb` and `app_ar.arb` are machine-drafted;
  - the review also covers the confirmation templates and the date and month names.
- [ ] C2. Real-device checks: RTL layout, fonts, Eastern Arabic digits, and 200% text size in all three languages.
- [ ] C3. Real-model replies in all three languages reviewed (A7).

## D. Messaging providers: approvals and end-to-end tests

- [ ] D1. For each launch provider, its official documentation has been read directly, and each capability recorded as `verified` with URL and date. Today every capability is an assumption, see [provider verification](phase-9/provider-verification.md) and [integrations report §4 and §7.5](phase-9/integrations-report.md).
- [ ] D2. Platform approvals:
  - Meta App Review and Business Verification;
  - WhatsApp: payment method and approved templates;
  - TikTok partner access;
  - Viber commercial terms.
- [ ] D3. An end-to-end test on a **test** account per provider, on staging:
  - connect, receive, reply with seller confirmation;
  - delivery receipts, the unknown-outcome path and disconnect.
- [ ] D4. The background sender's scheduler is configured on staging only; its secret is at least 32 characters.
- [ ] D5. Live AI suggestions, if they are ever enabled, only after A5–A9 and the owner's written decision. Auto-send stays out of scope (BR-47).

## E. Security, deployment, database migration and rollback

- [ ] E1. Security review and penetration test (MC-6). Secret scan of the full Git history.
- [ ] E2. Production project separate from staging; region and data-residency decision; secret-rotation runbook.
- [ ] E3. **Migrations:** apply them in order to staging first, then run the full pgTAP suite and the HTTP role checks there. Record the migration list and each one's reversibility.
  - Migrations are forward-only. Rollback means restoring a backup, or a corrective migration that has been tested on staging.
- [ ] E4. A backup taken before the production migration, and a **restore rehearsal** done (AD-05).
- [ ] E5. Edge Functions deployed from a reviewed commit; `verify_jwt` settings checked (`channel-webhook`, `channel-oauth` and `channel-worker` are public by design and authenticate otherwise).
- [ ] E6. App release: signing, store listings, privacy policy and terms, and the data-processing terms with Google and Meta.
- [ ] E7. Monitoring and alerts, error reporting, an on-call contact, and the support-access procedure.
- [ ] E8. A rollback plan for the app: the previous store build is available; features can be switched off on the server (AI, channels) without a new build.
- [ ] E9. The owner's launch decision, recorded.
