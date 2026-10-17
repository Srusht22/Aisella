# F. Test report

All results below were produced in this environment on 2026-10-17, against the **local** Supabase stack: Postgres 17, GoTrue v2.197, PostgREST v16, Storage API v1.82.1, Kong 2.8 and Mailpit. The final run was on commit `caff3e2`.

## 1. Commands and results

| Check | Command | Result |
|---|---|---|
| Format | `dart format --output=none --set-exit-if-changed lib test tool` | ✅ 116 files, 0 changed |
| Analyze | `flutter analyze` | ✅ No issues |
| Tokens | `dart run tool/gen_tokens.dart --check` | ✅ |
| Layer boundaries | `dart run tool/check_imports.dart` | ✅ 89 files |
| No physical left/right | `dart run tool/check_directional.dart` | ✅ 89 files |
| Flutter tests | `flutter test` | ✅ **217 passed** (185 unit/widget, 32 golden), 16 backend tests skipped |
| Flutter + real backend | `flutter test --coverage` with `SUPABASE_TEST_*` and `MAILPIT_TEST_URL` | ✅ **233 passed** |
| Real-backend only | `flutter test --tags backend` | ✅ **16 passed** (11 Phase 5 + 5 catalog) |
| Database | `supabase db reset && bash supabase/tests/run_db_tests.sh` | ✅ **224 assertions** in 7 suites |
| Coverage | `lcov.info` from the run with the backend | 84.5% of lines overall; `lib/features/catalog` 80.3% |
| Release compile | `flutter build web --release` in a scratch copy with web enabled | ✅ Built |
| Storage API smoke | curl with a real user JWT (see [C §4](c-security-and-authorization.md#4-tests-of-authorization-and-isolation)) | ✅ All eight expectations met |

## 2. Suites added or changed in Phase 6

| Suite | Count | Covers |
|---|---|---|
| `supabase/tests/database/05_catalog_rules` | 61 | Create, trim, default variant, initial stock movement, replay and key reuse, id conflict; validation of every field at once (prices integral, numeric, > 0; options ≤ 2; images ≤ 5; descriptions ≤ 2000; variants ≤ 100); option arity; duplicate combinations and SKUs (case-insensitive, store-wide); category spelling reuse; edit with versions; stock untouched by edits; price audit before and after; `VARIANT_IN_USE`; archive and restore of a combination; deleting variants that never had stock; archive, no-op repeat, no delete status; images (never uploaded, other product's, order, `removed_image_paths`); untracked with no stock; search (name, SKU, ك/ک, wildcards literal); filters, category, sort, paging; summary counts; currency lock; low-stock default |
| `06_inventory` | 32 | Add, remove, set; replay and key reuse; never negative with the current stock reported; no-change refused; `STOCK_CHANGED`; note for Other; joint validation; archived variants; untracked refused; history order, actor and paging; newest result = stock; Σ delta = stock; ledger immutable even for the owner; reconciliation detects drift |
| `07_catalog_isolation` | 32 | [C §4](c-security-and-authorization.md#4-tests-of-authorization-and-isolation) |
| `01_catalog_guards` | 12 (+3) | Reviewed api surface and helper grants, private JPEG ≤ 2 MiB bucket, no update policy, ledger trigger |
| `04_account_deletion` | 19 (+2) | The purge removes the catalog and ledger; outside the purge the ledger stays append-only |
| `test/catalog/catalog_domain_test.dart` | 20 | Contract parsing, stock states, error details, digit parsing, variant combinations (keep ids/SKUs, archive with history, back to default), draft validation keys, initial stock only for new tracked variants, preview math, **image pipeline: EXIF/GPS removed, 1:1, ≤ 1600 px, PNG→JPEG, > 10 MB refused**, path scoping |
| `test/catalog/catalog_screens_test.dart` | 23 | Empty catalog, rows and words, filters and debounced search (no request while typing), retry, tablet list–detail, validation, create (Eastern digits), options and combinations, photos including a failed upload, network retry with the same request, server field errors, unsaved guard, adjust/negative/reason/concurrent change/history, archive, untracked, foreign id, Today and checklist, store inventory setting, Sorani RTL, **200% text at 360×640 in both languages** |
| `test/backend/catalog_backend_test.dart` | 5 | Real upload and signed URL; replay; search and summary; stock add, stale and negative; **20 parallel removals of 1 from 5 → exactly 5 succeed**; image removal and deletion; tenant isolation including storage |
| Goldens | 32 (5 new `p6_*`) | Product list en/ckb/dark/320; detail ckb; editor with options; adjust sheet; tablet list–detail. The Today and products goldens were regenerated and reviewed. |

The Phase 4 sample-data product tests were removed with the sample repository. Phase 5 tests all still pass, including auth, session restore, protected navigation, onboarding, store settings and store isolation.

## 3. Failures found and fixed during the phase

| Found by | Problem | Fix |
|---|---|---|
| pgTAP (`05`) | Expected a variant error that can't occur with too many option types | Test expectation corrected |
| pgTAP (`05`) | Editing without a category correctly cleared it (the list is the full state); the test omitted it | Test sends the category |
| pgTAP (`04`) | The append-only check ran on an empty table (a row trigger doesn't fire) | The other seller now has stock history |
| Real backend | The idempotent replay test built a new SKU per call, and the server correctly refused the reused key | The test reuses the same draft |
| Widget tests | `Isolate.run` never completes in the fake-async test zone | Image preparation is an injectable provider; tests run the same pipeline synchronously |
| Golden review | List stock label sat mid-row; Latin names aligned left in Sorani; an empty full-width gallery box; chip delete icons rendered as boxes (no Material glyphs bundled); currency suffix misaligned; Apply misaligned; search hint truncated | All fixed and re-reviewed |
| 200% smoke test | Overflows: `SectionHeader` action (also the Phase 5 Today checklist in Sorani), combination header, "Set for all" row, Add photo tile | Fixed: actions shrink and wrap, rows wrap or stack |
| Directional check | `TextAlign.left/right` used to align seller text | Replaced with bidi isolates in the screen's direction |
| Analyzer | A literal U+2066 in a test (the editor tool turned an escape into the character) | Every `.dart` file scanned; escapes restored |

## 4. Not run, or not possible here

- **Android and iOS builds, and device runs:** no Android SDK or Xcode here. The camera, gallery, HEIC conversion, keystore and real image uploads from a device are **not verified on devices**. The picker plugin is not exercised by tests; a fake replaces it.
- **Upload progress percentages:** the Storage SDK reports none; tiles show an indeterminate ring.
- **Hosted Supabase:** none exists ([G §6](g-phase-6-completion-report.md#6-configuration-still-needed)).
- **The pg_cron schedules firing:** the jobs are created; the functions they call are tested directly.
- **Orphan purge worker:** not built ([D §5](d-image-storage.md#5-abandoned-objects-cleanup)).
- **Large catalogs:** paging and the trigram index are in place, but no load test with thousands of products was run.
