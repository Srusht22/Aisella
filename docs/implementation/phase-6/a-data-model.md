# A. Product and inventory data model

Migration: `supabase/migrations/20261017090000_catalog_inventory.sql`. The tables follow Phase 3 §4.2; the differences are listed in §6.

## 1. Entities

```
stores 1──* products 1──* product_variants 1──* inventory_movements (append-only ledger)
                  └──* product_images (≤ 5)  ──▶ storage.objects in bucket store-media
```

- Every product has **at least one variant** (BR-13). A product without options has exactly one *default* variant with `option_values = '{}'`; the seller never sees it as a variant.
- **Stock, SKU, price override and the low-stock threshold live on variants**, never on the product, so the same units are never counted twice.

## 2. Tables

### `app.stores` (one new column)
| Column | Type | Rule |
|---|---|---|
| `low_stock_default` | integer, default **3** | 0–9999. The store-wide low-stock threshold (BR-18, decision P6-D2). |

### `app.products`
| Column | Type | Rule |
|---|---|---|
| `id` | uuid PK | **Chosen by the client** for new products, so photos can upload before the first save. A taken id is refused (§C). |
| `store_id` | uuid → stores | Unique `(store_id, id)` as the target of composite foreign keys |
| `name` | text | 1–120 characters, trimmed |
| `description` | text, null | ≤ 2000 characters (used by the AI in Phase 8) |
| `category` | text, null | 1–60 characters, trimmed. The spelling already used in the store is reused (case-insensitive). |
| `base_price` | integer | **1 … 1,000,000,000**, in the store currency (§3) |
| `track_stock` | boolean | Default true. False means BR-16 availability mode. |
| `option_types` | text[] | 0–2 names, for example `{Size, Colour}` |
| `status` | text | `active`, `inactive` or `archived` (never deleted, BR-17) |
| `search_text` | text | Normalized name, category, option values and SKUs (§5) |
| `version` | integer | Optimistic concurrency for edits |
| `created_at`, `updated_at` | timestamptz | |

### `app.product_variants`
| Column | Type | Rule |
|---|---|---|
| `id` | uuid PK | |
| `store_id`, `product_id` | uuid | Composite FK `(store_id, product_id)` → products, so a variant can't point at another store's product |
| `option_values` | text[] | One value per option type; `{}` for the default variant. **Unique per product** (deferrable constraint). |
| `label` | text | Values joined with " · " ("M · Black") |
| `sku` | text, null | 1–64 characters. **Unique per store, case-insensitive** (partial unique index). |
| `price_override` | integer, null | 1 … 1,000,000,000. Null means the product price. |
| `stock_on_hand` | integer | **CHECK 0 … 1,000,000**. Changed only by ledger functions (§B). |
| `available` | boolean | Availability switch for untracked products |
| `low_stock_threshold` | integer, null | 0–9999. Null means the store default. |
| `status` | text | `active` or `archived` |
| `position` | integer | Display order |

### `app.product_images`
| Column | Type | Rule |
|---|---|---|
| `storage_path` | text, **unique** | `{store_id}/products/{product_id}/{uuid}.jpg` |
| `position` | integer | 0–4. Unique per product; position 0 is the main photo. |
| `store_id`, `product_id` | uuid | Composite FK → products |

### `app.inventory_movements` (append-only)
| Column | Type | Rule |
|---|---|---|
| `id` | bigint identity | Ordering key for history paging |
| `store_id`, `variant_id` | uuid | Composite FK → variants |
| `delta` | integer | ≠ 0 |
| `resulting_qty` | integer | ≥ 0. Equals `stock_on_hand` right after the movement. |
| `reason` | text | `initial_stock`, `received`, `sold_in_shop`, `damaged`, `count_correction`, `other`, plus the order reasons reserved for Phase 7 (`order_approved`, `order_edited`, `order_cancelled`, `order_returned_restock`) |
| `note` | text, null | ≤ 200 characters. Required for `other`. |
| `actor_user_id` | uuid, null | Null for the system |
| `created_at` | timestamptz | |

A trigger refuses every UPDATE and DELETE (errcode `AS002`). The only exception is a DELETE inside the account-purge transaction, which sets `aisellia.purge = on` for itself.

## 3. Money

