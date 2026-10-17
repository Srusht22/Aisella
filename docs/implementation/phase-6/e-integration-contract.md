# E. Integration contract for Phase 7 (orders) and Phase 8 (AI)

## 1. Read operations

All reads take the store id, are members-only, and return `NOT_FOUND` for foreign ids.

| Need | Use | Returns |
|---|---|---|
| Product details | `api.get_product(store, product)` | Product with all variants (including archived, flagged `status`) and images ([A §7](a-data-model.md#7-json-contract-returned-by-the-api-functions)) |
| Available variants | Same; select `status = 'active'` on both product and variant | `option_values`, `label`, `sku`, `price`, `stock_on_hand`, `available` |
| Is it sellable? | Product `status = 'active'` **and** variant `status = 'active'` **and** (tracked: `stock_on_hand ≥ qty`; untracked: `available`) | — |
| Authoritative price | Variant `price` (= `price_override` ?? `base_price`) in the store currency (`api.stores.currency`) | Integer |
| Catalog search / candidates | `api.list_products(store, query, filter, category, sort, limit ≤ 50, offset)` | Items with `price_min/max`, `variant_count`, `stock_total`, `low_count`, `out_count`, `stock_state`, `image_path`; `total`, `has_more` |
| Counts | `api.catalog_summary(store)` | `total`, `all`, `low`, `out`, `inactive`, `archived`, `categories[]`, `low_stock_default` |
| Stock history | `api.list_inventory_movements(store, product, variant?, limit ≤ 100, before_id?)` | Movements newest first, `has_more` |

**Phase 8 (AI)** must read only active products and variants of the conversation's store (BR-10). It must take prices and availability from these values, never from model output (BR-11, Phase 1 §8.7). Archived and inactive products are excluded from answers. Exact counts aren't revealed by default (D-11): use the stock state.

## 2. Stock changes from orders (Phase 7)

Phase 7 must change stock **only inside its own `api.*` order functions**, in the same transaction as the order status change. It must follow these rules:

1. **Lock** every affected variant with `SELECT … FOR UPDATE` **in ascending variant id order**, the same order `upsert_product` uses.
2. **Re-validate at that moment:** product and variant active, the product still tracks stock, `stock_on_hand ≥ qty`, and the quoted price against the current price (BR-21, BR-23). A displayed or cached stock value is never proof of availability.
3. **For each tracked line:**
   - update `stock_on_hand` and insert an `inventory_movements` row with `delta`, the new `resulting_qty`, reason `order_approved`, `order_edited`, `order_cancelled` or `order_returned_restock`, and `actor_user_id`;
   - add an `order_id` column with a composite FK `(store_id, order_id)` in the Phase 7 migration.
4. **Never** move stock for untracked products or test orders (BR-50), never go below zero (the CHECK is a backstop, not the check), and never update or delete movements.
5. **Idempotency:** approval and every other stock-moving order call take an idempotency key, and the status transition prevents a second deduction.
6. **Archiving:** a product or variant referenced by any order must never be hard-deleted. `upsert_product` already refuses to delete variants with history; Phase 7 must extend that check to "referenced by an order line" once order lines exist.

The reasons for these movements already exist in the CHECK constraint. `adjust_stock` doesn't accept them, so only order functions can write them.

## 3. Invariants Phase 7 must keep

- Σ `inventory_movements.delta` = `product_variants.stock_on_hand` for every variant. The nightly reconciliation reports drift.
- `stock_on_hand` is between 0 and 1,000,000. Movements are append-only.
- A product has at least one active variant while it's sellable. Combinations are unique per product, and SKUs are unique per store.
- Prices are positive integers in the store currency. The store currency is fixed once products exist.
- Every catalog or stock write is audited, and authorized for the store in the request.

## 4. Not provided in Phase 6

Reservations or holds, backorders, inventory transfers or locations, purchase orders, bulk import, product duplication, discounts. None of these is in the P0 catalog scope.
