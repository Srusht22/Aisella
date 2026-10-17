# B. Inventory rules

## 1. Tracking modes (per product)

| Mode | Meaning | Stock | Shown as |
|---|---|---|---|
| **Track stock** (default) | Units are counted per variant | `stock_on_hand` ≥ 0, changed only through the ledger | "12 in stock", "Low · 2 left", "Out of stock" |
| **Do not track** (BR-16) | Made-to-order, decants, services | Not counted; adjustments are refused (`STOCK_NOT_TRACKED`); initial stock is ignored | "Available" or "Unavailable", from each variant's `available` switch |

Switching a product from tracked to untracked leaves the balance and history untouched; they're simply not used. Switching back shows the old balance, which the seller can then correct with an adjustment.

## 2. Where stock can change

| Path | Effect | Function |
|---|---|---|
| Creating a tracked variant with an initial quantity | +qty, reason `initial_stock` | `api.upsert_product` (new variants only) |
| Manual adjustment | add, remove or set, with a reason | `api.adjust_stock` |
| Orders (Phase 7) | approve, edit, cancel, return | Future `api.*` order functions (§E) |

**Nothing else changes stock:**
- editing a product never touches the stock of existing variants (an `initial_stock` sent for them is ignored, and a test proves it);
- the client has no write privilege on any table;
- `stock_on_hand` has a CHECK of 0 … 1,000,000.

## 3. Adjustment semantics (`api.adjust_stock`)

| Input | Rule |
|---|---|
| `mode` | `add`: +q (q ≥ 1). `remove`: −q (q ≥ 1). `set`: result = q (q ≥ 0); the movement records the difference. |
| `quantity` | Integer 0…1,000,000. Zero only for `set`. |
| `reason` | `received`, `sold_in_shop`, `damaged`, `count_correction` or `other` (PR-05 chips). `other` requires a note. "Lost" and "returned to stock by hand" are recorded as `other` with a note. |
| `expected_stock` | Optional: the number the seller saw. If it differs from the current stock, the answer is **`STOCK_CHANGED`** with `current_stock`, and nothing changes. The app always sends it. |
| `idempotency_key` | Required. The same key with the same request replays the first result; with a different request it is refused (`IDEMPOTENCY_KEY_REUSED`). |

Results:

| Outcome | Answer |
|---|---|
| Result below 0 | **`INSUFFICIENT_STOCK`** with `current_stock` (BR-14) |
| Result equals current stock | Validation error `quantity: no_change` (no empty movements) |
| Archived variant | Validation error `variant: archived` |
| Untracked product | **`STOCK_NOT_TRACKED`** |
| Success | Returns `previous_stock`, `stock_on_hand` and the movement. The audit event `stock.adjust` is written in the same transaction. |

## 4. The ledger

- `inventory_movements` is **append-only** (BR-64). A trigger refuses UPDATE and DELETE even for the database owner, except inside the account-purge transaction.
- Every movement stores `delta`, `resulting_qty`, `reason`, `note`, `actor_user_id` and `created_at` (BR-15).
- **Invariant:** for every variant, Σ `delta` = `stock_on_hand`.
  - `internal.inventory_mismatches()` lists any variant that breaks it.
  - `internal.check_inventory_reconciliation()` logs a warning with the count. It runs nightly at 02:41 UTC through pg_cron (`aisellia-inventory-reconciliation`).
  - A test changes a balance behind the ledger's back and shows that the check detects it.
- **History (PR-06):** `api.list_inventory_movements` returns movements newest first, paged by movement id, optionally for one variant. Each carries the variant label and who made it ("You", "Team member" or "Aisellia"). The newest entry's `resulting_qty` equals the current stock (US-017, tested).

## 5. Concurrency

- `adjust_stock` locks the variant row (`SELECT … FOR UPDATE`) before reading the balance. Concurrent adjustments therefore run one after another, and each sees the previous result. There is no read-then-write race.
- `upsert_product` locks the product row, then its variants **in id order**. That's the same order Phase 7's approval must use, to avoid deadlocks (Phase 3 §5).
- **Measured:** 20 parallel "remove 1" requests on a stock of 5 through the real PostgREST gave **exactly 5 successes and 15 `INSUFFICIENT_STOCK`**. Final stock was 0 and the sum of movements matched (`test/backend/catalog_backend_test.dart`).
- **Stale screens:** the adjust sheet sends the stock it showed. A change made elsewhere returns `STOCK_CHANGED`; the sheet then shows "Stock changed to 10 while you were editing" and recalculates its preview. It never overwrites the other change.
- **Lost answers:** a timeout is retried once with the same idempotency key, so the server replays the first result instead of applying the change twice. Further retries by the seller reuse the same key while the request is unchanged.

## 6. Low stock and out of stock (BR-18)

- **Threshold:** the variant's own `low_stock_threshold`, or else the store's `low_stock_default`, which defaults to **3** (decision P6-D2). Sellers change the store default in Store → Inventory, and a product's threshold in its editor (one value applied to all its variants). The API accepts a different threshold per variant.
- **Variant state:** out when stock = 0; low when 0 < stock ≤ threshold; otherwise in stock. A threshold of 0 means the variant is never "low". Untracked variants are available or unavailable.
- **Product state** (list row, filters, Today):

| State | Rule |
|---|---|
| `out` | Every active variant has 0 |
| `low` | At least one active variant is at or below its threshold (including some, but not all, at 0) |
| `in` | Otherwise |
| `available` / `unavailable` | Untracked: available if any active variant is available |

- **Filters:**
  - *Low stock* = `low`;
  - *Out of stock* = `out` plus untracked `unavailable`;
  - archived products are excluded from both.
- Today's "Low or out of stock" uses the same summary, so the two counts always match (PR-01 #19).
- **Display:** text plus icon plus color, never color alone. "Low · 2 left" uses the warning color with a trend-down icon; "Out of stock" uses danger with a prohibit icon; in stock is calm secondary text (Phase 2 §2.4). Multi-option products summarize, for example "2 options low".

## 7. Variants and stock together

- **No double counting:** stock exists only on variants. The product-level numbers are sums over **active** variants.
- **Removing a variant** with stock or history is refused (`VARIANT_IN_USE` with the ids). The editor offers "Archive this option" instead; an archived variant keeps its stock and history but is excluded from totals, states and adjustments.
- **Re-adding an archived combination** restores the same variant, so its history stays continuous.
- **Turning options on** for a product whose default variant has history archives that default variant. Its units don't silently move to the new variants: the seller adjusts the new variants explicitly. Each new variant carries its own initial stock.
