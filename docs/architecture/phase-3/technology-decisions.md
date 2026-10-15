# Technology decisions

**Phase 3** · Status: **Proposed — pending owner approval** · Related: [ADRs](architecture-decision-records/README.md) · [Overview](architecture-overview.md) · [Costs](pilot-cost-estimate.md)

## 1. Inputs and evidence

| Input | Status |
|---|---|
| Master prompt, Phase 0 audit | Exist only in the project conversation (not in the repository) |
| Phase 1 product specification | `docs/product/phase-1-product-specification.md`. Decisions D-01–D-15 are **still pending formal approval**; used as the baseline. |
| Phase 2 design specification | `docs/design/phase-2/`. Decisions DD-01–DD-13 are **pending approval**; used as the baseline. |
| Repository | Documentation only; no application code, no dependency files, no CI, no backend configuration (inspected 2026-10-15 on `S.H_Branch`) |
| Prior backend or provider choices | **None.** Phase 0 only *suggested* Supabase. Nothing has been provisioned. |

**Development environment (this cloud container, re-inspected in Phase 3):**
- **Not installed:** Flutter, Dart, Supabase CLI, Deno.
- **Installed:** PostgreSQL 16 (client and server binaries), Node 22, Python 3.13, Java 21.
- **Docker:** CLI present but no running daemon.
- **Network:** `pub.dev` and the Flutter SDK archive are reachable. The Android SDK host (`dl.google.com`), `supabase.com`/`*.supabase.co` and `fonts.google.com` are blocked by the environment's network policy, and web fetches to supabase.com failed DNS resolution.

**Evidence sources used in Phase 3:**
- **pub.dev API** (queried 2026-10-15) for package versions and compatibility.
- **Flutter release index:** stable **3.47.7 / Dart 3.13.5**, released 2026-10-08.
- **Official vendor documentation via web search** (supabase.com, firebase.google.com and cloud.google.com, developers.facebook.com, core.telegram.org, sentry.io).
- **Anthropic's Claude API reference** bundled with Claude Code (pricing cached 2026-10-06).

Where a figure comes from a search summary rather than a page read directly, it is marked *(verify)*. All prices must be re-checked before money is committed.

**Design proof performed:** the approval, tenancy and inventory transaction design was prototyped against a throwaway PostgreSQL 16 ([proofs/approval-consistency](proofs/approval-consistency/README.md)), with 14 checks covering RLS, privileges, concurrency and idempotency. All behaved as designed. This is a design validation, **not** tested production infrastructure.

## 2. Backend and database

### 2.1 Candidates and criteria
Scores run from 1 (poor) to 5 (strong) for *this* product (relational orders and inventory, multi-tenant, 3–5 pilot sellers, a small team).

| Criterion | **Supabase** (managed Postgres + Auth + Storage + Edge Functions) | **Firebase** (Firestore + Auth + Cloud Functions + Storage) | **Custom backend** (for example a TypeScript or Dart server + managed Postgres + separate auth) |
|---|---|---|---|
| Flutter fit | 5. Official `supabase_flutter` 2.18.3, 150/160 pub points | 5. Official FlutterFire | 3. Hand-written client |
| Relational data (orders, lines, variants, movements) | 5. PostgreSQL | 2. Document model; joins and reporting via denormalisation | 5 |
| Transactions and inventory consistency | 5. SQL transactions, row locks, CHECK constraints (proven in this phase) | 3. Firestore transactions exist but invariants live in code and rules; no CHECK or FK | 5 |
| Multi-tenant authorization | 5. Row-level security plus SQL functions | 3. Security Rules (powerful, but relational invariants are awkward) | 4. All in application code |
| Auth | 4. Email and password, OTP, OAuth built in. Default SMTP capped at 2 emails/hour, so production needs custom SMTP. | 5 | 2. Must integrate a provider |
| Webhooks and async | 4. Edge Functions + pg_cron + Queues (pgmq) | 4. Cloud Functions + Pub/Sub | 4. Must build |
| Server-side AI | 4. Edge Functions (Deno/TS), up to 400 s wall clock on paid plans, 2 s CPU per request *(verify)* | 4 | 5 |
| File storage | 4. Storage with RLS policies | 4. Storage with rules | 3. Separate object store |
| Migrations and testing | 5. SQL migrations, local stack via CLI (Docker), pgTAP | 3. Emulator suite; no schema | 4 |
| Backup and restore | 4. Pro: 7 days of daily backups; PITR add-on about $100/month for 7 days *(verify)* | 3. Managed exports | 3. Depends on the host |
| Logging and monitoring | 3. Platform logs, plus Sentry | 4. Cloud Logging | 3 |
| Deployment and ops burden | 5. Managed | 5. Managed | 2. Servers, auth, patching |
| Lock-in | 4. Standard Postgres; Auth (GoTrue) and the edge runtime are open source | 2. Proprietary data model | 5 |
| Pilot cost | 4. Pro $25/month *(verify)*; staging option per AD-09 (second Pro project ≈ $10, or Free organisation) | 4. Usage-based; free daily quotas | 3. Host + database + auth |
| Team productivity | 4. SQL skills required (RLS, plpgsql) | 4 | 3 |

