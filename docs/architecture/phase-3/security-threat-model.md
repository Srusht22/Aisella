# Security threat model

**Phase 3** · Status: **Proposed — pending owner approval** · Scope: the architecture in [architecture-overview.md](architecture-overview.md) (P0), plus live channels (P1) where noted.

**Assets:**
- store business data (catalog, prices, stock, orders)
- **customer personal data** (names, phones, addresses, message content)
- seller accounts
- secrets (service-role key, Anthropic key, SMTP credentials, channel tokens, webhook secrets)
- AI spend
- availability and recoverability of the data

**Adversaries:**
- another seller (a curious or malicious tenant)
- an outsider holding a stolen or guessed credential
- a malicious customer (via message content)
- a forged-webhook sender (P1)
- an accidental insider (an operator or developer mistake)

**Risk** = likelihood × impact, rated qualitatively (L/M/H).

**Timing** (in the "When" column):
- **Pilot**: must be in place before the first external seller.
- **Comm.**: needed before broader commercialization.

## Threats

| ID | Threat | Component | Impact | Likelihood | Risk | Mitigations (layered) | Verification | Residual | When |
|---|---|---|---|---|---|---|---|---|---|
| T-01 | **Cross-tenant data access** | Postgres, PostgREST, Storage | H: privacy breach, loss of trust | M (one policy bug is enough) | **H** | `store_id` on every row; SELECT-only grants; RLS on all tables; explicit checks in every function; composite FKs; storage path policies; `NOT_FOUND` for foreign IDs | NT-01…NT-07, NT-11, NT-13 in CI; a catalog-driven test generator; prototype T1/T4 | Low | Pilot |
| T-02 | **Broken authorization on a new function** | `api.*` | H | M | **H** | `require_permission` / `require_end_user` helpers; review checklist; CI fails when a function lacks a negative test | Generated negative tests | Low | Pilot |
| T-03 | **Account compromise** (weak or reused password, phishing) | Auth | H for that store | M | **H** | Password ≥ 8 characters with a strength hint; Supabase rate limits; leaked-password protection if available *(verify)*; refresh-token rotation; "sign out all devices"; email on new sign-in *(P1)*; MFA for sellers *(Comm.)*; MFA **required** for the owner's Supabase and GitHub accounts | Auth configuration review; rate-limit test | Medium (no seller MFA in P0) | Pilot (dashboard MFA); Comm. (seller MFA) |
| T-04 | **Leaked privileged key** (service role, Anthropic, channel tokens) | Repository, CI, Edge | H: full data read; AI spend | L–M | **H** | Secrets only in Supabase secrets, Vault and CI secrets; `.gitignore` of env files; secret scanning on push (GitHub secret scanning plus a pre-commit scanner); no secrets in the app; least-privilege CI deploy token; rotation runbook; `require_end_user` prevents approvals even with the service role | Scan in CI; quarterly rotation drill *(Comm.)*; review that the app bundle contains no secrets (strings check in CI) | Low–Medium | Pilot |
| T-05 | **Anon key misuse** (public by design) | PostgREST | M | H (it is public) | M | The anon role gets no table grants and no `api.*` execution except auth-related routes; RLS deny-by-default | NT-04 | Low | Pilot |
| T-06 | **Insecure file access** (guessing image URLs, uploading malware or huge files) | Storage | M | M | M | Private bucket; signed URLs with 1 h TTL; path policies; MIME and size allow-list; client re-encoding; server-side size checks; no file execution or serving as HTML | NT-07; upload tests with wrong types and sizes | Low | Pilot |
| T-07 | **Malicious customer messages / prompt injection** | AI pipeline | M: misleading replies, cost | H | **H** | No mutating tools; data-only delimiters; server-rendered facts; reply guard; escalation; seller must copy or send manually; approval impossible from the AI path | Injection cases in the AI evaluation set; prototype T5 | Medium (the model may still write odd text; the seller reviews it) | Pilot |
| T-08 | **Unauthorized order approval** | Approval function | H: wrong orders, stock | L | M | Owner-only; end-user JWT required; verified email; version and status checks; two-step UI; audit | NT-05, NT-08, NT-09; prototype T4–T6 | Low | Pilot |
| T-09 | **Duplicate order or duplicate stock deduction** | Orders, inventory | H: wrong stock and money | M | **H** | Idempotency keys; status-transition guards; row locks; one open AI draft per conversation; unique event and message IDs | Prototype T6, T11, T14; concurrency tests in CI | Low | Pilot |
| T-10 | **Stock manipulation** (direct writes, negative stock, ledger tampering) | Inventory | H | L | M | No table writes; CHECK ≥ 0; append-only ledger; nightly reconciliation alert | NT-03, NT-10; reconciliation job test | Low | Pilot |
| T-11 | **Forged or replayed webhooks** | Channel webhook (P1) | H: fake conversations or orders | M | **H** (P1) | Signature or secret-token verification on the raw body; per-connection URL; event-ID dedupe; reject stale timestamps where the provider supplies them; rate limiting | Signature tests (valid, invalid, missing, replay) | Low | P1 before launch |
| T-12 | **Exposed messaging tokens** | Vault, Edge (P1) | H: impersonation of the seller's channel | L | M | Tokens only in Vault; write-only entry UI; never logged; revoke on disconnect; least scopes | Log-scrubber tests; review | Low | P1 |
| T-13 | **Abuse of AI endpoints / runaway cost** | `ai-assist` | M (money) | M | M | JWT required; per-store rate limits and daily caps; idempotency; alerts; provider-side spend limits *(owner sets; verify)*; payload size limits | Rate-limit tests; cost alert test | Low | Pilot |
| T-14 | **Denial of service** (request floods, oversized payloads) | All public endpoints | M | L–M | M | Supabase platform limits; statement timeouts; payload caps; rate limits; Edge timeouts | Load smoke test *(Comm.)* | Medium (managed-platform dependent) | Pilot (basic) |
| T-15 | **Insecure administrative access** | Supabase dashboard, GitHub, CI | H | L–M | M | MFA on all admin accounts; named accounts (no shared logins); break-glass procedure with consent and logging; least-privilege CI tokens; protected branches *(when a main branch policy exists)* | Account review checklist | Low | Pilot |
| T-16 | **Sensitive data in logs** | Edge, client, Sentry | M: privacy | M | M | Redaction rules ([data model §7.2](backend-and-data-model.md#72-redaction-rules)); Sentry scrubbing; no body logging; review | Unit tests for the scrubber; log sampling review before the pilot | Low | Pilot |
| T-17 | **Production data exposed in non-production** | Staging, dev | H | M | M | No production dumps in staging or dev; synthetic fixtures; separate projects and keys; an environment ribbon in the app; restore rehearsals into an isolated, access-restricted project that is deleted afterwards | Process checklist | Low | Pilot |
| T-18 | **Backup or recovery failure** | Platform, dumps | H: data loss | L–M | M | Daily platform backups (7 days); nightly encrypted logical dumps (30 days) to separate storage; job-failure alerts; **restore rehearsal before the pilot** and quarterly; documented runbook | Rehearsal record with timings | Medium (RPO ≤ 24 h, AD-05) | Pilot |
| T-19 | **Session theft on device** | App | M | L | L | Tokens in Keychain or Keystore; HTTPS; short access-token TTL; sign-out clears storage; server-side revocation | Review; Phase 5 tests | Low | Pilot |
| T-20 | **Supply-chain risk in dependencies** | Flutter packages, Edge imports | M–H | L | M | Pinned versions and lockfiles; minimal dependencies; Dependabot or equivalent alerts; review new packages (licence, maintenance) | CI dependency audit | Low–Medium | Pilot |
| T-21 | **Regional network blocking of the backend** (availability) | Supabase domains | H (app unusable) | **Unknown** | **H until measured** | M0 reachability tests; configurable base URL; custom-domain or proxy contingency (ADR-009) | M0 report | Unknown | Before build |
| T-22 | **Fabricated AI claims reaching customers** | AI, seller copy | M | M | M | Server-rendered facts; guard; "not sent" labelling; the seller reviews before copying | Fabrication = 0 evaluation gate | Low–Medium | Pilot |

## Baseline controls (apply everywhere)
- **Transport:** HTTPS only (platform-enforced); no cleartext traffic in Android or iOS configuration.
- **Sessions:** Supabase JWT (about 1 h access token) with refresh rotation; secure storage on device; server-side revocation on sign-out or password change.
- **Trusted execution:** business rules only in database functions and Edge Functions.
- **Input validation:** at the database-function boundary (types, ranges, lengths, enums); the client validates for UX only.
- **Rate limiting:** Auth (platform), AI, imports, mutations (database counters).
- **Auditing:** the audited actions list in [authorization §8](authorization-and-tenancy.md#8-audit-requirements).
- **Secret rotation:** a documented runbook (rotate, redeploy functions, verify, revoke the old secret). Required immediately after any suspected exposure; rotate routinely *(Comm.)*.

## Pre-pilot security gate (summary)
The following must be complete before the first external seller:
1. All Pilot-timed mitigations for T-01–T-10, T-13, T-15–T-19 and T-21.
2. NT-01…NT-15 passing in CI.
3. Dashboard and GitHub MFA enabled.
4. Secret scanning on.
5. Restore rehearsal done.
6. AI evaluation gates met.
7. Provider terms reviewed (AD-08).
