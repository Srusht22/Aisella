# H. Phase 9 specification, risks and next steps

## 1. User stories (Phase 9)

Numbered P9-xx to avoid colliding with Phase 1's US-0xx.

**P9-01 — Connect a channel (owner).** As an owner, I connect my Instagram professional account so customer DMs appear in Aisellia.
- Only the owner (`channels.manage`) sees "Connect".
- The connection shows "Connecting" until a real event has round-tripped, then "Connected".
- An account already connected to another store is refused without revealing which store.
- Connect and disconnect are audited.
- No token ever reaches the app.

**P9-02 — Receive messages.** As a seller, new DMs appear in the inbox within about 10 s of arrival, in the right conversation, once each.
- Duplicates and replays create nothing.
- Attachments show as placeholders.
- The conversation is labelled with the channel and a health dot.
- Sandbox and imported conversations are unchanged.

**P9-03 — AI suggestions on live messages (opt-in).** As an owner, I can turn on "Prepare suggestions for new messages".
- Off by default.
- Debounced; within the Phase 8.5 cost brakes and per-contact caps.
- Manipulation escalates to "Needs you".
- The AI never sends.

**P9-04 — Send a reply (explicit authorization).** As a seller, I send text I can see.
- A suggestion must first be moved into the composer with "Use this reply".
- The send is refused when the window is closed, the contact is blocked or the connection is unhealthy.
- The exact authorized text is what is sent.
- Every send has an audit row naming me.
- A double tap sends once.

**P9-05 — See sending outcomes.** I see Sending, Sent, Delivered or Read where supported, Not sent with a reason, or Status unknown.
- Unknown is never resent automatically.
- "Send again" asks for confirmation and creates a new authorization.

**P9-06 — Send an order confirmation.** After I approve an order, I can send the server-generated confirmation in that conversation.
- Not available before approval.
- Not editable into a different order state.