**Decision ([ADR-001](architecture-decision-records/ADR-001-backend-platform.md)): Supabase on PostgreSQL, in a single project per environment.** It is the only option where the database itself enforces the core invariants: stock never negative, one approval per order, tenant isolation. The prototype demonstrated each of those, which reduces the most expensive class of bugs for this product.

**Main risk, discovered in this phase:** Supabase documented regional network blocks of `supabase.co` in 2025–2026 (UAE, Yemen, India). Reachability from Iraqi networks is **unknown** and must be tested in M0 before anything is built (ADR-009).

### 2.2 How the backend is used (summary)
- **Reads:** Flutter reads tables and views directly through the PostgREST API with the user's JWT; **RLS** restricts every row to the user's store.
- **Writes:** **every business mutation is a PostgreSQL function** (`api.*`, called via RPC) that checks authorization, validates, runs in one transaction, records audit and history, and honours idempotency keys. The `authenticated` role has **no** INSERT, UPDATE or DELETE privilege on business tables ([ADR-002](architecture-decision-records/ADR-002-mutations-through-database-functions.md)).
- **Edge Functions** (TypeScript on Deno) host only what SQL cannot: AI calls, external webhooks (P1), account deletion (it needs the Auth admin API), scheduled jobs.
- **Background work:** Supabase Queues (pgmq) + pg_cron triggering Edge Functions. No separate worker infrastructure ([ADR-008](architecture-decision-records/ADR-008-background-processing.md)).

### 2.3 Region
`eu-central-1` (Frankfurt). The published Supabase region list has **no Middle East region**; Frankfurt is the nearest listed EU region (Mumbai is the other plausible option). Latency from KRI is **unmeasured** and is measured in M0. A project cannot change region in place, which makes this an expensive decision to reverse ([ADR-009](architecture-decision-records/ADR-009-region-and-network-reachability.md)).

## 3. Flutter stack

Compatibility was checked against Flutter **3.47.7 / Dart 3.13.5** using pub.dev metadata (latest versions, published dates, SDK constraints). Versions are pinned at Phase 4 setup, and re-checked then.

