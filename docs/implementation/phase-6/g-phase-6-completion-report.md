# G. Phase 6 completion report

**Phase:** 6. Product catalog, variants, image management and inventory.
**Status:** Complete. **Waiting for owner approval. Phase 7 has not started.**
**Branch:** `S.H_Branch`.

## 1. Summary

Phase 6 replaces the Phase 4 sample-data product screens with a real, persisted catalog. Everything is store-scoped in Postgres and Supabase Storage, and enforced by the database, not the app.

| Area | Delivered |
|---|---|
| Products | Create, edit, archive, restore, make inactive. Name, description, category, integer price in the store currency, active switch. |
| Variants | Up to 2 option types and 100 combinations, generated from option values. Per-variant price override, SKU (unique per store) and stock. Variants with history are archived, never deleted. |
| Images | Up to 5 per product, from the camera or gallery. Cropped 1:1, ≤ 1600 px, re-encoded without metadata. Private bucket, signed URLs. Per-photo upload state with retry; set as main, replace, remove; unsaved uploads cleaned up. |
| Inventory | Stock per variant, or "do not track" with availability. Add / remove / set with reasons. Append-only ledger with history, never negative, row-locked, idempotent. Detects concurrent changes. Nightly reconciliation. |
| Low stock | Store default (3, editable) with per-product/variant override. Low and out states in words, icon and color. Same count on the list chips and on Today. |
| Catalog | Debounced, normalized search over name, category, options and SKU (Arabic and Kurdish letter variants, Eastern digits). Filters All / Low / Out / Inactive / Archived; category; five sorts; paging; tablet list–detail. |
| Quality | 224 database assertions, 233 Flutter tests with the backend (16 against the real stack), 32 reviewed goldens, 200% text in both languages, release compile |

## 2. Architecture reused

| What | How |
|---|---|
| Backend | Supabase: Postgres, PostgREST `api` schema, Storage, pg_cron, pg_trgm. Same conventions as Phase 5: `app`/`api`/`internal` schemas, definer functions, envelope, idempotency keys, optimistic versions, audit. |
| Client | Flutter with Riverpod 3 and go_router, and the Phase 4 design system |
| New dependencies | `image_picker` 1.2.4 (flutter.dev) and `image` 4.12.0 (pure Dart). No other services. |

## 3. Commits

| Commit | Message | Pushed |
|---|---|---|
| `7df6312` | feat(catalog): product, variant, image and inventory schema with store-scoped access | ✅ verified |
| `701ab16` | feat(catalog): catalog data layer, image pipeline and real-backend tests | ✅ verified |
| `701204c` | feat(catalog): product list, detail, editor, variants, stock and history screens | ✅ verified |
| `caff3e2` | test(catalog): 200% text on small phones in both languages; fix overflows | ✅ verified |
| *(this commit)* | docs(phase-6): data model, inventory rules, security, image storage, integration contract, test report and completion report | reported in the hand-off |

Each commit was validated before it was pushed with `git push -u origin S.H_Branch`, and verified by `git fetch` plus a local-versus-remote hash comparison.

## 4. Files

About 66 files changed since Phase 5 (`673fefd`), before these docs.

- **Backend:**
  - new `supabase/migrations/20261017090000_catalog_inventory.sql`;
  - `supabase/config.toml` (storage on, S3 off);
  - new `supabase/tests/database/05_catalog_rules`, `06_inventory`, `07_catalog_isolation`;
  - updated `01_catalog_guards` and `04_account_deletion`.
- **Catalog feature (new):**
  - `lib/features/catalog/domain/{catalog, product_draft}.dart`;
  - `data/{catalog_repository, media_store}.dart`;
  - `application/catalog_providers.dart`;
  - `presentation/{product_list_screen, product_detail_screen, product_editor_screen, adjust_stock_sheet, inventory_history_screen, image_viewer_screen, catalog_widgets, catalog_text}.dart`.