- **Representation:** integers in the store's currency unit, with no fractional part (Phase 1 BR-12, D-08). IQD has no minor unit in use, and USD prices are whole dollars in P0. No floating point is used anywhere: the database type is `integer`, Dart uses `int`, and JSON carries integers.
- **One currency per store**, taken from `stores.currency`. Products don't carry a currency.
- **Currency changes are refused once the store has products** (`CURRENCY_LOCKED`, reason `products_exist`, decision P6-D3). Prices are never converted. The store JSON reports `currency_locked` when products exist or an order has been approved.
- **Validation:** the server checks the JSON type (number, not string), integrality and range for the product price and every variant override. The client parses Western, Eastern Arabic and Persian digits with grouping separators, but sends only integers.
- **Display:** `Money.format` gives "35,000 IQD" or "35,000 د.ع", and "$25". Each number is an LTR isolate. Ranges read "35,000 IQD – 42,000 IQD".
- **Discounts, sale prices and promotions** are not part of the P0 catalog and were not built.

## 4. Categories

A **free-text category per product**, matching Phase 1 ("category (optional, free or chosen)") and Phase 3 (`products.category`):
- the editor offers the store's existing categories plus eight localized suggestions (Clothing and fashion, Shoes and bags, Cosmetics and skincare, Perfumes, Electronics and accessories, Home goods, Gifts, Other);
- the server reuses an existing spelling case-insensitively, so "shoes" doesn't create a second "Shoes";
- `api.catalog_summary` lists the distinct categories with counts for the filter.

No category table was added; the approved model has none. The suggestions are stored in whatever language the seller picked them.

## 5. Indexes and search

| Index | Purpose |
|---|---|
| `products (store_id, status, updated_at desc)` | Default list order and status filters |
| `products (store_id, lower(category))` | Category filter |
| `products using gin (search_text gin_trgm_ops)` | Substring search (pg_trgm) |
| `product_variants (product_id, position)` | Variant reads |
| `product_variants (store_id, lower(sku)) where sku is not null` | SKU uniqueness and lookup |
| `inventory_movements (variant_id, id desc)`, `(store_id, id desc)` | History paging, reconciliation |

`app.search_normalize` lowercases text and maps ي/ى to ی and ك to ک. It converts Eastern Arabic and Persian digits to Western, removes tatweel and ZWNJ, and collapses spaces. The same function normalizes stored text and the query, so "كراس" and "کراس" match. LIKE wildcards in queries are escaped.

## 6. Differences from Phase 3 §4.2

| Phase 3 | Implemented | Why |
|---|---|---|
| `product_images.status` (pending, ready, failed) | No status column; a row exists only once the object is uploaded and attached | Pending and failed states live in the editor; orphans are found by `internal.orphaned_media` (§D) |
| `option_values` jsonb | `text[]` aligned with `option_types` | Simpler uniqueness and ordering; the same information |
| `inventory_movements.order_id` | Not added yet | No orders table exists; Phase 7 adds the column and FK (§E) |
| Store currency immutable after the first approval | Also immutable once products exist | P6-D3: prices are stored in the store currency |

## 7. JSON contract (returned by the `api` functions)

`api.get_product` and `api.upsert_product` return:

```json
{ "id", "store_id", "name", "description", "category", "base_price", "track_stock",
  "option_types": ["Size"], "status", "version", "created_at", "updated_at", "low_stock_default",
  "variants": [{ "id", "option_values": ["M"], "label", "sku", "price_override", "price",
                 "stock_on_hand", "available", "low_stock_threshold", "status", "has_history" }],
  "images": [{ "id", "path", "position" }] }
```

`upsert_product` also returns `removed_image_paths`. List items, the summary and movements are described in [E](e-integration-contract.md).

## 8. Rollback considerations

The migration is additive except for three replaced functions: `store_json`, `store_field_errors` and `update_store` (all backward compatible), plus `purge_due_account_deletions`.

To roll back on a database **without catalog data**:
1. drop the four tables, the new functions and the storage policies;
2. drop `stores.low_stock_default`;
3. unschedule `aisellia-inventory-reconciliation`;
4. re-create the three Phase 5 functions from `20261015170000` and `20261015210000`.

Once sellers have created products, roll back by archiving data first; never drop tables holding seller data. No rollback script is shipped, because the migration has not reached any shared environment.
