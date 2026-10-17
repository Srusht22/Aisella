# I. Phase 5 completion report

**Phase:** 5. Secure authentication, seller onboarding, store creation and account management.
**Status:** Complete. **Waiting for owner approval. Phase 6 has not started.**
**Branch:** `S.H_Branch`.

## 1. Summary

Aisellia now has real accounts and real stores:
- sellers sign up, verify their email, sign in, reset their password and sign out through **Supabase Auth**, with the session in the platform keystore;
- one auth controller and one pure route guard decide everything a seller can reach;
- setup (store, delivery zones, payments) is stored in **Postgres** and resumes where it stopped;
- the store's business settings are edited against the server, with conflict, retry and idempotency handling;
- sellers can request **account deletion**, with re-authentication and a 14-day purge.

Ownership and tenant isolation are enforced **in the database**:
- RLS on every table;
- no client write privileges;
- every mutation runs through an authorizing function;
- non-members get `NOT_FOUND`.

This is shown by pgTAP, by end-to-end tests through the real GoTrue and PostgREST, and by mutation checks that confirm the tests catch a broken guard.

**Evidence** ([G](g-test-results.md)):
- 171 Flutter tests (144 unit/widget, 27 golden);
- 11 real-backend tests;
- 94 database assertions;
- analyzer, format, token, import-boundary and RTL checks clean;
- 88.5% line coverage.

## 2. Commits

| Commit | Message |
|---|---|
| `0d81b7a` | feat(backend): Supabase schema for identity, stores, onboarding and zones |
| `42d058f` | feat(auth,onboarding): Supabase authentication, protected navigation and store setup |
| `b252fb4` | feat(account): account deletion with re-authentication, plus real-backend tests |
| `462ab84` | fix(today): read the date through an injectable clock; remove unused reloadUser |
| *(this commit)* | docs(phase-5): authentication, navigation, onboarding, authorization, settings, localization, tests, setup and completion report |

Each commit was validated before it was pushed. Each push was verified by fetching `origin/S.H_Branch` and comparing hashes.

## 3. Scope check against the Phase 5 brief

| Deliverable | Result |
|---|---|
| A. Functional authentication | ✅ [A](a-authentication.md). Sign-up, verification, sign-in, reset, change password (by link), sign-out on this device or everywhere, re-authentication. P5-D1 adapts AU-06. |
| B. Central auth state and routing | ✅ [B](b-auth-state-and-routing.md). `AuthController` plus `guardRedirect`, with an exhaustive no-loop test |
| C. Real onboarding with persisted stores | ✅ [C](c-onboarding-and-stores.md) |
| D. Server-side ownership and authorization | ✅ [D](d-ownership-and-authorization.md) |
| E. Persistent business settings | ✅ [E](e-business-settings.md) |
| F. Localized UI | ✅ [F](f-localized-ui.md). Sorani wording still needs native review (DD-04). |
| G. Automated tests | ✅ [G](g-test-results.md) |
| H. Setup and configuration docs | ✅ [H](h-setup-and-configuration.md) |
| I. Completion report | ✅ This document |
| No catalogue, inventory, orders, AI, messaging, fulfilment, billing or analytics | ✅ No such tables, functions or screens. The Phase 4 sample-data screens are unchanged and labelled. |
| Minimal records only | ✅ Profiles, stores, members, zones, audit, idempotency, deletion requests |
| Architecture kept (Phase 3) | ✅ Supabase plus Flutter/Riverpod/go_router. Deviations are listed in §8. |
| No new production infrastructure | ✅ Local stack only; nothing hosted was created |
| No service key in the client, auth and RLS never disabled, no fake auth | ✅ The app refuses privileged keys; tests run against the real provider |
| No secrets committed | ✅ Only `*.example.json`. Every staged diff was scanned before commit; the one JWT-shaped string in the tests is a deliberately forged, unsigned token. |

## 4. The 17 items