**P9-07 — Reply window awareness.** The composer shows when the window closes, and disables Send after it closes with an explanation and the alternatives (Copy, the platform's app).

**P9-08 — Connection health and recovery.** The owner sees:
- last event received;
- last send;
- failures;
- token expiry;
- a "Needs attention" state with a fix path (reconnect).

Sends pause while a connection needs attention.

**P9-09 — Disconnect.** The owner disconnects. The token is revoked or deleted, the webhook is removed where applicable, conversations stay, and sending is disabled.

**P9-10 — Delete a channel customer.** "Delete this customer" covers channel contacts, including those without a phone number, and their webhook payloads.

**P9-11 — Block a contact.** The seller blocks an abusive contact. Their messages are stored, but they get no AI runs and cannot be sent to.

**System stories:**
- **P9-S1:** webhook authenticity on raw bytes.
- **P9-S2:** tenant isolation by verified account id.
- **P9-S3:** deduplication at event and message level.
- **P9-S4:** retries with backoff, a failed state and replay.
- **P9-S5:** rate limits.
- **P9-S6:** audit evidence that every provider message id maps to a human authorization.
- **P9-S7:** a 14-day payload purge.
- **P9-S8:** no secrets in logs.

## 2. Proposed implementation milestones (after approval)

| # | Milestone | Contents | Gate |
|---|---|---|---|
| M9-1 | Data model and roles | Migrations for connections, webhook events, contacts, send requests and the message extensions; ingest and sender roles; pgTAP for isolation, deduplication, send rules and guards | Local only |
| M9-2 | Generic pipeline | `channel-webhook` and `channel-send` with the adapter interface; Telegram adapter **as a local fixture harness**; provider stubs; local end-to-end test | Local only |
| M9-3 | Instagram adapter (or WhatsApp, per D-02) | Verification, parsing, send, OAuth, capabilities; fixture tests | Local only |
| M9-4 | App | Connect screen, live inbox labels, composer with "Use this reply", window indicator, send states, health, block, delete customer; localization; tests | Local only |
| M9-5 | Staging integration test | G §3 with team-owned test accounts | **Owner authorizes staging deployment and provides credentials** |
| M9-6 | Platform review preparation | Screencast, privacy texts, data-deletion callback | Owner decides to submit |

Real sellers connect only after M9-5, the platform's approval, and the Phase 8.5 gates G1–G3.

## 3. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Non-numeric fabricated promises reach customers faster with a Send button** | Medium | High | Two-step "Use this reply" → Send; AI-origin label; order-text confirmation step; Phase 8.5 G1–G3 before pilot use; candidate second-pass classifier. **Not solved.** |
| Meta app review or business verification rejected or slow, including for the legal entity's country | Medium | High (blocks real sellers) | Design and test in dev mode first; prepare review material early; the owner decides the legal entity; keep manual import as a fallback |
| WhatsApp reply costs: **confirmed charged since 2026-10-01** beyond 1,000 per number per month; Iraq amounts unknown (I W1–W2) | High (now certain to apply) | Medium | Decide who pays; retrieve the Iraq rate card; a `payment_required` connection state; no templates in Phase 9 |
| WhatsApp coexistence probably unavailable for Iraqi numbers (I W7), so sellers may need a separate business number | Medium | High for WhatsApp adoption | Interview question J-7; confirm with Meta before choosing WhatsApp |
| WhatsApp Business Solution Terms: the AI-provider clause, the human-escalation requirement, and the ban on using data to train models (I W15) | Low–medium | High | Humans send every message, with escalation to the seller built in; Anthropic API data is not used for training; **legal review before choosing WhatsApp** |
| Webhook delivery gaps (platform outage, our downtime) | Medium | Medium | Platform retries plus our idempotent ingestion; health alerts; replay; the seller can always use the native app |
| Duplicate or lost sends on timeouts | Medium | Medium | `unknown` state, reconciliation, no automatic resend |
| Cross-store attribution bug | Low | Very high | Account-id resolution, a unique active account, composite foreign keys, dedicated isolation tests |
| Inbound flooding raises AI cost | Medium | Medium | AI opt-in, debounce, per-contact caps, cost brakes |
| Token leakage | Low | High | Vault, a single definer function, log tests, no tokens in the client |
| Platform facts wrong or outdated: official sites blocked here, checked via an official-domain search index (I) | Medium | Medium | A direct read of every source in I, dated, before any implementation milestone; unverified items stay labelled |
| **Model quality unvalidated:** the Phase 8.5 real-model evaluation and native review have not run | Certain until done | High | Separate open gate (Phase 8.5 H, G1–G2). No claim of model quality, and no pilot use of live sending, until it closes. |
| Sorani and Arabic UI and AI quality | Medium | High | Native review (Phase 8.5 H §3) covers the new strings too |

## 4. Decisions

**Taken by the owner** (approval in principle):
- The architecture, under the 10 conditions in the [README](README.md).
- AI suggestions for live messages are opt-in and off by default.
- The Human Agent tag is deferred to Phase 9b.

**Outstanding:**
1. **First channel (D-02).** Run the seller interviews ([J](j-seller-interview-questionnaire.md)), then decide with the owner. Instagram is the provisional lead; WhatsApp depends on the number model, cost and coexistence.
2. **First implementation milestone.** Proposed: M9-1, data model and roles, local only, after D-02. Needs explicit approval.
3. **The legal entity and Meta business portfolio** that will own the Meta app, and its eligibility for Business Verification (I I12, unverified).
4. **Who pays WhatsApp message charges** (seller or Aisellia), if WhatsApp is chosen.
5. **Legal review** of the WhatsApp Business Solution Terms AI clauses (I W15) and of platform data-retention terms, before WhatsApp is chosen.
6. **Staging:** create the project (AD-09) and the K §1 assets; later, authorize deployment and enter the K §2 credentials yourself.
7. **Network access** for this environment to the official documentation domains, if you want direct verification done here; otherwise someone reads the sources in I directly.
8. **Phase 8.5 gates:** a dedicated Anthropic staging key (G1), native reviewers (G2), and acceptance of the non-numeric fabrication risk or a decision to add a second-pass check (G3).

## 5. What was done in this design step

- No code, migration, connection, webhook, message, deployment or provider charge.
- Documents A–H in `docs/architecture/phase-9/`, revised after the owner's review; I (official verification), J (interview questionnaire) and K (staging checklist) added.
- Phase 8.5 open gates and protocols in `docs/implementation/phase-8.5/h-validation-gates-and-review.md`.
