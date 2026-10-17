# H. Phase 7 completion report

**Phase:** 7. Order management, order drafts, seller approval and the order lifecycle.
**Status:** Complete. **Waiting for owner approval. Phase 8 has not started.**
**Branch:** `S.H_Branch`.

## 1. Summary
Phase 7 replaces the Phase 4 sample-data draft preview with a real, persisted order system on the existing Supabase architecture.

| Area | Delivered |
|---|---|
| Orders | Manual orders with a customer snapshot, delivery zone or another place, fee from the zone or the seller, cash on delivery or other, discount, notes. Numbers per store from #1001. Server-computed prices, snapshots, totals and status |
| Drafts | Saved as draft or needs approval by the server from BR-36 completeness; re-evaluated after every edit; never approved by saving |
| Approval gate | Owner-only, end-user, confirmed email, from pending only. Re-validation under locks (availability, stock, price with explicit choice); all or nothing; idempotent; races serialize; confirmation sheet with input guard |
| Lifecycle | Reject, approve, preparing, out for delivery, delivered with cash, delivery failed, try again, returned (restock or write-off per line), cancel. Exactly the BR-30 transitions, enforced by a trigger on every write |
| Inventory | Deduct at approval, difference on approved edits, restore on cancel and restocking returns. Order-linked ledger rows; held units per line; reconciliation of both invariants |
| History | One status event per change; audit before/after for edits; history screen; stock history names the order |
| Screens | OR-01 list (search, chips with counts, grouped by day, paging, tablet list–detail); OR-02 review; OR-03 approval sheet; OR-04 reject; OR-05 detail with tracker; OR-06 editor; OR-07 picker; OR-08 status sheets; OR-09 cancel; OR-10 confirmation copy; OR-11 history; Today from real orders |
| Quality | 413 database assertions; 278 Flutter tests with the backend (21 against the real stack); 42 reviewed goldens; 200% text in both languages; release compile |

Nothing was deployed. No message is sent to customers. No AI, channel, delivery-provider, billing or analytics integration was added.

## 2. Architecture reused
| What | How |
|---|---|
| Backend | Same `app`/`api`/`internal` schemas, definer functions, envelope, idempotency keys, optimistic versions and audit as Phases 5–6. Stock on Phase 6's variants and ledger. No new infrastructure |
| Client | Flutter, Riverpod 3, go_router, the Phase 4 design system. The orders feature has domain / data / application / presentation layers like the catalog |
| New dependencies | None |

## 3. Commits
| Commit | Message | Pushed |
|---|---|---|
| `e5f37c3` | feat(orders): order schema, lifecycle guard, owner-only approval with atomic stock | ✅ verified |
| `570d1d2` | feat(orders): order domain, repository, providers and real-backend tests | ✅ verified |
| `7b8281e` | feat(orders): order list, review, approval, fulfilment, editor, picker and history screens | ✅ verified |
| `08ffa40` | test(orders): order screen flows, approval gate, failures and RTL | ✅ verified |
| *(this commit)* | docs(phase-7): data model, lifecycle, approval security, inventory, audit, integration contract, test report and completion report | reported in the hand-off |

Each commit was validated, pushed with `git push -u origin S.H_Branch`, and verified by `git fetch` plus a local-versus-remote hash comparison.

## 4. Files
- **Backend:**
  - new `supabase/migrations/20261017150000_orders.sql` and `20261017160000_order_today.sql`;
  - new tests `08_order_rules`, `09_order_approval`, `10_order_isolation`;
  - updated `01_catalog_guards` and `04_account_deletion`.
- **Orders feature:**
  - `lib/features/orders/domain/{order, order_draft}.dart`;
  - `data/orders_repository.dart`;
  - `application/order_providers.dart`;
  - `presentation/{orders_screen, order_detail_screen, order_sheets, order_editor_screen, product_picker_sheet, order_history_screen, order_widgets, order_text}.dart`.
- **Removed:** the Phase 4 preview (`orders_home_screen`, `draft_review_preview_screen`, `approve_sheet`, `sample_draft`), its route, strings and goldens.
- **Changed:**
  - `lib/app/{router, route_guard}.dart` (order routes);
  - `lib/core/backend/api.dart` (order error codes, details);
  - `lib/design_system/components/inputs.dart` (search autofocus);
  - `lib/features/catalog/{domain/catalog, presentation/inventory_history_screen}.dart` (order number in stock history);
  - `lib/features/today/**` (real counts);
  - `lib/l10n/app_{en,ckb}.arb` (185 new keys, 14 removed; 639 per language).
