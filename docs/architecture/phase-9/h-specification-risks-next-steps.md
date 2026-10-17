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
| WhatsApp costs higher than expected (service-message charging from 2026-10-01 is unverified; Iraq rates unknown) | Medium | Medium | Instagram first; verify the rate card before choosing WhatsApp; no templates in Phase 9 |
| WhatsApp policy on AI chatbots interpreted against an assistant product | Low–medium | High | Aisellia is a business-specific assistant; humans send every message; review the terms with Meta's current text |
| Webhook delivery gaps (platform outage, our downtime) | Medium | Medium | Platform retries plus our idempotent ingestion; health alerts; replay; the seller can always use the native app |
| Duplicate or lost sends on timeouts | Medium | Medium | `unknown` state, reconciliation, no automatic resend |
| Cross-store attribution bug | Low | Very high | Account-id resolution, a unique active account, composite foreign keys, dedicated isolation tests |
| Inbound flooding raises AI cost | Medium | Medium | AI opt-in, debounce, per-contact caps, cost brakes |
| Token leakage | Low | High | Vault, a single definer function, log tests, no tokens in the client |
| Platform facts in B are wrong or outdated (gathered via search; official sites unreachable here) | Medium | Medium | The B §5 verification list must be completed before M9-3 |
| Sorani and Arabic UI and AI quality | Medium | High | Native review (Phase 8.5 H §3) covers the new strings too |

## 4. Decisions needed from the owner

1. **D-02:** the first channel. The recommendation is Instagram, subject to the M0 interviews. B §4.
2. **Approve this design**, or request changes, before any implementation.
3. **The legal entity and Meta business portfolio** that will own the Meta app.
4. **Staging:** create the staging project (AD-09), then later authorize deployment and provide the G §3 credentials.
5. **AI auto-suggestion for live messages:** keep it opt-in and off by default, as proposed.
6. **Human Agent tag:** defer to Phase 9b, as proposed, or include it.

## 5. What was done in this design step

- No code, migration, connection, webhook, message, deployment or provider charge.
- Documents A–H in `docs/architecture/phase-9/`.
- Phase 8.5 open gates and protocols in `docs/implementation/phase-8.5/h-validation-gates-and-review.md`.
