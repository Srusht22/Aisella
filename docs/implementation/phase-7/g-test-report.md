# G. Test report

All results below were produced in this environment on 2026-10-17, against the **local** Supabase stack: Postgres 17, GoTrue, PostgREST, Storage API, Kong and Mailpit. The final run was on commit `08ffa40` plus these docs.

## 1. Commands and results
| Check | Command | Result |
|---|---|---|
| Format | `dart format --output=none --set-exit-if-changed lib test tool` | ✅ 128 files, 0 changed |
| Analyze | `flutter analyze` | ✅ No issues |
| Tokens | `dart run tool/gen_tokens.dart --check` | ✅ |
| Layer boundaries | `dart run tool/check_imports.dart` | ✅ 97 files |
| No physical left/right | `dart run tool/check_directional.dart` | ✅ 97 files |
| Flutter tests | `flutter test` | ✅ **257 passed** (including 42 goldens), 21 backend tests skipped |
| Flutter + real backend | `flutter test --coverage` with `SUPABASE_TEST_*` and `MAILPIT_TEST_URL` | ✅ **278 passed** |
| Real-backend only | `flutter test --tags backend` | ✅ **21 passed** (11 Phase 5, 5 catalog, 5 orders) |
| Database | `supabase db reset && bash supabase/tests/run_db_tests.sh` | ✅ **413 assertions** in 10 suites |
| Coverage | `lcov.info` from the run with the backend | 82.9% of lines overall; `lib/features/orders` 85.7% |
| Release compile | `flutter build web --release` in a scratch copy with web enabled | ✅ Built |

