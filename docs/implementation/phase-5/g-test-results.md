# G. Tests and results

All results below were produced on the final Phase 5 tree (commit `462ab84` plus these docs) on 2026-10-17. They ran in this environment against the **local** Supabase stack: Postgres 17, GoTrue v2.197, PostgREST v16, Kong 2.8 and Mailpit.

## 1. Summary

| Check | Command | Result |
|---|---|---|
| Format | `dart format --output=none --set-exit-if-changed lib test tool` | ✅ 100 files, 0 changed |
| Static analysis | `flutter analyze` | ✅ No issues |
| Tokens current | `dart run tool/gen_tokens.dart --check` | ✅ |
| Layer boundaries | `dart run tool/check_imports.dart` | ✅ 78 files |
| No physical left/right | `dart run tool/check_directional.dart` | ✅ 78 files |
| Unit + widget + golden | `flutter test` | ✅ **171 passed** (144 unit/widget, 27 golden); 11 backend tests skipped without a stack |
| Database (pgTAP) | `bash supabase/tests/run_db_tests.sh` | ✅ **94 assertions** in 4 suites |
| Backend integration | `flutter test --tags backend` with the stack's URL, key and Mailpit | ✅ **11 passed** |
| Everything together | `flutter test --coverage` with the backend variables set | ✅ **182 passed** |
| Line coverage | `lcov.info` from the run above | 88.5% overall; Phase 5 auth, store, guard and backend code 87.9%; `route_guard.dart` 100% |

The Phase 4 baseline was 58 unit/widget and 19 golden tests. Phase 5 adds 86 unit/widget tests, 8 goldens, 11 backend tests and the pgTAP suites.

## 2. Flutter tests (fakes behind the real interfaces)