- **Removed:** `lib/features/products/**` (the Phase 4 sample repository and screen).
- **Changed:**
  - `lib/app/{router, route_guard}.dart` (product routes, `/store/inventory`);
  - `lib/core/backend/api.dart` (catalog error codes, details);
  - `lib/core/formatting/dates.dart` (`time`);
  - `lib/features/store/domain/store.dart` (`lowStockDefault`);
  - `lib/features/settings/{store_menu_screen, store_settings_screens}.dart` (Inventory setting);
  - `lib/features/today/**` (real "first product", real low-stock row; sample low stock removed);
  - `lib/features/common/top_level_page.dart` (pull to refresh);
  - `lib/design_system/components/rows.dart` (section header actions wrap);
  - `lib/l10n/app_{en,ckb}.arb` (166 new keys; 467 per language; two texts updated);
  - `pubspec.yaml` and `pubspec.lock`;
  - `ios/Runner/Info.plist` (camera and photo usage).
- **Tests:**
  - `test/catalog/{catalog_domain_test, catalog_screens_test}.dart`;
  - `test/backend/{catalog_backend_test, backend_support}.dart`;
  - `test/helpers/{catalog_fakes, test_app, fakes}.dart`;
  - goldens.
- **Docs:** `docs/implementation/phase-6/*`.

## 5. Known limitations

| Limitation | Impact | Next step |
|---|---|---|
| No device builds or runs (no Android SDK or Xcode) | Camera, gallery, HEIC conversion and real uploads from a phone are unverified | Device checklist before the pilot |
| Orphaned-media purge worker not built (needs a deployed Edge Function with the service role) | Abandoned uploads can accumulate; `internal.orphaned_media()` lists them | Build with the hosted project (ADR-008) |
| No manual crop adjuster; photos are centre-cropped (PR-07 asks for an adjuster) | Off-centre subjects may be cut | Add a crop UI if pilot sellers need it |
| Photos reorder by "Set as main" only, not drag | Fewer gestures than PR-03 | Drag reorder later |
| Per-variant low-stock thresholds: API only; the editor sets one value for all variants | Fine-grained thresholds need the API | Add to the combination rows if needed |
| No product duplication ("P0-lite" in Phase 1) and no "Used in orders" count (no orders yet) | — | Duplication when requested; the count in Phase 7 |
| Upload progress is indeterminate | — | SDK limitation |
| Sorani strings are machine-drafted (DD-04); iOS permission texts are English only | Wording quality | Native review; localized `InfoPlist.strings` |
| Offset paging (≤ 50 per page) and no load test | Fine for the expected hundreds of products | Keyset paging if catalogs grow large |
| The account purge removes catalog rows; storage objects then become orphans for the worker above | Objects remain until the worker exists | Same as the worker |

## 6. Configuration still needed

All of this needs authorization:
- the hosted project from Phase 5 H §4;
- `supabase db push` of the new migration, then a check that `store-media` is private, JPEG-only and 2 MiB, and that both pg_cron jobs exist;
- deploy the orphan-cleanup worker;
- localized iOS permission strings.

## 7. Decisions needing owner sign-off

| ID | Decision | Recommendation |
|---|---|---|
| **P6-D1** | Free-text categories with suggestions and spelling reuse; no category table | Accept (matches Phase 1 "free or chosen") |
| **P6-D2** | Store default low-stock threshold = **3**, editable in Store → Inventory, overridable per product or variant | Accept; adjust after the pilot |
| **P6-D3** | The store currency is locked once any product exists (prices are never converted) | Accept |
| **P6-D4** | Images are centre-cropped automatically; the crop adjuster and drag reorder are deferred | Accept for the pilot |
| P6-D5 | Turning options on for a product with stock archives the old default variant; the seller enters new per-option stock | Accept (no silent re-allocation of units) |
| Carried over | P5-D1…P5-D3; D-xx, DD-xx, AD-xx (especially AD-10 and DD-04) | Still pending |

## 8. Recommended next steps before Phase 7

1. Owner review of Phase 6 and decisions P6-D1…P6-D5 (and the open Phase 5 decisions).
2. Device test on Android and iOS: pick and take photos, upload on a slow network, retry, HEIC, a large catalog list.
3. Native Sorani review of the catalog strings.
4. When the hosted staging project is authorized: push the migrations, deploy the orphan-cleanup worker, and verify the bucket settings.
5. Phase 7 must follow [E](e-integration-contract.md): lock order, re-validation at approval, ledger reasons, the `order_id` column, and the "referenced by an order" archive rule.

**Phase 7 will not start until you explicitly authorize it.**