1. **Auth provider and configuration:** Supabase Auth (GoTrue) with email and password, the PKCE flow, keystore session storage and a publishable key only. Settings are in [A §1](a-authentication.md#1-provider-and-configuration).
2. **Flows that work:**
   - sign-up with terms consent;
   - email verification by link;
   - sign-in with generic errors;
   - forgot password, and a new password from the link;
   - change password by link;
   - sign-out, and sign-out everywhere;
   - session restore;
   - re-authentication;
   - account deletion request;
   - store setup in three steps;
   - store profile, zones, payments and account settings.
3. **Session restore and revoke:**
   - restored from the keystore at launch, with nothing protected shown until it is known;
   - expired or revoked sessions go to Sign in with an explanation;
   - sign-out revokes the refresh token on the server (tested against the real stack);
   - "everywhere" revokes all of the user's sessions;
   - a 401 from the API clears the local session;
   - reinstalling on iOS cannot restore an old session.
4. **Protected navigation:** one pure guard, with one home per state, so it cannot loop. Deep links and Back cannot reach protected routes. Setup resumes at the saved step. A pending deletion locks the account to one screen.
5. **Ownership enforcement:** in Postgres, through RLS SELECT policies on membership, no client write grants, and `SECURITY DEFINER` api functions that check membership and permission. Non-members get `NOT_FOUND`. There is one owner per store and one store per user (P0).
6. **Settings that persist:**
   - server: store name, phone, city, currency (with a lock guard), reply language, delivery zones, payment methods, onboarding progress, terms version and the deletion request;
   - device only (by design): language, digits, theme and motion.
7. **Backend and database changes:**
   - `supabase/config.toml`;
   - two migrations: `app`, `api` and `internal` schemas, 7 tables, RLS, 2 views, 7 api functions, the sign-up trigger, the purge job and the pg_cron schedule;
   - an empty `seed.sql`;
   - 4 pgTAP suites with a runner.
8. **Tests and results:**
   - Flutter: 171 passed;
   - backend: 11 passed;
   - pgTAP: 94 passed;
   - all static checks clean.

   Details are in [G](g-test-results.md).
9. **Security and tenant isolation:**
   - isolation is proven at the database and API level, and the tests fail if a guard is removed;
   - no tokens or secrets in logs;
   - privileged keys are refused;
   - credential errors are generic, and reset does not reveal whether an account exists;
   - re-authentication is checked from the JWT for deletion;
   - every mutation is audited.

   Residual risks are in §6.
10. **Outstanding configuration:**
    - a hosted Supabase project (staging and prod) with the settings in [H §4](h-setup-and-configuration.md#4-hosted-project-checklist-not-done-needs-authorization);
    - a production SMTP sender and localized email templates;
    - the final app identifier and URL scheme (AD-10), then the redirect URLs, Android and iOS;
    - real `staging.json` and `prod.json` in CI secrets.
11. **Known issues and risks:** see §6.
12. **Files changed:** see §7.
13. **Branch:** `S.H_Branch`.
14. **Commit hashes:** `0d81b7a`, `42d058f`, `b252fb4`, `462ab84`, plus the docs commit (hash reported in the hand-off message).
15. **Push status:** each commit was pushed with `git push -u origin S.H_Branch` and verified with `git fetch` plus a local-versus-remote hash comparison. The final verification is reported in the hand-off message.
16. **Uncommitted work:** none intended. `config/dev.json` (local key) and `coverage/` are git-ignored and not committed.
17. **Next steps before Phase 6:** see §9.

## 5. Decisions needed from the owner

| ID | Decision | Recommendation |
|---|---|---|
| **P5-D1** | AU-06 "Continue setup" before verification is not possible with Supabase confirmations on. The app waits for the link instead. | Accept. The alternatives are in [A §3](a-authentication.md#3-decision-p5-d1-verification-before-first-sign-in). |
| P5-D2 | Change password in-session (ST-07) is implemented as a reset link by email | Accept for P0; revisit together with MFA |
| P5-D3 | Deletion can be cancelled only through support (no in-app cancel), and no confirmation email is sent until SMTP exists | Accept for the pilot; add both before public launch |
| Carried over | D-01–D-15, DD-01–DD-13, AD-01–AD-12 (especially **AD-10** app identifier and **DD-04** Sorani review) | Still pending from earlier phases |

## 6. Known issues and risks

| Risk | Impact | Mitigation |
|---|---|---|
| An access JWT stays valid up to 1 h after sign-out or deletion if it was copied before | A stolen token works until it expires | It is short-lived. Deletion also blocks all store access in the database at once, because membership is checked on every call. |
| No device builds were run (no Android SDK or Xcode here) | Keystore, deep-link hand-off and email links opening the app are unverified on real OSes | Run the manual device checklist (H §4 step 8) before the pilot |
| No hosted project | Configuration drift between local and hosted settings | H §4 checklist; consider `supabase config push` deliberately |
| Built-in mailer and no SMTP | Emails rate-limited and possibly marked as spam; no deletion email | Production SMTP with SPF, DKIM and DMARC before the pilot |
| Sign-up says "this email already has an account" (US-001) | Possible account enumeration through sign-up | Provider rate limits; this was a Phase 1 product choice. It could be changed to a neutral message if the owner prefers. |
| Sorani strings are machine-drafted | Wording errors | Native review (DD-04) |
| Provisional URL scheme `app.aisellia://` | Another app could register the same custom scheme | PKCE: an intercepted code is useless without the verifier stored on the device. Move to verified App Links and Universal Links once AD-10 fixes the domain. |
| pg_cron purge not observed firing | A purge could be missed | The function is idempotent and catches up on the next run. Monitor `cron.job_run_details` in hosted projects. |
| The Terms and Privacy Policy do not exist yet (AD-06); the Terms screen says so, and sign-up records consent to version `2026-10` of the pending documents | Consent is to documents still being written | Publish the final texts after legal review, bump `currentTermsVersion`, and ask existing sellers to accept again before the pilot |

## 7. Files changed (since Phase 4, `5386d99`)

95 files in the feature commits, plus this phase's fix and docs:

- **Backend:**
  - `supabase/config.toml`, `supabase/.gitignore`, `supabase/seed.sql`;
  - `supabase/migrations/20261015170000_identity_stores_onboarding.sql`, `…210000_account_deletion.sql`;
  - `supabase/tests/run_db_tests.sh`, `supabase/tests/database/{_helpers.psql, 01–04 *.test.sql}`.
- **App core:**
  - `lib/app/{bootstrap, router, route_guard, gate_screens}.dart`;
  - `lib/core/backend/{api, idempotency, secure_session_storage}.dart`;
  - `lib/core/clock.dart`;
  - `lib/core/config/app_config.dart`, `lib/core/formatting/dates.dart`, `lib/core/settings/key_value_store.dart`.
- **Features:**
  - `lib/features/auth/**` (domain, data, application, 6 presentation files);
  - `lib/features/store/**` (domain, validation, repository, workspace controller);
  - `lib/features/onboarding/presentation/setup_screens.dart`;
  - `lib/features/settings/{store_menu_screen, store_settings_screens}.dart`;
  - `lib/features/today/presentation/{today_screen, setup_checklist}.dart`;
  - `lib/features/common/{api_error_text, form_page, form_widgets, store_forms, deferred_feature_screen, top_level_page}.dart`;
  - `lib/features/products/presentation/products_screen.dart`.
- **Design system:** `components/{inputs, feedback}.dart`, `icons/app_icons.dart`, Phosphor subset fonts.
- **Localization:** `lib/l10n/app_en.arb`, `app_ckb.arb`.
- **Platform and config:** `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`, `pubspec.yaml` and `pubspec.lock`, `config/dev.example.json`, `config/README.md`, `dart_test.yaml`.
- **Tooling:** `tool/check_imports.dart`, `tool/icons/{gen_app_icons.py, subset_phosphor.py, phosphor_codepoints.json, README.md}`.
- **Tests:**
  - `test/app/{route_guard_test, navigation_test}.dart`;
  - `test/core/{phase5_units_test, foundation_test}.dart`;
  - `test/features/{auth_flow_test, onboarding_settings_test, phase5_localization_test, screens_test}.dart`;
  - `test/design_system/text_field_semantics_test.dart`;
  - `test/backend/backend_integration_test.dart`;
  - `test/helpers/{fakes, test_app}.dart`;
  - 8 new golden PNGs.
- **Docs:** `docs/implementation/phase-5/*`.

## 8. Deviations from earlier specs

| Spec | Deviation | Where |
|---|---|---|
| Phase 2 AU-06 | Waits for the link (P5-D1) | [A §3](a-authentication.md#3-decision-p5-d1-verification-before-first-sign-in) |
| Phase 2 ST-07 | Change password by email link | [A §4](a-authentication.md#4-behaviour-that-differs-from-the-specs-and-why) |
| Phase 3 config key `SUPABASE_ANON_KEY` | `SUPABASE_PUBLISHABLE_KEY` (SDK rename) | [config/README.md](../../../config/README.md) |
| Phase 1 US-004 | No confirmation email; cancellation through support | [D §6](d-ownership-and-authorization.md#6-account-deletion) |

No Phase 1–3 document was edited; the deviations are recorded here for the owner to accept or reject.

## 9. Next steps before Phase 6

1. **Owner review and approval** of Phase 5, and decisions on P5-D1 to P5-D3.
2. Decide **AD-10** (domain and app identifier), then switch to verified App Links and Universal Links.
3. **Authorize** creating the hosted staging project; apply the H §4 checklist and SMTP.
4. Run the **device checklist** on Android and iOS against staging: sign-up link, reset link, restore after kill, reinstall, sign-out everywhere.
5. Native **Sorani review** of the Phase 4 and 5 strings (DD-04).
6. Final Terms and Privacy Policy after legal review (AD-06), then bump the terms version and re-ask for consent.

**Phase 6 will not start until you explicitly authorize it.**