- **Tests:**
  - `test/orders/{order_domain_test, order_screens_test}.dart`;
  - `test/backend/orders_backend_test.dart`;
  - `test/helpers/{order_fakes, catalog_fakes, test_app}.dart`;
  - navigation, route guard, responsive, screens and golden tests updated;
  - 15 new goldens.
- **Docs:** `docs/implementation/phase-7/*`.

## 5. Known limitations
| Limitation | Impact | Next step |
|---|---|---|
| No device builds or runs (no Android SDK or Xcode) | Sheets, clipboard and keyboard behaviour are verified only in widget tests | Device checklist before the pilot |
| No customer records (CU-01…CU-03) | Each order has its own customer snapshot; no phone match or reuse; "View customer" isn't offered | Customers with Phase 8 or later (P7-D1) |
| No connectivity indicator (P-OFFLINE) | Offline actions fail with "Couldn't reach Aisellia. Check your connection and try again." instead of being disabled beforehand | Add a connectivity provider app-wide |
| After dispatch only the internal note is editable; delivery details can't be corrected for a re-attempt (BR-33 allows it) | The seller notes corrections in the courier or internal note | Small `api` addition if pilots need it |
| Returns decide whole lines (restock or write off); the API supports split quantities | A line of 3 with 1 damaged needs the API | Per-unit split in the sheet |
| Line prices come only from the catalog; there is no manual price per line (BR-33 lists prices as editable) | Price changes go through the discount or the catalog | P7-D4 |
| The confirmation text is composed on the device and its wording is fixed | — | AI-written replies in Phase 8 |
| Reporting beyond Today (`v_summary` for a date range) not built | — | Reporting phase |
| An action bar with a very long secondary label can squeeze the primary on narrow screens (seen only with the test font) | Real fonts render well (goldens, 200%) | Watch in the native review |
| Sorani strings are machine-drafted (DD-04) | Wording quality | Native review |
| Offset paging, no load test | Fine for the expected volume | Keyset paging if needed |

## 6. Decisions needing owner sign-off
| ID | Decision | Recommendation |
|---|---|---|
| **P7-D1** | Customer data is a snapshot on the order; no customers table yet | Accept for the pilot |
| **P7-D2** | Customer phones must be Iraqi mobiles (E.164 `+9647…`), like the store phone | Accept; widen if foreign numbers appear |
| **P7-D3** | Approval is **owner-only** in P0; a staff member with an approve permission is still refused | Accept (BR-30 "Owner only") |
| **P7-D4** | Line prices always come from the catalog (quoted, then approved); there is no free-typed unit price; adjustments go through the order discount | Accept |
| **P7-D5** | Order numbers start at #1001 per store | Accept |
| **P7-D6** | "Today" figures use the Asia/Baghdad calendar day | Accept |
| **P7-D7** | Reasons: reject (changed mind, not a real order, duplicate, out of stock, can't deliver, other); cancel (customer cancelled, out of stock, can't deliver, duplicate, other); delivery failed (unreachable, refused, wrong address, other). "Other" needs a note | Accept or edit the lists |
| **P7-D8** | Written-off returned units stay out of stock (no movement); restocked units come back with a movement | Accept (Phase 3 §6.3) |
| **P7-D9** | The Test filter is hidden until sandbox conversations exist | Accept |
| Carried over | P6-D1…P6-D5, P5-D1…P5-D3; D-xx, DD-xx, AD-xx (especially AD-10 and DD-04) | Still pending |

## 7. Configuration still needed
All of this needs authorization:
- the hosted project from Phase 5 H §4;
- `supabase db push` of both new migrations;
- a check that the nightly reconciliation job reports order invariants (it calls the same `check_inventory_reconciliation`).

No secrets or service keys are involved in the app.

## 8. Recommended next steps before Phase 8
1. Owner review of Phase 7 and decisions P7-D1…P7-D9 (and the open Phase 5–6 decisions).
2. Device test on Android and iOS: create, approve (double tap, slow network), fulfil, cancel, return, copy confirmation; a large order list.
3. Native Sorani review of the order strings and the confirmation message.
4. When the hosted staging project is authorized: push the migrations and run the database suites against a staging copy.
5. Phase 8 must follow [F](f-integration-contract.md): drafts only, a dedicated AI draft function with provenance and "seller edits win", no approval path, prices from the catalog.

**Phase 8 will not start until you explicitly authorize it.**
