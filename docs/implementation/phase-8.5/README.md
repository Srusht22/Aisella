# Aisellia — Phase 8.5: validation and staging readiness

**Status:** done as far as this environment allows. **Waiting for owner approval. Phase 9 has not started.**

**Scope:** a limited milestone between Phase 8 and Phase 9, authorized by the owner after Phase 8 was accepted.
- **In scope:** validation, safety tests, cost and provider-terms review, staging preparation, the customer-data fixes.
- **Out of scope:** Phase 9, live messaging channels, automatic sending, deployment, contacting customers.

**What happened:**
- **The real-model evaluation did not run.** No Anthropic API key is configured in this environment. [A](a-key-configuration.md) gives the exact steps to configure one securely.
- **A deterministic red-team of the reply checks found 19 of 30 unsafe phrasings passing.** Examples: "Delivery is free for you", "It will arrive in 2 days", "Your order is placed!", and confirmations in Sorani and Arabic. All 19 are fixed. There is now a structural number check that does not depend on wording, and 78 new database assertions ([B](b-red-team-and-safety-fixes.md)).
- **Spending brakes:** requests now stop at a per-store and a total 24-hour cost ([C](c-provider-data-and-cost.md)).
- **"Delete this customer" now reaches the seller's free-text notes**, which closes the open order-notes gap. The retention jobs now have tests ([E](e-customer-data.md)).
- **Staging:**
  - A read-only preflight script exists.
  - Hosted validation is **blocked**: there are no staging credentials and no hosted project ([D](d-staging-readiness.md)).
- **No consented customer conversations exist.** [F](f-consented-samples.md) gives a collection template and consent text; none were invented.

| # | Document | Contents |
|---|---|---|
| A | [Key configuration](a-key-configuration.md) | Key availability check; how to configure it securely; how to run the evaluation |
| B | [Red-team and safety fixes](b-red-team-and-safety-fixes.md) | Failures found, fixes, structural checks, tests |
| C | [Provider data terms, model and spending](c-provider-data-and-cost.md) | Retention and region review, proposed AD-07 and AD-08 decisions, caps, spending limit |
| D | [Staging readiness](d-staging-readiness.md) | Secrets, checklist, preflight script, blockers |
| E | [Customer data](e-customer-data.md) | Notes redaction on anonymisation, retention jobs, remaining gaps |
| F | [Consented samples](f-consented-samples.md) | Collection template, consent text (en / ckb / ar), file format |
| G | [Validation report](g-validation-report.md) | What was verified, what was not, safety failures and fixes, Phase 9 readiness |

| Commit | Contents |
|---|---|
| `902c006` | Migration `20261019090000_ai_guard_hardening.sql`, pgTAP 16 (78 assertions) |
| `78b1a5a` | Migration `20261019100000_customer_notes_redaction.sql`, pgTAP 17 (42 assertions), pgTAP 13 updated |
| `ba7f84b` | `ai-assist`: inference region, per-language evaluation report, spending cap, consented-set input, staging preflight, tests |
| (this commit) | These documents and a correction to Phase 8 G |
