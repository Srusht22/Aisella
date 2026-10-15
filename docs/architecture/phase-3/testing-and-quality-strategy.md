# Testing and quality strategy

**Phase 3** · Status: **Proposed — pending owner approval** · Related: [Phase 1 traceability §11](../../product/phase-1-product-specification.md#11-requirements-to-tests-traceability), [Phase 2 acceptance checklist](../../design/phase-2/08-design-acceptance-checklist.md), [negative tests](authorization-and-tenancy.md#9-negative-authorization-tests-architectural-requirements)

## 1. Layers
| Layer | Tooling | Runs | Owner of truth |
|---|---|---|---|
| Flutter unit | `flutter_test`, `mocktail` | Every push | Formatting, domain, mapping, notifiers, mutation lifecycle |
| Flutter widget and golden | `flutter_test` goldens, bundled fonts | Every push | Screens and components × states × `en`/`ckb` × light/dark × text scale |
| Database and backend | Supabase CLI local stack (Docker) + **pgTAP** | Every push (CI) | RLS, privileges, functions, constraints, transactions, migrations |
| Edge Functions | Deno test with a stubbed `AiProvider` and channel adapters | Every push | Validation pipeline, PII minimiser, renderer, webhook verification |
| Integration (app ↔ local backend) | `integration_test` on an Android emulator in CI | Pull requests to the default branch and nightly | Journeys (§6) |
| AI evaluation | Scripted evaluation set against the real model (costs money) | On demand; required before model, effort or prompt changes, and before the pilot | Quality gates |
| Manual device | Test scripts on real Android and iOS phones | Before each pilot release | RTL, performance, screen readers, real networks |

## 2. Flutter tests
- **Unit:**
  - digit normalisation (Western, Eastern Arabic and Persian digits);
  - IQD/USD formatting;
  - phone normalisation (Iraqi variants);
  - date localisation;
  - DTO mapping, including unknown enums;
  - `AppFailure` mapping for every server code;
  - `MutationController`: key reuse across retries, `unknownOutcome` → re-read, invalidation.
- **Widget and golden:** every P0 screen in loading, empty, error, data and offline states. Draft review with every provenance state. Approve sheet. RTL mirroring. 200% text scale.
- **Navigation:** redirect guard (no session, no store, setup step), deep links to own and foreign IDs (the latter show GL-04), per-tab stack preservation, unsaved-changes guard.
- **Localization:** no missing ARB keys (CI), pseudo-locale run, `ckb` delegate presence.
- **Validation and error presentation:** field errors, banners, P-ERR-UNKNOWN flow.

## 3. Backend and database tests (pgTAP + SQL)
| Area | Cases |
|---|---|
| Authentication | Anonymous denied; expired or forged JWT denied (NT-04, NT-15) |
| Tenant isolation and authorization | NT-01…NT-12, generated per table and function from the catalog |
| Business rules | Every Phase 1 BR in §6.2–6.7 has a test (product limits, SKU uniqueness, transitions table, BR-30 matrix exhaustively: every from × to pair) |
| Constraints | Negative stock, quantity range, discount ≤ subtotal, one owner, order-number uniqueness |
| Transactions and rollback | A failure mid-approval leaves no partial movements (force an error after the first line) |
| Approval | Prototype cases T4–T14 as permanent tests, plus `INCOMPLETE_ORDER`, `LINE_UNAVAILABLE`, `EMAIL_NOT_VERIFIED`, `CURRENCY_LOCKED` set on first approval |
| Inventory consistency | Property-style: random sequences of approve, edit, cancel, return and adjust; afterwards balance = Σ movements, never negative, and per-order net movement = expected |
| Duplicate requests | Same key replays; same key with a different payload returns `IDEMPOTENCY_KEY_REUSED`; concurrent duplicates (parallel sessions) |
| Data migration | Migrations apply from empty; upgrade from the previous release snapshot with seeded data; down-path not required (forward-fix policy); RLS still enabled on every table after migration (catalog check) |
| Reporting | Summary figures equal sums over the filtered lists; test orders excluded |
| Jobs | Reconciliation detects an injected mismatch; purge jobs respect retention; deletion job order |

## 4. AI tests
| Area | Method |
|---|---|
| **Deterministic** (no model call; Deno tests with recorded or fabricated model outputs) | Malformed JSON; wrong types; unknown variant IDs; prices in literal text (guard); `stop_reason` refusal or `max_tokens`; phone tokenisation round trip; seller-edited fields protected; one open draft per conversation; repeated requests with the same key; timeouts and 429 handling (stubbed provider) |
| **Evaluation set** (real model; M0 data, consented and anonymised, 50–100 conversations) | Product and variant matching precision and recall; missing-field detection; ambiguous variants become candidates; unsupported business claims (fabrication = 0); escalation recall on unsafe cases; prompt-injection attempts; mixed Sorani, Arabic, English and Latin-script Kurdish; reply-language correctness |
| Gates | Phase 1 §14.3: fabrication = 0, auto-confirmation = 0, escalation recall ≥ 95%, product-match precision ≥ 85%; recorded per prompt version, model and effort |

## 5. Messaging tests (P1)
- Signatures: valid, invalid, missing, body tampering, replay of an old event.
- Duplicate events, and the same message in two events.
- Out-of-order events.
- Rate-limit (429) handling.
- Failed sends (permanent and retriable).
- Unknown outcome: no automatic resend, reconciliation via echo.
- Revoked tokens, a disconnected channel, an expired reply window.

Use provider sandboxes or test accounts only. Never use real customers' chats.

## 6. End-to-end journeys (integration, local backend)
1. **Onboarding:** sign up → verify email (stubbed) → create store → zones → product with variants → stock history shows initial stock.
2. **Inquiry to draft:** import messages → `ai-assist` (stubbed provider in CI; real model in a manual run) → suggestion "not sent" → create draft → provenance shown.
3. **Review and approval:** fix flagged fields → approve → stock decremented once → confirmation text available → replay after a simulated lost response shows a single approval.
4. **Inventory changes:** edit approved order (+1) → stock checked → cancel → stock restored → history correct.
5. **Fulfilment:** preparing → out for delivery → delivered with partial COD → outstanding COD on Today.
6. **Failure and recovery:** offline during approval (P-ERR-UNKNOWN), price changed at approval, insufficient stock at approval, session expiry mid-edit, AI timeout and manual fallback.

## 7. Environments and test data
- **CI:** an ephemeral Supabase local stack per job (Docker), seeded with **synthetic** fixtures (`seed/` with sample stores, Sorani and English products, conversations). Never production data.
- **AI calls in CI:** the stubbed provider by default. A real-model evaluation job needs a manual trigger and a separate, rate-limited API key in CI secrets.
- **Staging:** synthetic data plus owner-created test stores. Test orders flagged.
- **Secrets in CI:** GitHub Actions encrypted secrets, scoped to the environment. Forks do not receive secrets.

## 8. CI pipeline (proposal)
1. Format and analyze: `dart format --set-exit-if-changed`, `flutter analyze`, import-boundary check, ARB completeness, token-codegen freshness.
2. Unit, widget and golden tests.
3. Backend: `supabase start` → apply migrations → pgTAP suite (including generated negative tests) → Edge Function Deno tests.
4. Secret scan and dependency audit.
5. Build Android debug APK (Linux runner). iOS build on macOS runner nightly or for release candidates.
6. Integration tests on an emulator (pull requests and nightly).
7. Contrast check (`docs/design/phase-2/tools/contrast_check.py`) when the token file changes.

## 9. Release gates
| Gate | Required |
|---|---|
| Any merge | Steps 1–4 green |
| Staging deploy | Plus integration tests; migrations rehearsed on a staging copy |
| Pilot release | Plus: AI evaluation gates met; NT suite green; restore rehearsal done; Phase 2 design checklist passed on all P0 screens; manual device scripts on at least one mid-range Android and one iPhone, in both `en` and `ckb`; known-issues list reviewed; pre-pilot security gate ([threat model](security-threat-model.md#pre-pilot-security-gate-summary)) |