## 2. Suites added or changed in Phase 7
| Suite | Count | Covers |
|---|---|---|
| `08_order_rules` | 60 | Manual order is pending, never approved; numbering; server totals; snapshots; one creation event; no stock at creation; replay and key reuse; drafts and their issues; **status/total/approver/store/price from the client refused**; joint validation (phone, fee, discount, payment, quantity 1–999); unknown, duplicate, archived and inactive variants; discount ≤ subtotal; disabled payment method; zone and seller fees; draft ↔ pending re-evaluation as a system event; quoted price kept after a catalog change; versions; audit before/after; zone snapshot survives renames; reject with reason, terminal; summary = list totals; search by name, phone (any form), number (Eastern digits), product, SKU; history; **storage guards** (direct writes refused, privileged writes outside BR-30 refused, approved without approver impossible, no insert as approved, history append-only, orders never deleted, ordered variant never deleted) |
| `09_order_approval` | 92 | **Gate:** anon and service_role cannot execute, a service_role token is refused, staff with an approve permission refused, unconfirmed email refused. **Approval:** deduction, recorded stock change, movement linked to the order, untracked lines untouched, approved prices, cash due, currency lock, event, replay without a second deduction, second device → `INVALID_TRANSITION`. **Refusals:** draft, stale version, short stock, one short line blocks all, inactive product, unavailable untracked item, price changed with explicit choice (quoted or current), invalid choices. **Fulfilment:** no jumps, no generic set-status, preparing, dispatch with courier, no cancel/edit after dispatch, failure reason, retry, delivered with cash ≤ due, problems count, terminal delivered, record cash ≤ outstanding, no stock moves. **Returns:** every line decided, restock movement, write-off without movement, terminal. **Cancel:** reason, restock once, replay, terminal. **Approved edits:** increase, decrease, new line at current price, refused increase, must stay complete, discount and cash due, removed line restocked, kept price, audit. **Confirmation and notes.** **Today figures.** **Invariants:** stock = ledger; held = order movements |
| `10_order_isolation` | 30 | Two sellers: all 12 order functions `NOT_FOUND` via either store id, for approved and pending orders; list, count and search; create in another store; another store's product or zone; numbering per store; RLS on orders, lines, history and order movements; direct writes refused; transition table hidden; A unchanged; anon refused |
| `01_catalog_guards` | 17 (+5) | Reviewed api surface (+15 functions); history and transition triggers; exactly 15 transitions; approved only from pending through approve |
| `04_account_deletion` | 21 (+2) | The purge removes orders, lines and history; outside the purge order history stays append-only |
| `test/orders/order_domain_test.dart` | 10 | Contract parsing, approval readiness (issues, short, unavailable, untracked), price changes, status groups, order error codes and details, **draft sends documented fields only**, Eastern-digit phone normalization, line merge and 1–999 bounds, client checks match the server, held units, canonical key |
| `test/orders/order_screens_test.dart` | 23 | See [§3](#3-what-the-widget-tests-prove) |
| `test/backend/orders_backend_test.dart` | 5 | Lifecycle with replay and a second device, history, counts and phone search; **6 orders for 3 units → exactly 3 approvals**; **8 simultaneous approvals → 1, stock deducted once; 5 simultaneous cancels → restocked once**; client-decided values refused; seller isolation through PostgREST |
| Goldens | 42 (15 new `p7_*`, 6 preview shots removed) | Review en/ckb light/dark, full length, 200% Sorani; list en and ckb dark; draft with missing details; approved ckb (RTL tracker); delivered with cash due; approval sheet; new-order editor; history ckb; tablet list–detail; Today from real orders |
| Updated | — | Navigation (orders stack), route guard (order routes), 200% text through list → review → approval sheet in both languages, Today without sample data |

## 3. What the widget tests prove
- **List.** Empty state; one-sentence semantics; filter and debounced search sent to the server; load failure with Retry; tablet list–detail.
- **Approval gate:**
  - a draft's Approve is disabled with the reason, and the missing fields are listed;
  - approval goes only through the sheet, which ignores early taps, makes **one call for a double tap**, and shows the stock change as recorded;
  - Back approves nothing;
  - a changed price needs an explicit choice, and the total follows it;
  - stock gone meanwhile → refused, nothing changes;
  - approved on another device → reported, deducted once;
  - a timeout → one replay with the same key, one approval.
- **Reject.** The reason is required, and a note for Other; no stock change.
- **Fulfilment.** Preparing → dispatch with courier → delivered with partial cash typed in Eastern digits → record the rest. Cancel restocks once. Delivery failed → return with no default decision. The confirmation is copied and never shown as "Sent"; "I sent this" is recorded.
- **Editor:**
  - a new order through the picker (the out-of-stock option is disabled) is saved as needs approval, never approved;
  - an invalid phone is shown on the field and nothing is sent;
  - an approved edit previews and applies the stock difference;
  - an order after dispatch can't be edited.
- **History, access and language.** History lists status changes; another store's id shows "unavailable"; the Sorani review is RTL with Western-digit numbers.

## 4. Failures found and fixed during the phase
| Found by | Problem | Fix |
|---|---|---|
| pgTAP `08` | Creating an order failed the total CHECK: the header was written before the totals | Discount, fee and totals are written in one statement (`order_recompute` with the header's money) |
| pgTAP `08` | Same-transaction rows had equal timestamps, so list and history order were unstable | List sorted by time then number; history puts an edit before the status change it caused |
| pgTAP `09` | `stock_after`, `restocked` and `stock_diff` had two elements per line (`array ‖ object ‖ object`) | Parenthesized as `array ‖ (object ‖ object)` |
| pgTAP `09` | Order movements ≠ held units after a write-off | Written-off units stay held (`stock_deducted − restocked`); invariant documented in [D §2](d-inventory-integration.md#2-stock_deducted-what-a-line-holds) |
| pgTAP `09` | Approved edit decreasing a quantity broke `stock_deducted ≤ quantity` mid-update | Quantity and held units are written in one statement |
| Real backend | Isolation test created futures eagerly; errors surfaced unhandled | Calls wrapped in closures |
| Widget tests | Wide test font squeezed the action bar; snackbars covered it | Order tests load the real fonts and dismiss snackbars before tapping |
| Golden review | "Still missing: Customer name is missing, …" repeated "is missing"; the fee row said "Delivery"; tracker labels touched | Short field names; "Delivery fee"; label spacing |
| Boundary check | The Phase 4 preview imported `orders/data` once orders had an application layer | Preview removed; real screens use the application layer |

## 5. Not run, or not possible here
- **Android and iOS builds and device runs** (no Android SDK or Xcode). Clipboard and sheet behaviour on devices are unverified.
- **Hosted Supabase:** none exists, so the migrations ran only locally.
- **Offline indicator:** the app has no connectivity provider (Phases 5–6 neither). Offline is detected when an action fails (`errNetwork`); actions are not pre-disabled ([H §5](h-phase-7-completion-report.md#5-known-limitations)).
- **Load test:** no test with thousands of orders. Offset paging (≤ 50) and indexes are in place.
- **Native Sorani review** of the 185 new strings.
