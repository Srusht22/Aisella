# A. Data model

Migrations:
- `supabase/migrations/20261017150000_orders.sql`: tables, guards, functions;
- `supabase/migrations/20261017160000_order_today.sql`: Today figures in `api.order_summary`.

Conventions are unchanged from Phases 5–6. Tables live in `app` with SELECT-only member RLS. Every change goes through an `api` SECURITY DEFINER function that returns the `{ok, data | error}` envelope.

## 1. Tables

### `app.orders`
| Column | Notes |
|---|---|
| `id`, `store_id` | `unique (store_id, id)` for composite foreign keys |
| `number` | Per store, from `stores.last_order_number` (starts at 1000, so the first order is **#1001**). `unique (store_id, number)` |
| `status` | `draft`, `pending_approval`, `rejected`, `approved`, `processing`, `dispatched`, `delivered`, `delivery_failed`, `returned`, `cancelled` |
| `origin` | `manual` (Phase 7) or `ai` (reserved for Phase 8) |
| `is_test` | Always false in P0 (no sandbox conversations yet). Immutable |
| `currency` | Store currency copied at creation. Immutable |
| `customer_name`, `customer_phone`, `customer_phone2` | Customer snapshot. Phones are Iraqi mobiles in E.164 (`^\+9647[0-9]{9}$`) |
| `zone_id`, `zone_name` | Zone and its name **snapshot**. Composite FK to `delivery_zones` |
| `city_text` | A place outside the zones ("Other place") |
| `area`, `landmark`, `address_details` | Delivery details |
| `delivery_fee`, `delivery_fee_source` | Snapshot of the zone fee (`zone`) or the seller's fee (`seller`) |
| `payment_method`, `payment_note` | `cod` or `other` (recorded only, BR-42) |
| `discount` | 0 … subtotal (BR-25) |
| `subtotal`, `total` | Computed by the server. CHECK `total = subtotal − discount + fee` |
| `cod_due`, `cod_collected` | Set at approval; 0 due after cancel or return (BR-44) |
| `customer_note`, `internal_note`, `courier_note` | |
| `failure_reason` | `unreachable`, `refused`, `wrong_address`, `other` |
| `closed_reason`, `closed_note` | Reject and cancel reasons, return note |
| `approved_by`, `approved_at` | CHECK: present exactly when the status is approved or later |
| `confirmation_marked_sent_at` | "I sent this" (OR-10), the seller's statement |
| `search_text`, `phone_digits` | Normalized search fields (Arabic/Kurdish letter variants, Eastern digits, phone in international and local forms) |
| `version`, `created_at`, `updated_at`, `status_changed_at` | Optimistic concurrency and times |

### `app.order_items`
| Column | Notes |
|---|---|
| `variant_id`, `product_id` | Composite FKs `(store_id, …)`. Null only for an unresolved AI line (Phase 8); CHECK resolution ↔ variant |
| `resolution`, `customer_text`, `quantity_basis` | For AI drafts. Manual lines are `resolved` / `confirmed` |
| `name_snapshot`, `variant_label_snapshot`, `sku_snapshot` | Taken when the line is added, refreshed and frozen at approval |
| `quantity` | 1–999 (BR-37) |
| `quoted_unit_price` | Catalog price when the line was added (BR-23) |
| `approved_unit_price` | Price chosen at approval; never changes afterwards |
| `stock_deducted` | Units this line currently holds from stock (see [D](d-inventory-integration.md)). CHECK `≤ quantity` |

A unique index allows one line per variant per order.

### Other tables
| Table | Purpose |
|---|---|
| `app.order_status_events` | One row per status change: from, to, actor (user or `validation`), reason, note, time. Append-only (trigger) |
| `app.order_transitions` | The 15 allowed transitions of BR-30 and the function that performs each. Fixed (trigger), not readable by clients |
| `app.return_lines` | Per-line restock and write-off quantities; unique per item |
| `app.cod_collections` | Cash recorded (amount > 0, who, when) |
| `app.inventory_movements.order_id` | New column, composite FK to the order. CHECK: order reasons ⇔ `order_id` present |
| `app.stores.last_order_number` | New column for the numbering |

## 2. Storage-level guards
- `orders_status_guard` (trigger): a new order starts as `draft` or `pending_approval`. A status change must be in `order_transitions`. Store, number, currency and test flag are immutable. Orders are never deleted outside the account purge.
- `order_status_events_append_only`, `order_transitions_fixed` (triggers).
- `product_variants_keep_ordered` (trigger): a variant referenced by an order line is never deleted. `upsert_product` answers `VARIANT_IN_USE` (BR-17).
- CHECKs on totals, discount ≤ subtotal, approver ⇔ approved status, quantities and money ranges.

## 3. Indexes
`orders (store_id, status, created_at desc)`, `(store_id, created_at desc, id)`, trigram GIN on `search_text`; `order_items (order_id, position)`, `(store_id, variant_id)`; `inventory_movements (store_id, order_id)`; `order_status_events (order_id, id)`; `cod_collections (order_id)`.

## 4. Functions (`api`)
| Function | Purpose |
|---|---|
| `create_order(store, order, key)` | Manual order → draft or pending approval |
| `update_draft(store, order_id, version, order, key)` | Full-state edit of a draft or pending order |
| `approve_order(store, order_id, version, price_choices, key)` | The approval gate ([C](c-approval-security.md)) |
| `reject_draft(store, order_id, version, reason, note, key)` | Draft or pending → rejected |
| `edit_approved_order(store, order_id, version, order, key)` | Approved or processing: edit with stock difference |
| `cancel_order(store, order_id, version, reason, note, key)` | Approved or processing → cancelled, restock |
| `transition_order(store, order_id, version, to, payload, key)` | processing, dispatched, delivered, delivery_failed |
| `record_return(store, order_id, version, lines, note, key)` | → returned with per-line decisions |
| `record_cod(store, order_id, amount, key)` | Cash after delivery, at most what is outstanding |
| `mark_confirmation_sent(store, order_id)` | "I sent this" |
| `update_order_note(store, order_id, version, note)` | Internal note, any status |
| `list_orders(store, query, filter, limit, offset)` | List page |
| `order_summary(store)` | Counts per filter, cash outstanding, Today figures |
| `get_order(store, order_id)` | Detail ([§5](#5-json-contract)) |
| `order_history(store, order_id)` | Status events plus edits, notes, cash, confirmation marks |

`list_inventory_movements` now also returns `order_id` and `order_number`.

## 5. JSON contract
`app.order_json` is the single shape returned by every read and mutation:

```
{ id, store_id, number, status, origin, is_test, currency,
  customer: {name, phone, phone2},
  delivery: {zone_id, zone_name, city_text, area, landmark, details, fee, fee_source, courier_note},
  payment: {method, note, cod_due, cod_collected, cod_outstanding},
  discount, subtotal, total, customer_note, internal_note, failure_reason,
  closed_reason, closed_note, approved_by ("you" | "member" | "system"), approved_at,
  confirmation_marked_sent_at, version, created_at, updated_at, status_changed_at,
  issues: [{field, kind, item_id?}],
  lines: [{id, variant_id, product_id, resolution, customer_text, name, variant_label, sku,
           quantity, quantity_basis, quoted_unit_price, approved_unit_price, unit_price,
           line_total, stock_deducted, image_path,
           current: {price, stock_on_hand, track_stock, available, product_status, variant_status},
           return: {restock_qty, writeoff_qty} | null}],
  events: [{from, to, actor, reason, note, created_at}],
  cod_collections: [{amount, actor, created_at}] }
```

The mutations add, depending on the call:
- `stock_after` (approve);
- `stock_diff` (approved edit);
- `restocked` (cancel, return).

Each entry has the item, variant, name, label, before and after.
