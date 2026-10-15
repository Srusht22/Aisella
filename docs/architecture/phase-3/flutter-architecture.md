# Flutter application architecture

**Phase 3** · Status: **Proposed — pending owner approval** · Decisions: [ADR-006](architecture-decision-records/ADR-006-flutter-state-and-routing.md), [ADR-013](architecture-decision-records/ADR-013-client-session-storage.md) · Design inputs: [Phase 2 handoff](../../design/phase-2/09-implementation-handoff.md)

Target toolchain: Flutter **3.47.x stable / Dart 3.13** (latest stable on 2026-10-15), pinned in Phase 4. Package versions in [technology-decisions.md §3](technology-decisions.md#3-flutter-stack).

## 1. Principles
1. **The client is a view of server truth.** Client-side validation exists for UX; the server re-validates everything.
2. **Feature-first structure with explicit layers.** Widgets never talk to Supabase.
3. **One way to do each thing:** one state pattern, one mutation pattern, one error type, one router.
4. **Design tokens are generated, never hand-copied** (Phase 2 §9).

## 2. Project structure
```
lib/
  main.dart                     # reads AppConfig (dart-define), bootstraps
  app/                          # App widget, router, shell (bottom bar / rail), global banners
  core/
    config/                     # AppConfig (env name, Supabase URL, anon key, Sentry DSN)
    backend/                    # Supabase client provider, RPC helper, error-envelope decoding
    errors/                     # AppFailure (sealed), mapping from server codes
    mutation/                   # MutationController, idempotency-key lifecycle
    session/                    # auth state, secure LocalStorage adapter
    connectivity/               # offline detection
    formatting/                 # money, digits (Western/Eastern), phone normalisation, dates
    logging/                    # Sentry wrapper with PII scrubbing
  design_system/
    tokens/                     # tokens.g.dart, generated from docs/design/phase-2/tokens
    theme/                      # ThemeData + ThemeExtensions (light/dark, en/ckb type)
    components/                 # CMP-* widgets (Phase 2 §05)
    patterns/                   # P-LOAD-*, P-EMPTY*, P-ERR-*, P-OFFLINE wrappers
    motion/                     # durations, curves, ink-settle, number roll, reduced-motion
    gallery/                    # debug-only component gallery (excluded from release)
  features/
    auth/  onboarding/  today/  inbox/  assistant/  orders/  products/  customers/  settings/
      domain/                   # entities, value objects, pure UX rules
      data/                     # repositories (interfaces + Supabase implementations), DTOs
      application/              # Riverpod notifiers (screen state, mutations)
      presentation/             # screens, feature widgets
  l10n/                         # app_en.arb, app_ckb.arb (+ app_ar.arb later)
test/  integration_test/  tool/ # tool/: token codegen, import-boundary check
```

**Feature boundaries:** a feature may import `core/`, `design_system/` and another feature's **domain** only. Cross-feature navigation goes through route names. A CI script (`tool/check_imports`) fails the build when `presentation/` imports `supabase_flutter` or `data/`, or when a feature imports another feature's `data/` or `presentation/`.

## 3. Responsibilities by layer

| Layer | Owns | Must not |
|---|---|---|
| **Widgets (presentation)** | Layout, tokens, components, local ephemeral UI state (text controllers, expansion), wiring to notifiers, showing failures through the standard patterns | Call repositories or Supabase; compute business values (totals, stock); decide authorization |
| **Application (Riverpod notifiers)** | Screen state (`AsyncValue`), orchestrating repository calls, the mutation lifecycle and idempotency keys, mapping failures, triggering refetch and invalidation, emitting one-off effects (navigation, snackbar) | Hold widgets or BuildContext; parse JSON |
| **Domain** | Immutable entities (freezed), value objects (`Money` as integer minor units equal to whole IQD/USD, `PhoneNumber`, `Quantity`, `OrderStatus` with UX transition hints), pure UX validation | Be treated as authoritative; the server decides |
| **Data (repositories)** | Supabase reads (select or views), RPC calls, Storage uploads, Edge Function invocations, DTO↔entity mapping, decoding the error envelope into `AppFailure` | Contain UI logic; swallow errors |
| **Remote services (server)** | Authorization, business rules, transactions, AI | — |

## 4. State management (Riverpod 3)
- **Read state:** `AsyncNotifierProvider` (`.family` by record ID) per screen or list. The UI renders `AsyncValue` with the shared patterns: loading uses P-LOAD-* (after 300 ms), error uses P-ERR-LOAD, data renders the screen.
- **Mutations:** a single `MutationController<T>` convention.
  - States: `idle → submitting → success(T) | failure(AppFailure) | unknownOutcome`.
  - It creates an **idempotency key when the user starts an intent** (for example, opening the approval sheet) and reuses it for every retry of that intent. The key is discarded on success or on dismissal.
  - On `TimeoutFailure` or `NetworkFailure` for **critical** operations (approve, cancel, return, stock adjust), the state becomes `unknownOutcome`. The UI shows "Checking…" (P-ERR-UNKNOWN), and the controller **re-reads the record** before showing any result. A retry replays the same key, so the server returns the stored outcome.
  - On success it invalidates the affected providers (the order, its list, Today counts, product stock).
- **Side effects** (navigation after success, snackbars) go through `ref.listen` in widgets. They are never triggered inside build methods.
- **Lifetime:** auto-dispose by default; keep-alive only for the session, config and current-store providers.
- **Writing style:** notifiers written by hand (no provider code generation) to reduce build complexity. `freezed` and `json_serializable` remain the only code generators.

## 5. Navigation (go_router 18)
- `StatefulShellRoute.indexedStack` with four branches: `/today`, `/inbox`, `/orders`, `/products`. Each branch keeps its own stack (Phase 2 IA §3.1). The shell renders a bottom bar or rail depending on window class.
- **Store menu and settings:** pushed onto the current branch (`/…/store/...`) or opened as a root-level route on tablets.
- **Full-screen modals** (editors, import) use the root navigator with fullscreen-dialog presentation. **Sheets and dialogs are not routes**; they are presented imperatively (they are not deep-link targets).
- **Redirect guard, evaluated on auth-state changes:**
  - no session → `/welcome` (keeping the requested location to continue after sign-in);
  - session without a store → the first incomplete `/setup/step-n`;
  - otherwise allow.
- **Deep links** `/orders/:id`, `/inbox/:id`, `/products/:id`, `/customers/:id` resolve inside their owning branch. A not-found result shows GL-04; an access-denied result (server `NOT_FOUND` is used for cross-tenant IDs, so there is no existence leak) also shows GL-04.
- **Back behaviour:** predictive back (Android) and the iOS edge swipe stay enabled. The unsaved-changes guard uses route `onExit` / `PopScope` only on dirty editors.

## 6. Dependency injection
Riverpod providers are the DI container:
- `appConfigProvider`
- `supabaseClientProvider`
- one provider per repository interface, `XRepository` (overridden with fakes in tests)
- `clockProvider`
- `connectivityProvider`
- `formattersProvider` (depends on locale and digit setting)

There is no service locator.

## 7. Data models and serialization
- **DTOs:** `freezed` with `json_serializable`; snake_case mapping to database columns. Unknown enum values map to an `unknown` case (forward compatibility) and are logged.
- **Entities:** separate from DTOs only where the shapes differ meaningfully (for example `Order` with typed provenance). Otherwise the DTO is the entity, to avoid needless duplication.
- **Money:** `int` in the store currency (no doubles anywhere).
- **Times:** stored as UTC; rendered in the device timezone with the store's locale formatting.
- **Concurrency:** every editable record carries `version`. Mutations send `expected_version`.

## 8. Error handling
`AppFailure` is a sealed type:

| Case | Server or source signal | UX |
|---|---|---|
| `NetworkFailure` / `OfflineFailure` | Socket or DNS error, connectivity off | GL-01 offline; P-ERR-ACTION with Retry |
| `TimeoutFailure` | Client timeout (reads 15 s, writes 30 s, AI 35 s) | Critical: P-ERR-UNKNOWN; otherwise Retry |
| `UnauthenticatedFailure` | 401 / refresh failed | GL-02 sign-in sheet, then return; editor state kept in memory |
| `ForbiddenFailure` | `FORBIDDEN` | GL-03 |
| `NotFoundFailure` | `NOT_FOUND` | GL-04 |
| `ValidationFailure(fieldErrors)` | `VALIDATION_FAILED` | Field errors (localized from message keys) |
| `ConflictFailure(currentVersion)` | `CONFLICT_VERSION` | Info banner "Updated elsewhere"; reload; re-apply the user's pending sheet input where safe |
| `BusinessRuleFailure(code, details)` | `INSUFFICIENT_STOCK`, `PRICE_CHANGED`, `INVALID_TRANSITION`, `EMAIL_NOT_VERIFIED`, `CURRENCY_LOCKED`, … | Screen-specific (Phase 2 §5.6) |
| `RateLimitedFailure(retryAfter)` | `RATE_LIMITED` | Banner with wait time |
| `ServiceUnavailableFailure(service)` | `AI_UNAVAILABLE`, 503 | GL-08 or Retry |
| `UnexpectedFailure(ref)` | Anything else | P-ERR-* with the reference code; reported to Sentry |

Raw exceptions are never shown. The error-envelope contract is in [api-and-service-contracts.md §2](api-and-service-contracts.md#2-common-conventions).

## 9. Session and client-side security
- `supabase_flutter` handles sign-in, refresh and auth state. The session is persisted with a **secure-storage `LocalStorage` adapter** (ADR-013) and wiped on sign-out (together with in-memory caches and image caches for that store).
- Only the **anon key** and Supabase URL are compiled in. They are public by design; data protection comes from RLS and function checks. No service-role, AI or channel secret exists in the app.
- Screenshots are not blocked (sellers share screens for support). The app-switcher snapshot is not obscured in P0 (revisit if pilot feedback warrants it).
- Debug logging is off in release builds; Sentry `beforeSend` strips request bodies, phone-like and email-like strings, and addresses.

## 10. Localization
- gen-l10n with ARB files `app_en.arb` and `app_ckb.arb`. Every key has a description. ICU plurals and selects.
- `Directionality` follows the locale. Only directional (start/end) geometry is used, and a lint check rejects physical left/right helpers.
- If Flutter lacks `ckb` Material, Cupertino or Widgets localizations (to verify in Phase 4), ship custom delegates ([Phase 2 07 §1](../../design/phase-2/07-localization-and-accessibility.md#1-localization-foundations)).
- `core/formatting` implements:
  - digit normalisation (Western, Eastern Arabic and Persian digits on input);
  - display in Western or Eastern digits (setting; phones and order numbers always Western, DD-07);
  - IQD/USD formatting;
  - localized dates.

  These are unit-tested exhaustively.
- Server error codes map to localized messages on the client. The server never sends user-facing sentences, except AI-generated customer-facing drafts, which are content rather than UI.

## 11. Design-system integration
- `tool/gen_tokens` turns `docs/design/phase-2/tokens/aisellia-tokens.json` into `tokens.g.dart`. CI fails if the generated file is stale.
- Theme: `ThemeData` for the standard roles plus `ThemeExtension`s (Pencil, Semantic, Provenance, Spacing, Radii, Motion, TypeScale per script).
- Components follow [Phase 2 §05](../../design/phase-2/05-components.md). Patterns are shared widgets. The motion package reads a single reduced-motion source (OS setting or app setting).
- A debug-only gallery route renders every component in every state, in both directions and both themes. It is the golden-test target.

## 12. Environment configuration
- **Flavors** (Android product flavors and iOS schemes), each with its own app identifier and display name:
  - `dev` → `app.aisellia.dev`, local Supabase
  - `staging` → `app.aisellia.staging`, staging project
  - `prod` → `app.aisellia`

  *Identifiers are provisional; final bundle IDs need the owner's domain (AD-10).*
- **Runtime config:** `--dart-define-from-file=config/<env>.json`, containing **public values only**: `ENV_NAME`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SENTRY_DSN`. Committed: `config/*.example.json`. Real files are git-ignored. CI writes them from its secret store.
- Non-production builds show a persistent environment ribbon ("STAGING") so test data is never confused with production.
- **Feature flags:** none in P0 except build-time `ENV_NAME` checks for the debug gallery. Remote flags are introduced only with a concrete need (for example live-channel rollout in P1).

## 13. Network failures, expired sessions, loading and conflicts (summary)
| Situation | Behaviour |
|---|---|
| Slow request | Skeleton or progress after 300 ms; "Still working…" at 10 s |
| Offline | Banner; reads show last-loaded data; writes disabled with reason; reads auto-retry on reconnect; writes never auto-retry |
| Expired session | Silent refresh; if that fails, GL-02, then return to the same route; retry the pending mutation with the **same** idempotency key |
| Conflict | `CONFLICT_VERSION`, then reload with a banner; approvals that hit `INVALID_TRANSITION` with current status `approved` are shown as already approved (no error tone) |
| Lost response on a critical write | `unknownOutcome`, then re-read and reconcile |

## 14. Testing conventions
- **Unit:** formatting and normalisers, domain value objects, DTO mapping (including unknown enum values), failure mapping, `MutationController` (key reuse, unknown outcome), notifiers with fake repositories.
- **Widget and golden:** every P0 screen in each state (loading, empty, error, data, offline) × `en`/`ckb` × light/dark × text scale 1.0/2.0 (Phase 2 [08 §3](../../design/phase-2/08-design-acceptance-checklist.md#3-required-evidence-per-screen)). Golden tests use bundled fonts (no network).
- **Navigation:** router redirect tests (no session, no store, deep links), per-tab stack preservation, back behaviour.
- **Integration (`integration_test`):** against the local Supabase stack in CI. Journeys are listed in [testing-and-quality-strategy.md](testing-and-quality-strategy.md).
- **Targets** (proposed, not measured):
  - ≥ 90% line coverage on `core/formatting`, `core/errors`, `core/mutation`;
  - every screen has state goldens;
  - no coverage target on presentation code beyond goldens.
- **Lints:** `flutter_lints` + `tool/check_imports` + no physical-direction APIs + no hard-coded user-facing strings in `presentation/` (CI grep against non-ARB string literals, with an allow-list).