| File | Tests | What it proves |
|---|---|---|
| `test/app/route_guard_test.dart` | 9 | For every auth and workspace state and every route, a redirect lands on an allowed, stable home (**no loops**). Signed-out sellers reach only public routes. An expired session goes to sign-in. Setup resumes at the first incomplete step. A ready seller cannot reopen sign-in or setup. Another user's cached workspace is never used. |
| `test/core/phase5_units_test.dart` | 23 | Credential rules; phone normalization (local, international, Eastern digits); fee parsing; field-issue mapping; provider error-code mapping; envelope unwrapping and PostgREST error mapping; `IntentKey` reuse; privileged-key refusal; `dayMonthYear` in both languages |
| `test/features/auth_flow_test.dart` | 18 | Cold start signed out → Welcome, never Today; restore → workspace; workspace failure → Retry; the provider ending the session leaves the workspace; field errors send nothing; one generic credential message; double taps send one request; service failures are distinct from wrong credentials; sign-out revokes, and Back cannot return; re-sign-in reloads from the server; reset does not reveal accounts; recovery is restricted to setting a new password |
| `test/features/onboarding_settings_test.dart` | 16 | A seller without a store lands on setup; missing fields block creation; full setup (create, skip zones, finish → Today); a lost response is reconciled with no second store; restarting mid-setup resumes at the saved step; zones with Eastern digits saved before moving on, and an enabled zone without a fee not sent; turning off every payment method blocked; profile saves only the changed field; a version conflict reloads and explains without claiming success; zones list, add and remove; account email and sign-out everywhere; deletion (password and exact name required, a wrong password deletes nothing, success → only sign-out remains) |
| `test/features/phase5_localization_test.dart` | 3 | Sorani sign-in is RTL with LTR email and password; Sorani setup labels with an LTR phone; every auth and setup screen at 200% text on 360×640 in both languages without exceptions |
| `test/design_system/text_field_semantics_test.dart` | 1 | Text fields expose label, value and error in one semantics node |
| `test/goldens/screens_golden_test.dart` | 27 (8 new `p5_*`) | Visual baselines ([F §5](f-localized-ui.md#5-visual-review)) |
| Phase 4 suites | updated | Navigation and screens now start from a signed-in seller with a store; the Sorani/English key-parity test covers the new keys |

Widget and golden tests run on a **fixed clock** (`clockProvider`, Thursday 15 October 2026), so screens that show today's date render the same on every day. This was found during the final run, when the goldens failed on a later date, and fixed in `462ab84`.

## 3. Backend integration tests (real stack)

`test/backend/backend_integration_test.dart`, tag `backend`. The tests use the app's own `SupabaseAuthRepository`, `SupabaseStoreRepository` and `callApi` against real GoTrue and PostgREST, and read emails through the Mailpit API.

| Test | Proves |
|---|---|
| Sign-up requires email verification before sign-in | `email_not_confirmed` until the Mailpit link is opened; afterwards sign-in works |
| Signing up an existing email is reported, without a second account | `emailInUse`; the original password still works |
| Wrong password and unknown account give the same failure | No account enumeration through sign-in |
| Short passwords are rejected by the provider | The rule is enforced server-side, not only in the app |
| Password reset | The same answer for unknown emails; the real email link and PKCE code set a new password; the old one stops working |
| Sign-out revokes the refresh token | The refresh token is refused after sign-out |
| Stores: create, replay, one per user, update, zones | The idempotent replay returns the same store; a second store gives `LIMIT_EXCEEDED`; versioned update; zone create and duplicate |
| Tenant isolation | Seller B gets `NOT_FOUND` on A's store and zones with forged ids and sees nothing in the views; A is unchanged |
| Direct writes and unexposed schemas | `PATCH` on `api.stores` refused; `app` schema and `app.is_member` unreachable |
| Anonymous callers and forged tokens | Refused; a forged JWT gives `UNAUTHENTICATED` |
| Account deletion with a real fresh JWT | Deletion accepted after a password sign-in; access ends at once; 14-day schedule |

The tests skip unless `SUPABASE_TEST_URL`, `SUPABASE_TEST_PUBLISHABLE_KEY` and `MAILPIT_TEST_URL` are set. Each run uses unique email addresses, so runs do not interfere with each other.

## 4. Database tests (pgTAP)

`supabase/tests/database/*.test.sql`. Each file runs in a rolled-back transaction. `_helpers.psql` impersonates users by setting the JWT claims, including `amr`, the way PostgREST does.

| Suite | Assertions | Covers |
|---|---|---|
| `01_catalog_guards` | 9 | RLS everywhere; no client write privileges; `anon` executes nothing; definer functions use an empty `search_path`; views are security-invoker; the `api` surface equals the reviewed list |
| `02_tenant_isolation` | 27 | Phase 3 NT-01 to NT-06 and NT-10 ([D §5](d-ownership-and-authorization.md#5-tenant-isolation-evidence)) |
| `03_store_rules` | 41 | Every store and zone rule, idempotency, versions, currency lock, payments rule, audit, onboarding order ([E §3](e-business-settings.md#3-verified)) |
| `04_account_deletion` | 17 | Re-authentication window, name check, immediate loss of access, pending-state rules, idempotent repeat, purge permissions, purge result, other sellers untouched |

**Mutation check.** Breaking each guard on purpose made the suites fail:

| Mutation | Failing assertions |
|---|---|
| `is_member` always true | 17 |
| permission check skipped | 8 |
| write grant added | 2 |

After `supabase db reset` they passed again ([D §5](d-ownership-and-authorization.md#5-tenant-isolation-evidence)).

## 5. Not tested here

- **Device builds and runs** (Android or iOS): this environment has no Android SDK or Xcode, so the keystore, deep links, and email links opening the app on a device were **not** exercised. The SDK's PKCE exchange was exercised through the backend test with the real link, without the OS hand-off.
- **Hosted Supabase:** none exists ([H §4](h-setup-and-configuration.md#4-hosted-project-checklist-not-done-needs-authorization)).
- **The pg_cron schedule firing:** the job is created by the migration. The purge function itself is tested directly; waiting for the 03:17 UTC run was not.
- **Real SMTP delivery and spam placement.**
