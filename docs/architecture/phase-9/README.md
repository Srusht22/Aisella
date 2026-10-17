# Aisellia — Phase 9: messaging integration (design)

**Status:** **Design proposal. Not approved. No implementation.**
- No channel account is connected.
- No webhook is configured.
- No message has been sent.
- Nothing is deployed and no provider charge was incurred.

Live integration work starts only after the owner reviews and explicitly approves this design.

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

**About the sources:**
- Platform facts were gathered by web search on **2026-10-17**.
- The official developer sites (developers.facebook.com, core.telegram.org, developers.viber.com) could not be opened directly from this environment (DNS failure), so some facts come from search summaries of those pages and some from third parties.
- Each fact in B is marked **official**, **third-party** or **unverified**. All of them must be re-checked against the official pages before implementation, and B §5 lists them.
