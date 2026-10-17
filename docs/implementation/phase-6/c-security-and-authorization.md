# C. Security and authorization

Phase 6 reuses the Phase 5 model (Phase 3 ADR-002/003, authorization §3) without exceptions.

## 1. Store scoping

- **Reads and writes go through `api` functions only.** All are `SECURITY DEFINER` with an empty `search_path`. Each one:
  1. calls `app.require_end_user()`, which refuses anon and service_role;
  2. checks membership and permission for **the store id in the request**, with `require_member` for reads and `require_permission(store, perm)` for writes;
  3. filters every query by that store id.
- A store the caller doesn't belong to, and any id that isn't in that store, gives **`NOT_FOUND`**. This is the same answer as a random id, so nothing about another store's existence leaks.
- **Permissions** (owners hold all of them in P0):

| Action | Permission |
|---|---|
| Create or edit a product | `catalog.edit` |
| Change a price on edit | also `catalog.price` |
| Archive | `catalog.archive` |
| Adjust stock | `inventory.adjust` |

- **Ids from the client are never trusted:**
  - composite foreign keys `(store_id, product_id)` and `(store_id, variant_id)` make cross-store references impossible at the storage level;
  - a client-chosen product id that already exists, in any store, is refused;
  - variant ids in an edit must belong to that product;
  - image paths must carry the same store and product.
- **RLS:** the four new tables have RLS enabled with SELECT-only member policies, as defense in depth. `authenticated` has no INSERT, UPDATE or DELETE on any table.
- **Guards:** `01_catalog_guards` fails the build if:
  - a new table lacks RLS;
  - anyone gains a write privilege;
  - an `api` function isn't a hardened security definer;
  - the `api` surface differs from the reviewed list;
  - the bucket stops being private, JPEG-only and ≤ 2 MiB;
  - an update policy appears on media;
  - the ledger trigger disappears.

## 2. Storage (bucket `store-media`)

| Operation | Policy on `storage.objects` |
|---|---|
| Read (and signed URLs, which are created with the seller's own token) | `bucket_id = 'store-media'` and member of the store named by the first path segment |
| Upload | `catalog.edit` in that store, and the path matches `{uuid}/products/{uuid}/{uuid}.jpg` |
| Overwrite or rename | **No UPDATE policy**, so it's refused (verified: `x-upsert` returns 403) |
| Delete | `catalog.edit` in that store, and **no product still references the object** |

- The three helpers the policies call (`app.has_permission`, `app.media_store_id`, `app.media_referenced`) are the only new functions `authenticated` may execute in `app`. They are read-only checks.
- Bucket limits enforced by the Storage API: **private, `image/jpeg` only, 2 MiB**. Verified: PNG returns 415 and larger files return 413.
- No service key or secret is used by the app. Uploads, signed URLs and deletes all use the seller's JWT.

## 3. Data integrity

- Server-side validation of every field: types, lengths, integrality, ranges, duplicates, per-variant rules, image ownership.
- Business errors come back in the envelope. Unexpected errors return `INTERNAL` with a reference only; details go to the server log. No product data, tokens or prices are logged by the app.
- Every write is audited in the same transaction: `product.create`, `product.update` (with before and after prices), `product.status`, `stock.adjust`.
- Idempotency keys protect product creation and edits, and stock adjustments. Status changes are naturally idempotent.

## 4. Tests of authorization and isolation

| Level | Where | What |
|---|---|---|
| pgTAP | `07_catalog_isolation` (32 assertions) | Seller B gets `NOT_FOUND` for A's list, product, summary and history, directly or through B's own store id. B can't edit, create in, archive, or adjust A's catalog, or take over A's product id. RLS hides all of A's rows. Direct writes are refused. Storage: B can't see, upload under, attach or delete A's objects. Overwrite is impossible. Referenced objects can't be deleted; unreferenced own uploads can. anon is refused. |
| pgTAP | `01_catalog_guards` (12) | The structural guards above |
| Real stack | `catalog_backend_test.dart` | Real GoTrue JWTs, PostgREST and Storage API. B is refused on reads, search, stock, edits, upload to A's prefix, signing A's image and deleting it; A's image and stock are unchanged afterwards. |
| Real stack (manual smoke) | Storage API via curl | Own upload 200; PNG 415; over 2 MiB 413; another store's prefix 403; overwrite 403; signed URL 200 `image/jpeg`; public and anonymous reads refused; a referenced object isn't deleted |

The Phase 5 mutation checks (an always-true `is_member`, a skipped `require_permission`, an extra write grant) apply unchanged. The catalog functions use the same helpers.