| Concern | Choice | Latest version (2026-10-15) | Why | Alternatives considered |
|---|---|---|---|---|
| Backend client and auth session | `supabase_flutter` | 2.18.3 (Dart ≥ 3.9, Flutter ≥ 3.35) | Official; handles token refresh | Hand-written HTTP (rejected: re-implements auth) |
| State management and DI | `flutter_riverpod` (Riverpod 3) | 3.4.3 (Dart ^3.12) | Async state (`AsyncValue`) maps directly onto the loading/error/data patterns in Phase 2 §1; compile-safe DI and test overrides; no BuildContext coupling | **Bloc** (more ceremony; explicit events are good but heavier for a 1–2 person team); **Provider** (superseded by Riverpod for these needs); `setState`-only (does not scale) ([ADR-006](architecture-decision-records/ADR-006-flutter-state-and-routing.md)) |
| Routing | `go_router` (flutter.dev publisher) | 18.1.0 (Flutter ≥ 3.44) | `StatefulShellRoute` gives per-tab stacks (Phase 2 IA §3.1); URL deep links; redirects for auth | `auto_route` (codegen-heavy); Navigator 2.0 by hand (costly) |
| Models | `freezed` + `json_serializable` | 4.0.2 / 6.14.1 | Immutable typed models, unions for result types | Hand-written (error-prone) |
| Secure session storage | `flutter_secure_storage` | 11.2.0 | Keychain / Keystore-backed storage for the refresh token ([ADR-013](architecture-decision-records/ADR-013-client-session-storage.md)) | Default shared preferences (rejected for tokens) |
| Crash and error reporting | `sentry_flutter` | 10.1.0 | Crash reporting with PII scrubbing; free Developer plan for the pilot *(verify quota)* | Firebase Crashlytics (would add a second platform) |
| Localization | Flutter gen-l10n (ARB) + `intl` | intl 0.20.3 | Official; ICU plurals. `ckb` support in system localizations is unverified (Phase 2 [07 §1](../../design/phase-2/07-localization-and-accessibility.md#1-localization-foundations)). | — |
| Images | `image_picker`, `cached_network_image`; compression package chosen in Phase 6 | 1.2.4 / 4.0.4 | Standard | — |
| Connectivity | `connectivity_plus` | 7.3.2 | Offline banner (GL-01), combined with request failures | — |
| Offline read cache | **Deferred (P1)**; `drift` 2.35.2 is the candidate | — | P0 offline behaviour is "detect and never fake success" (Phase 1) | — |
| Icons | DD-05 pending (vendored Phosphor subset preferred; `phosphor_flutter` last published 2024-05-10) | — | — | — |
| Testing | `flutter_test`, `mocktail` 1.0.5, golden tests | — | — | — |

## 4. AI provider
- **Decision ([ADR-007](architecture-decision-records/ADR-007-ai-integration-boundary.md)):** Anthropic Claude via the Messages API, called **only from an Edge Function**.
- **Model:** `claude-opus-5-5` (the current default per Anthropic's reference; $4 input / $20 output per million tokens; cache reads $0.20 per million) at **low or medium effort**, tuned by evaluation.
- **Output:** structured outputs (`output_config.format` JSON schema) plus server-side validation.
- **Model tier is the owner's call (AD-07):** cheaper tiers (`claude-sonnet-5-5` at $2/$10, `claude-haiku-5-5` at $0.10/$0.50) can be adopted only if the Phase 8 evaluation set shows equal quality. Costs for both are shown in [pilot-cost-estimate.md](pilot-cost-estimate.md).
- The provider boundary is an internal interface (`AiProvider`) so another provider can be added later without touching business logic.
- **Data retention terms of the AI provider must be reviewed by the owner** before real customer messages are sent (Phase 1 BR-73). The Claude API reference states that zero-data-retention arrangements exist and that Opus 5.5 follows Opus 5's ZDR availability. The applicable commercial terms are **not** verified here.

## 5. Supporting services

| Need | Choice for the pilot | Notes |
|---|---|---|
| Transactional email (verification, reset) | Custom SMTP provider (choice deferred to Phase 5; several have free tiers) | Required: Supabase's built-in email is capped at 2/hour, best effort and delivers only to project team members *(verify)* |
| Error monitoring | Sentry (Developer plan, free; 1 user) *(verify quota)* | Team plan reported at about $26–29/month if needed *(verify)* |
| CI | GitHub Actions | Repository already on GitHub. Supabase CLI and Docker run in CI. |
| Android builds | GitHub Actions (or the owner's machine) | The cloud dev environment cannot download the Android SDK (Phase 0) |
| iOS builds | macOS runner (GitHub Actions) or the owner's Mac; Apple Developer account | — |
| Push notifications | **Not in P0** (P1, with the first live channel); FCM/APNs then | — |
| Messaging channels | Not in P0 (Stage A uses manual import). Telegram is the lowest-friction first live channel to build; the Meta channels need app review and business verification ([messaging doc](messaging-integration-architecture.md)). | — |

## 6. Deliberately not adopted
Microservices, Kubernetes, self-hosted models, vector databases or pgvector, event streaming, a separate API server, GraphQL, Redis, a second backend platform, Lottie/Rive, an offline-write sync engine. Each has a reconsideration trigger in its ADR or in [implementation-roadmap.md](implementation-roadmap.md).

## 7. Stable boundaries if the product scales
1. Tenant key (`store_id`) on every business row.
2. All mutations through named, versioned database functions. They can later move behind a dedicated API service without changing the client contract shape.
3. The `AiProvider` and `ChannelAdapter` interfaces.
4. Append-only ledgers: inventory movements, status events, audit.
5. The idempotency-key contract.
