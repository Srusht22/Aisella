# Deployment and operations

**Phase 3** · Status: **Proposed — pending owner approval** · Nothing here has been provisioned or deployed.

## 1. Environments
| Environment | Backend | App build | Data | Purpose |
|---|---|---|---|---|
| **Local / dev** | Supabase CLI local stack (Docker) | `dev` flavor | Synthetic seed | Development. *Note: the current cloud container has no running Docker daemon, so local-stack work runs in CI or on a developer machine.* |
| **CI** | Ephemeral local stack per job | Test builds | Synthetic seed | Automated tests |
| **Staging** | Separate Supabase project (eu-central-1) | `staging` flavor, internal distribution | Synthetic + owner test stores | Pre-release verification, restore rehearsals |
| **Production** | Supabase Pro project (eu-central-1) | `prod` flavor, TestFlight / Play internal testing for the pilot | Real pilot data | Pilot |

Each environment has its own Supabase project and keys, its own Anthropic key (a separate workspace if available), its own Sentry project/environment tag, its own SMTP sender settings, and (P1) its own channel apps and webhooks.

## 2. Deployment procedures
- **Database:** migrations as SQL files in `supabase/migrations/` (Phase 5+), applied by CI with `supabase db push`:
  - to staging automatically on merge;
  - to production via a **manually approved** workflow, after a fresh platform backup and a nightly dump less than 24 h old.

  Migrations are forward-only and backwards-compatible for one app release (expand, migrate, contract).
- **Edge Functions:** deployed by CI per environment (`supabase functions deploy`). The function version and prompt version are recorded.
- **Mobile app:**
  - Android: AAB built in CI, Play internal testing track for the pilot.
  - iOS: built on a macOS runner or the owner's Mac, distributed through TestFlight.
  - Release builds use Dart obfuscation and split debug info. Symbols are uploaded to Sentry. **Obfuscation is not treated as a security control.**
- **Release signing:**
  - The Android upload keystore and iOS certificates and profiles are stored in CI secrets, plus an offline backup held by the owner.
  - Play App Signing is used.
  - Losing the keystore is a business risk, so the owner keeps an encrypted offline copy.

## 3. Configuration and secrets
| Secret or setting | Where it lives | Never in |
|---|---|---|
| Supabase URL, anon key (public) | App build config (`config/<env>.json`, generated in CI) | — |
| Supabase service-role key | Edge Function environment (platform-provided); CI deploy secret | App, repository |
| Anthropic API key | Supabase function secrets (per environment) | App, repository, logs |
| SMTP credentials | Supabase Auth settings | App, repository |
| Webhook secrets, channel tokens (P1) | Function secrets / Supabase Vault | App, repository, logs |
| Supabase access token for CI deploys | GitHub Actions environment secrets (production environment protected by required reviewer) | Repository |
| Signing keys | CI secrets + the owner's offline backup | Repository |
| Sentry DSN (public by design) | App build config | — |

**Repository templates:**
- `config/*.example.json` (app).
- `supabase/.env.example` (function variable **names** only).
- `.gitignore` already excludes `.env` and `.env.*`; Phase 4 extends it for `config/*.json`.
- `docs/` explains the minimum steps to reproduce a dev environment.

**Minimum setup to reproduce the dev environment:**
1. Flutter 3.47.x, Docker, Supabase CLI.
2. `supabase start`.
3. Copy `config/dev.example.json` to `config/dev.json` (filled with local values printed by the CLI).
4. `flutter run --flavor dev --dart-define-from-file=config/dev.json`.

**No real secrets are needed for local development:** the AI provider is stubbed unless a developer supplies their own key in their local function environment.

**Preventing test data from reaching production:**
- separate projects and keys;
- the app environment ribbon;
- seed scripts refuse to run when `ENV_NAME=prod`;
- sandbox and test orders flagged (`is_test`);
- no production dumps restored outside the isolated rehearsal project.

## 4. Observability
| Signal | Tool | Alert |
|---|---|---|
| App crashes and errors | Sentry (PII-scrubbed) | New issue spike; crash-free sessions below 99% |
| Edge Function errors and latency | Sentry + Supabase function logs | `ai-assist` error rate > 5% over 1 h; p90 latency > 15 s |
| Database health | Supabase dashboard (CPU, connections, disk) | Disk > 70%; connection saturation |
| AI usage and cost | `ai_usage_daily` view + daily summary job | Store over daily cap; organisation spend over threshold (AD-07); invalid-output rate > 5% |
| Business integrity | Nightly reconciliation (stock = Σ movements; totals recomputed) | **Any mismatch** (critical) |
| Jobs | `job_runs` | Any failure of dump, purge, deletion or reconciliation |
| Channel health (P1) | `v_channel_health` | Per [messaging §10](messaging-integration-architecture.md#10-health-and-troubleshooting) |
| Auth email | SMTP provider dashboard | Bounce or failure spikes |

Alerts go to the owner's email (and to a chat channel, if one is set up). There is no 24/7 on-call during the pilot; the support hours are agreed with pilot sellers.

## 5. Backups and restoration
- **Platform:** Supabase Pro daily backups, retained 7 days *(verify)*.
- **Nightly logical dump:** a scheduled CI job runs `pg_dump` of the production database (schemas `app`, `auth`, needed metadata; Storage objects synced separately, weekly), encrypts it with a key held by the owner, and uploads it to separate storage in another provider or account. Retention is 30 days. A job failure alerts.
- **RPO / RTO targets for the pilot:** RPO ≤ 24 h; RTO ≤ 8 h during support hours (proposals, AD-05).
- **Restore rehearsal (before the pilot, then quarterly):**
  1. Restore the latest dump into an isolated, access-restricted project.
  2. Run the reconciliation and smoke queries.
  3. Record the duration.
  4. Delete the project.

  **A backup is only considered valid after a successful rehearsal.**
- **PITR:** recommended before commercialization (ADR-010).

## 6. Rollback
| Change | Rollback |
|---|---|
| Edge Function | Redeploy the previous version (CI keeps artifacts and tags) |
| Database migration | Forward fix preferred. Destructive migrations require the expand/contract pattern and a pre-migration dump. In an emergency: restore to an isolated project and repair the data, rather than restoring production over newer writes. |
| App release | Halt the staged rollout or expire the TestFlight build; the server stays backwards-compatible for one release |
| Prompt or model change | Config rollback to the previous `prompt_version` or model (recorded per run) |

## 7. Incident investigation
1. Triage using Sentry issue references (the reference codes shown to sellers).
2. Look at `audit_events`, `order_status_events`, `inventory_movements`, `ai_runs` (by request reference) and `job_runs`.
3. Break-glass data access only with seller consent ([authorization §7](authorization-and-tenancy.md#7-administrative-and-support-access)).
4. Write a short incident note: timeline, impact, data affected, fix, follow-up.
5. For suspected secret exposure: rotate immediately ([threat model](security-threat-model.md#baseline-controls-apply-everywhere)).
6. Data-protection notification duties are a legal question for the owner (data model §7.3).

## 8. Pilot versus later
| Pilot (minimum adequate) | After validation |
|---|---|
| One Pro production project, a staging project, CI deploys, Sentry free tier, daily plus nightly dumps, restore rehearsal, owner-email alerts | PITR, read replica if needed, status page, on-call rotation, SLOs, log drains or retention extension, a separate support tooling UI, an infrastructure-as-code review |
