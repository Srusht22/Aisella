# Aisellia — Phase 9: messaging integration (design)

**Status:**
- The single-channel architecture was approved in principle with conditions (below). The docs milestone at `61833a3` was provisionally accepted, subject to direct verification.
- **Scope revised to a multi-channel public launch:** provider-neutral architecture [L](l-multichannel-architecture.md), platform matrix [M](m-platform-matrix.md), all-platform questionnaire [J](j-seller-interview-questionnaire.md), and milestones [N](n-milestones-public-launch.md). These are **proposals for review, not approved**.
- **No platform is selected. No milestone is authorized; MC-2 (formerly M9-1) remains proposed.**
- No channel account is connected.
- No webhook is configured.
- No message has been sent.
- Nothing is deployed and no provider charge was incurred.

## Owner conditions (approval in principle) and where each is met

| # | Condition | Where |
|---|---|---|
| 1 | Keep separate least-privilege receiver and sender roles, signature verification, store isolation, deduplication, retries, audit and seller-controlled sending | [C §1](c-integration-architecture.md#1-components), [D](d-security.md), [E](e-reliability.md), [F](f-seller-sending-workflow.md) |
| 2 | AI suggestions for live messages opt-in and off by default; the AI never sends or approves | [C §4](c-integration-architecture.md#4-inbound-flow) step 5, [D §4](d-security.md#4-prompt-injection-through-incoming-messages), [F §1](f-seller-sending-workflow.md#1-the-rule) |
| 3 | The exact seller-authorized text is what is submitted; never auto-resend an unknown outcome | [F §4](f-seller-sending-workflow.md#4-server-checks-in-apisend_message) (exact-text guarantee, `TEXT_INTEGRITY`), [E §4](e-reliability.md#4-unknown-outcomes-and-reconciliation) |
| 4 | Order confirmations only for approved orders, only with explicit seller authorization | [F §1](f-seller-sending-workflow.md#1-the-rule), [F §4](f-seller-sending-workflow.md#4-server-checks-in-apisend_message) |
| 5 | Human Agent tag deferred to Phase 9b | [F §5](f-seller-sending-workflow.md#5-reply-windows) |
| 6 | No live accounts, production webhooks, deployment, customer contact or provider charges | This page; [G §1](g-test-plan-and-staging.md#1-rules-for-phase-9-testing); [K](k-staging-setup-checklist.md) |
| 7 | Re-check platform facts on official sources; label what is unverified | [I](i-official-verification.md) |
| 8 | Seller-interview questionnaire; do not choose by score alone | [J](j-seller-interview-questionnaire.md), [B](b-channel-comparison.md) (revised) |
| 9 | Staging checklist with minimum credentials and test accounts, no secret values | [K](k-staging-setup-checklist.md) |
| 10 | Phase 8.5 real-model evaluation stays a separate open gate; no model-quality claim | [Phase 8.5 H](../../implementation/phase-8.5/h-validation-gates-and-review.md), [H §3](h-specification-risks-next-steps.md#3-risks) |

**Authorized scope:** Phase 9 planning and design, in parallel with completing Phase 8.5 validation ([Phase 8.5 H](../../implementation/phase-8.5/h-validation-gates-and-review.md)).

**Baselines:**
- [Phase 1 product spec](../../product/phase-1-product-specification.md): BR-04, BR-06, BR-47, BR-50, D-01, D-02, D-06, the permission matrix (§5.2);
- [Phase 3 messaging architecture](../phase-3/messaging-integration-architecture.md) and [ADR-012](../phase-3/architecture-decision-records/ADR-012-messaging-adapter.md);
- what Phases 5–8.5 actually built.

Where this design differs from Phase 3, the difference is stated and the stronger boundary is kept.

**Non-negotiable rules carried forward:**
1. **The AI never sends, never approves.** It may propose replies and prepare unapproved order drafts (BR-47, permission matrix).
2. **No customer message leaves Aisellia without a seller's explicit authorization of that exact text** (D-06; [F](f-seller-sending-workflow.md)).
3. **Customer messages are untrusted data** (BR-06), including names, profile fields and attachments.
4. **Tenant isolation is enforced in the database,** not by URL paths or client code.
5. **Secrets stay server-side.** Provider tokens and app secrets never reach Flutter, logs or the repository.

| # | Document | Contents |
|---|---|---|
| A | [Current architecture and gaps](a-current-architecture.md) | What exists today and what live channels need |
| B | [Channel comparison and recommendation](b-channel-comparison.md) | WhatsApp, Instagram, Messenger, Telegram, Viber: requirements, cost, approval, sandbox |
| C | [Integration architecture](c-integration-architecture.md) | Components, data model, inbound and outbound flows, roles, the adapter contract |
| D | [Security design](d-security.md) | Webhook verification, tenant isolation, secrets, prompt injection, threat table |
| E | [Reliability design](e-reliability.md) | Deduplication, retries, rate limits, unknown outcomes, failure recovery, audit logging |
| F | [Seller sending workflow](f-seller-sending-workflow.md) | Authorization model, states, UI, the AI boundary, order confirmations |
| G | [Test plan and staging needs](g-test-plan-and-staging.md) | Fixtures, sandbox-only tests, minimum staging infrastructure and credentials |
| H | [Specification, risks and next steps](h-specification-risks-next-steps.md) | Phase 9 user stories, acceptance criteria, risks, decisions needed, plan |
| I | [Official-source verification](i-official-verification.md) | Each platform fact against official pages, with its status (confirmed, partly, unverified, changed) |
| J | [Seller-interview questionnaire](j-seller-interview-questionnaire.md) | Revision 2: all target platforms plus other; results and aggregation sheets; why broader validation is needed |
| K | [Staging setup checklist](k-staging-setup-checklist.md) | Accounts, credential names (no values), steps, constraints |
| L | [Multi-channel architecture](l-multichannel-architecture.md) | Provider-neutral core, adapters, capability registry, credentials, queues, isolation, quotas, monitoring, public multi-tenant changes |
| M | [Platform matrix](m-platform-matrix.md) | Instagram, WhatsApp, Messenger, Telegram, Viber, TikTok, others: every claim labelled VERIFIED / ASSUMPTION / UNRESOLVED with sources |
| N | [Milestones to public launch](n-milestones-public-launch.md) | MC-0 to MC-6 with acceptance criteria and dependencies (proposed only) |

**About the sources:**
- Platform facts were gathered by web search on **2026-10-17**.
- The official developer sites are blocked by this environment's network policy. [I](i-official-verification.md) re-checked every key fact with searches restricted to official domains and labels each one. Nothing there was read directly, so a direct read is still required before implementation.
- Each fact in B is marked **official**, **third-party** or **unverified**. All of them must be re-checked against the official pages before implementation, and B §5 lists them.
