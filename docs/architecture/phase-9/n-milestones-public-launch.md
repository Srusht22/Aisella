# N. Milestones to public launch (proposed)

**Status:** **proposal only.** No milestone below is approved or authorized. Each one starts only on the owner's explicit approval. Implementation milestones (MC-2 onward) also need the owner's channel decision.

**Relation to the earlier plan:** the M9-1…M9-6 plan in [H §2](h-specification-risks-next-steps.md#2-proposed-implementation-milestones-after-approval) maps into MC-2 to MC-4 below. **M9-1 remains proposed and unauthorized.** It becomes the provider-neutral MC-2.

| # | Milestone | Kind | Depends on |
|---|---|---|---|
| MC-0 | Multi-channel architecture and provider research | Docs and research | — |
| MC-1 | Seller interviews and channel selection | Research and owner decision | MC-0 |
| MC-2 | Local-only foundation and restricted database roles | Code, local only | MC-1 decision, owner authorization |
| MC-3 | First provider integration (local, fixtures) | Code, local only | MC-2, the provider's approvals started |
| MC-4 | Staging validation and limited pilot | Deployment to staging; pilot with consenting sellers | MC-3, staging authorization, Phase 8.5 gates |
| MC-5 | Additional provider integrations (one at a time) | Code, then staging, then pilot | MC-4 for the first provider; MC-0 / MC-1 evidence per provider |
| MC-6 | Public-launch readiness and operational scaling | Ops, legal, scale | MC-4 and the providers chosen for launch |

## MC-0. Multi-channel architecture and provider research

**Deliverables:** [L](l-multichannel-architecture.md) (architecture), [M](m-platform-matrix.md) (matrix), and this plan.

**Acceptance criteria:**
1. The architecture separates the common core from adapters and defines the capability registry, with UNRESOLVED treated as absent.
2. Every matrix claim is labelled VERIFIED, ASSUMPTION or UNRESOLVED, with source links and the check date.
3. **Every VERIFIED claim for the providers short-listed in MC-1 has been read directly on the official page**, with the date recorded. That needs network access to the official domains, or a person doing it.
4. The owner reviews the documents.

**Status:** documents written; criterion 3 open (direct read blocked here); owner review pending.

## MC-1. Seller interviews and channel selection

**Acceptance criteria:**
1. At least **5 discovery interviews** using [J](j-seller-interview-questionnaire.md), with results and aggregation sheets completed and no customer data.
2. A short-list of 1–3 providers, with the UNRESOLVED items that block each one listed:
   - eligibility of Aisellia's legal entity for Business Verification, Tech Provider status, and TikTok reviews;
   - Iraq rates;
   - coexistence.
3. **The owner selects the first provider**, recorded as a dated decision.
4. Plan for the broader validation (≥ 30 sellers) before MC-6.

**Dependencies:**
- the owner recruits sellers;
- native interviewers;
- the legal entity decision.

## MC-2. Local-only foundation and restricted database roles

This is the provider-neutral M9-1.

**Scope:**
- migrations for `providers`, `provider_capabilities`, `connections`, `contacts`, `message_attachments`, `send_requests`, `delivery_events`, `webhook_events`, and the extensions to `conversations` and `messages`;
- ingest and sender login roles;
- `api.send_message` with the exact-text hash;
- the processor with fair per-connection batching;
- the shared adapter interface and conformance kit, with a **fixture-only stub provider**;
- **no real provider adapter, no network, no deployment.**

**Acceptance criteria:**
1. pgTAP covers:
   - guard tests: both roles have no attributes, no tables and exact function lists; **no AI role can execute a send function**;
   - cross-store isolation and forged routing;
   - two-level deduplication;
   - backoff, failed state and replay;
   - the send rules (window, permission, blocked contact, approved-order-only confirmations, rate limits, idempotency);
   - an audit row for every authorized send;
   - `unknown` never re-claimed;
   - the capability rule (UNRESOLVED treated as absent);
   - retention purges.
2. Deno: conformance kit green against the stub provider; the stub receives **byte-identical** text (en / ckb / ar); timeout → `unknown`; no secrets in logs.
3. All existing suites stay green: pgTAP, Deno, and Flutter.
4. No change to production configuration; nothing deployed.

**Dependencies:**
- the owner's MC-1 decision;
- **explicit authorization of MC-2**.

## MC-3. First provider integration (local)

**Scope:**
- the chosen provider's adapter (verify, route, parse, send, status if available, connect, refresh, disconnect);
- its capability manifest with evidence;
- app screens: connect, inbox labels, composer with "Use this reply", window indicator, send states, health;
- ckb / ar / en strings.

**Acceptance criteria:**
1. Conformance kit plus provider fixtures green: signature, Unicode raw body, retries and duplicates, out-of-order status, provider error codes.
2. Capability-driven UI: no feature shown that the manifest lacks.
3. App tests including RTL and 200% text; native review of the new strings is scheduled.
4. The provider's platform approval process (App Review, Tech Provider, contract or review) has started, owned by the owner.

**Dependencies:**
- MC-2;
- verified (directly read) requirements for that provider.

## MC-4. Staging validation and limited pilot

**Acceptance criteria:**
1. The owner has **authorized the staging deployment**. The staging project and the secrets are set by the owner as in [K](k-staging-setup-checklist.md).
2. The extended preflight passes, with no secret values in its output.
3. A round trip with **team-owned test accounts only** passes all [G §3](g-test-plan-and-staging.md#3-staging-integration-test-later-needs-approval) exit criteria.
4. **Phase 8.5 gates closed before any pilot seller uses AI suggestions on a live channel:**
   - G1 real-model evaluation reported per language;
   - G2 native review passed;
   - G3 the fabricated-promise risk accepted, or mitigated by an evaluated second-pass check.

   Without them, the pilot runs with AI suggestions **off**.
5. The provider approval is granted for real (non-role) accounts.
6. Limited pilot: 3–5 consenting sellers, written pilot terms, a monitoring dashboard, an on-call owner, and a rollback (provider `suspended` switch). It ends with a written report.

**Dependencies:**
- MC-3;
- the owner's authorizations;
- provider approval;
- Phase 8.5 gates for AI use.

## MC-5. Additional providers (repeat per provider)

**Acceptance criteria (per provider):**
1. The [L §12](l-multichannel-architecture.md#12-adding-a-provider-the-checklist) checklist is completed.
2. **No core schema change**, or a reviewed exception.
3. The same conformance kit, isolation tests and staging criteria as MC-3 and MC-4.
4. The cost model is approved by the owner (for example Viber per-bot fees, WhatsApp per-message charges).
5. The legal and terms review is done (for example the WhatsApp AI clause).

**Dependencies:**
- the MC-1 evidence for that provider;
- its approvals and contracts;
- owner authorization for each provider.

## MC-6. Public-launch readiness and operational scaling

**Acceptance criteria:**
1. **Broader seller validation** (≥ 30 sellers, proposed) supports the launch providers and the pricing.
2. Every item in [L §13](l-multichannel-architecture.md#13-what-public-multi-tenant-operation-adds-beyond-the-pilot-design) is covered:
   - self-serve onboarding;
   - provider approvals for every launch provider;
   - billing and plans with pass-through of provider costs;
   - fair queuing;
   - dashboards, alerts, runbooks and on-call;
   - a support-access procedure;
   - abuse controls;
   - terms, privacy policy and data-processing terms;
   - a security review and penetration test;
   - load tests at the agreed multiple of pilot volume;
   - the region and data-residency decision.
3. Production project separate from staging, backups and restore rehearsal (AD-05), a secret-rotation runbook.
4. All Phase 8.5 gates closed **for every language offered**, or AI suggestions launched disabled.
5. The owner's launch decision, recorded.

**Dependencies:** MC-4 / MC-5 for the launch providers; legal; budget.

## Architecture changes required for public multi-tenant operation

These are summarized from [L §13](l-multichannel-architecture.md#13-what-public-multi-tenant-operation-adds-beyond-the-pilot-design):
- a provider registry and capabilities instead of a hard-coded channel list;
- per-provider webhook functions;
- fair per-connection queue claiming;
- a provider suspension switch;
- plan and quota tables, billing integration, and provider-cost pass-through;
- self-serve connect flows and seller-facing health and troubleshooting;
- operational dashboards and alerts, on-call, a status page;
- a support-access procedure, abuse handling, legal documents;
- capacity testing and Supabase plan sizing.

## Open risks carried across all milestones

- **Phase 8.5 (open):**
  - real-model quality untested;
  - no native Sorani and Arabic review;
  - no consented conversations;
  - **non-numeric fabricated promises not solved.**
- Provider approvals for the owner's legal entity (UNRESOLVED for every provider that requires one).
- Direct verification of official requirements is still pending (network block).
- Iraq regulatory volatility (Telegram suspension in 2026, per news).
