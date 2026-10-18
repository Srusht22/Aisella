# Project status (read this first)

**Updated:** 2026-10-18, on `S.H_Branch`. Phase numbers are the [roadmap's](../architecture/phase-3/implementation-roadmap.md) and the [Phase 1 product specification's](../product/phase-1-product-specification.md). They have not been renumbered.

## Standing rules (owner)

Each of these needs the owner's separate, explicit approval:
- deployment;
- hosted database migrations;
- real customer messages;
- external account connections or paid services;
- enabling live AI replies or automated outbound messaging.

In addition:
- **No real Gemini API call, and no request for a key, until the final pre-publication verification** ([checklist](pre-publication-checklist.md), item A).
- No production credentials or secrets in Git.

## Phases

| Roadmap phase | Milestone | Status | Report |
|---|---|---|---|
| 1–3 | Product, design, architecture | Done (docs) | `docs/product`, `docs/design`, `docs/architecture/phase-3` |
| 4 | R1 Foundation | Done | [phase-4](phase-4/README.md) |
| 5 | R2 Auth and store setup | Done | [phase-5](phase-5/README.md) |
| 6 | R3 Catalog and inventory | Done | [phase-6](phase-6/README.md) |
| 7 | R4 Orders and invariants | Done | [phase-7](phase-7/README.md) |
| 8, 8.5 | R5 Conversations and AI, then hardening | Done locally. Real-model gates open, see "Deferred" below | [phase-8](phase-8/README.md), [phase-8.5](phase-8.5/README.md) |
| 9 | R7 Live channels (six providers) | Implemented and tested **locally only**. No provider can send (capabilities not verified); nothing deployed or connected | [phase-9 report](phase-9/integrations-report.md) |
| (9 follow-up) | Gemini verification, requested under the name "Phase 10" | **Offline work complete; real-model evaluation deferred and incomplete** | [phase-10/gemini-readiness.md](phase-10/gemini-readiness.md) |
| **10** | **R8 Fulfilment extensions** (courier records, delivery lists, payment recording, courier settlement) | **In progress (the next phase after Phase 9)** | [phase-10/fulfilment-extensions.md](phase-10/fulfilment-extensions.md) |
| 11 | R9 Reporting | Not started | — |
| 11-lite / 12-lite | R6 Pilot readiness (Sentry, backups, signing, store builds, legal texts) | Not started: needs external accounts and owner approval | — |
| 12 | R10 Full QA and release | Not started | [pre-publication checklist](pre-publication-checklist.md) |

## Deferred and unverified (do not claim otherwise)

**Gemini, real model (deferred by the owner to pre-publication):**
- No real Gemini response has been tested.
- The 35-conversation real-model evaluation is outstanding.
- Actual model behaviour, observed API cost and real rate-limit handling are unverified.
- Native Sorani and Arabic review of real model outputs is outstanding.

**Phase 8.5 gates still open:**
- the Phase 1 §14.3 gates on 50–100 consented conversations;
- non-numeric fabricated promises;
- hosted staging.

**Messaging providers:**
- No capability is recorded as verified, and no platform approval exists.
- TikTok's formats are unresolved.

**Everything is local:**
- every migration after the initial setup is applied only to the local database;
- no hosted project has been changed.

**Translations:** the Sorani and Arabic strings are machine-drafted and await native review.

**What remains mocked** (tested only against local imitations): Gemini, all six messaging-provider APIs, Meta and TikTok OAuth.
