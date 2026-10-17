# D. Inventory integration

Phase 7 follows the [Phase 6 integration contract](../phase-6/e-integration-contract.md). Stock moves only inside the order functions, in the same transaction as the status change, with ledger rows that name the order. There is no new inventory system: orders use Phase 6's `product_variants.stock_on_hand` and the append-only `inventory_movements`.

## 1. When stock moves (Phase 3 §6.3)
| Event | Stock effect | Movement reason |
|---|---|---|
| Draft created or edited | None (BR-20; no reservations in P0) | — |
| Approve | −quantity per tracked line, all or nothing | `order_approved` |
| Edit before dispatch | The difference: increases checked and deducted, decreases restored | `order_edited` |
| Cancel (approved, processing) | Everything the lines hold comes back | `order_cancelled` |
| Preparing, dispatch, delivered, delivery failed | None | — |
| Returned | Per line: restocked units come back; written-off units don't | `order_returned_restock` |
| Untracked product or test order | Never | — |

## 2. `stock_deducted`: what a line holds
Each line records how many units it currently holds from stock:
- approval sets it to the quantity (tracked lines);
- an approved edit moves stock by `old − new`;
- cancel restores it and sets it to 0;
- a return restores the restocked units and keeps the written-off ones held (they are gone).

Invariant, checked by `internal.order_stock_mismatches()` and asserted in `09`: for every order and variant, Σ order movements = −Σ `stock_deducted`. Phase 6's invariant also holds (stock = Σ movements per variant). The nightly `check_inventory_reconciliation` now reports both.

Consequences:
- **No double deduction.** Approval is guarded by the status lock, the transition table and the idempotency key.
- **No double restock.** Cancelled and returned are terminal, and `return_lines` is unique per item.
- **Never negative.** Every decrease is checked under the variant lock. The CHECK is a backstop.
- **Tracking switched off later.** If a product stops tracking stock after approval, the units already taken stay held until the line is removed, cancelled or returned. Units are never invented.

## 3. Locks
- Order functions lock the order row first.
- They then lock products (`FOR SHARE`) and variants (`FOR UPDATE`), each in **ascending id order**. This is the same order `upsert_product` and `adjust_stock` use, so concurrent catalog edits, stock adjustments and approvals serialize without deadlocks.
- A displayed stock value is never proof: the review screen shows live stock and short lines, but the server checks again under the locks.

## 4. Visible to the seller
- The review shows "10 in stock", "Only 1 in stock" or "No longer sold" per line. Approve is disabled with a reason while a line can't be sold.
- The approval sheet shows "Stock after approval: Black Abaya: 10 → 8". After success the snackbar repeats the change the server actually recorded.
- The approved-order editor shows "Stock on save: −1" per changed line and reports "stock changed for N items" after saving.
- The inventory history of a product names the order: "Order approved · Order #1042".

## 5. Catalog rules extended
- A variant referenced by any order line is never deleted. `upsert_product` answers `VARIANT_IN_USE`, so the seller archives it instead (BR-17).
- The first approval locks the store currency (`currency_locked_at`). Products already lock it since Phase 6.
- New lines must be active and sellable. Lines kept from before may have become unavailable: the review flags them and approval refuses them (`LINE_UNAVAILABLE`).
