# Authorization and tenancy

**Phase 3** · Status: **Proposed — pending owner approval** · Related: [ADR-002](architecture-decision-records/ADR-002-mutations-through-database-functions.md), [ADR-003](architecture-decision-records/ADR-003-tenant-isolation.md) · Product roles: Phase 1 §5

## 1. Identity model
| Concept | Representation |
|---|---|
| **User** | A Supabase Auth user (`auth.users.id`) authenticated by email and password (Phase 1 D-07). The JWT `sub` is the user ID; `role` is `authenticated`. |
| **Store** | `stores.id`, the tenant |
| **Membership** | `store_members` (`store_id`, `user_id`, `role`, `permissions`, `status`). P0: a single `owner` per store, and one store per user (enforced in `api.create_store`). The schema allows many-to-many for P1 staff and P2 multi-store. |
| **System actors** | `service_role` (Edge Functions acting for the system: AI in webhook context (P1), jobs, deletions). It can call **only `internal.*` functions**, each of which declares what it may do. |
| **Support operator** | **No standing access** to store data. Break-glass procedure only (§7). |
| **AI** | Not an identity. AI output is written either by an `api.*` call carrying the **user's JWT** (Stage A, user-initiated) or by `internal.record_ai_result` (P1 webhook context). Neither path can approve, cancel, transition, adjust stock, change prices or change settings. |

**Current store resolution:** the client sends `store_id` explicitly on every call. The server never trusts it; each function verifies membership for that store. In P0 the client resolves its single store from `store_members` at sign-in.

## 2. Roles and permissions
P0 has only `owner`. `staff` permissions (P1) are boolean flags so that the owner can grant them individually, matching Phase 1 §5.2.

| Permission | Owner | Staff default (P1) | Grantable to staff |
|---|---|---|---|
| `catalog.read`, `orders.read`, `conversations.read` | ✓ | ✓ | — |
| `customers.read` | ✓ | ✓ | — |
| `catalog.edit` (details, images, variants) | ✓ | ✗ | ✓ |
| `catalog.price` | ✓ | ✗ | ✓ (later) |
| `inventory.adjust` | ✓ | ✗ | ✓ |
| `customers.edit` / `customers.delete` | ✓ / ✓ | ✗ / ✗ | ✓ / ✗ |
| `orders.create_draft`, `orders.edit_draft`, `orders.reject` | ✓ | ✓ | — |
| **`orders.approve`** | ✓ | ✗ | ✓ ("Can approve orders") |
| `orders.cancel` | ✓ | ✗ | ✓ |
| `orders.fulfil` (transitions after approval, COD) | ✓ | ✓ | — |
| `orders.discount` | ✓ | ✗ | ✗ |
| `settings.manage` (zones, payments, policies, profile, currency) | ✓ | ✗ | ✗ |
| `channels.manage` (P1) | ✓ | ✗ | ✗ |
| `members.manage` (P1) | ✓ | ✗ | ✗ |
| `audit.read` | ✓ | own actions | — |
| `store.delete` | ✓ (re-authentication) | ✗ | ✗ |

Helper functions (in `app`, `SECURITY DEFINER`, `search_path = ''`):
- `is_member(store_id)`: used by RLS.
- `require_permission(store_id, permission)`: used at the start of every `api.*` function. It raises `FORBIDDEN`, or `NOT_FOUND` when the user is not a member, so the store's existence is not revealed.
- `require_end_user()`: rejects the `service_role` and anonymous callers. Used by approve, cancel, transitions, stock, prices and settings.

## 3. Enforcement layers
1. **Network or API:** only the `api` schema and read views are exposed through PostgREST. `internal` is not exposed.
2. **Privileges:** `authenticated` has SELECT on business tables and views and EXECUTE on `api.*` functions. There are **no** INSERT, UPDATE or DELETE privileges on any business table.
3. **RLS:** every business table has RLS enabled with a SELECT policy `using (app.is_member(store_id))`. Tables with no client read need (`idempotency_keys`, `webhook_events`, `job_runs`, `account_deletion_requests`) have RLS enabled with **no** policy (deny all).
4. **Function checks:** explicit permission and end-user checks in every `api.*` function, plus validation that every referenced ID belongs to the same store (composite foreign keys are the backstop).
5. **Constraints:** CHECK, composite foreign keys, unique indexes.
6. **Client UI:** hides or disables actions for usability only. **Never relied on.**

## 4. Sensitive operations: how each is enforced
| Operation | Path | Authorization | Additional server checks | Audit |
|---|---|---|---|---|
| Read a product | SELECT `products`/`product_variants` | RLS `is_member` | — | — |
| Create or edit a product | `api.upsert_product` | `catalog.edit` (+ `catalog.price` when price fields change) | Limits (5 images, 2 option types, 100 variants), SKU unique per store, price > 0, version | ✓ (price changes with before and after) |
| Adjust stock | `api.adjust_stock` | `inventory.adjust` + end user | Variant in store, result ≥ 0, reason required, idempotency, row lock | Movement row + audit |
| Read customer details | SELECT `customers`, phones, addresses | RLS `is_member` (+ `customers.read`, always true in P0) | — | Not audited in P0 (reads) |
| Access conversations and messages | SELECT | RLS `is_member` | Sandbox and live are separated by `is_sandbox` | — |
| Create an order draft | `api.create_order` (manual) / `api.record_ai_result` (AI, user JWT) / `internal.record_ai_result` (P1 system) | `orders.create_draft`, or system context for internal | Status forced to draft or pending; all referenced IDs in the store; prices taken from the catalog | ✓ |
| Edit an order | `api.update_draft` / `api.edit_approved_order` | `orders.edit_draft` / owner (P0) | Version; allowed only in permitted statuses (BR-33); stock difference for approved orders | ✓ (before and after) |
| **Approve an order** | `api.approve_order` | `orders.approve` + **end user** + verified email | §6.2 of the data model | ✓ + status event |
| Cancel an order | `api.cancel_order` | `orders.cancel` + end user | Status ∈ {approved, processing}; reason; restock | ✓ + status event |
| Fulfilment transitions, COD | `api.transition_order`, `api.record_cod` | `orders.fulfil` + end user | Transition table; dispatch needs delivery details; COD ≤ due | ✓ + status event |
| Manage store settings | `api.update_store`, `api.upsert_zone`, `api.upsert_policy`, … | `settings.manage` | Currency lock; validation | ✓ |
| Connect or disconnect channels (P1) | Edge Function `channel-connect` → `internal.*` | Caller JWT checked for `channels.manage` before using the service role | OAuth state bound to user and store; token stored in Vault; disconnect revokes | ✓ |
| Files (images) | Storage | Policies on `storage.objects`: `bucket = 'store-media'`, first path segment = `store_id`, `is_member` for SELECT; INSERT, UPDATE and DELETE require `catalog.edit` | Size ≤ 10 MB before compression, MIME allow-list (JPEG/PNG/HEIC/WebP), private bucket, short-lived signed URLs | Image add and remove audited |
| Exports | Not in P0 | — | — | — |
| Delete account or store | Edge `account-delete` | JWT + recent re-authentication + owner | Grace period; scheduled execution | ✓ |

## 5. Cross-tenant references
- Every function resolves the `store_id` of each referenced row (order, variant, customer, zone, conversation) and requires it to equal the authorised store. A mismatch returns `NOT_FOUND`, the same as a non-existent ID.
- Composite foreign keys `(store_id, x_id)` make a mismatched reference impossible at the storage level.
- Guessing UUIDs gains nothing. RLS hides the rows, and functions return `NOT_FOUND`.
- Storage paths must start with the authorised `store_id`. The client never chooses another store's prefix, and policies enforce it.

## 6. Service role rules
- The service-role key exists only in Edge Function secrets and CI deployment secrets. It is **never** in the app or the repository.
- Edge Functions acting **for a user** use a Supabase client created with **the caller's JWT**, so RLS and function checks apply. The service role is used only to call explicitly designated `internal.*` functions.
- Each `internal.*` function documents and enforces its narrow purpose. For example, `internal.record_ai_result` can only create or update drafts and suggestions; `internal.ingest_webhook_event` can only insert events and messages.
- `api.approve_order` and the other end-user operations call `require_end_user()`. A leaked service-role key therefore still cannot approve orders through these functions (the prototype's T5 showed this). It could still read all data, so it is treated as a top-severity secret ([threat model](security-threat-model.md)).

## 7. Administrative and support access
- No admin UI in the pilot.
- **Break-glass procedure:**
  1. Written seller consent (for example in the support chat), naming the purpose.
  2. Time-boxed access using a dedicated, named Postgres role with read-only access (`support_readonly`), enabled only for the session.
  3. Queries recorded in an incident log.
  4. The role is disabled afterwards.
- Writes during support go through `api.*` functions impersonating nobody, or a reviewed migration.
- Supabase dashboard access is limited to named owner accounts with MFA enabled (pilot requirement).

## 8. Audit requirements
Audited actions (Phase 1 BR-63):
- approve, reject, cancel, every status transition, edit after approval
- stock adjustment, price change, discount
- settings change, currency lock
- channel connect and disconnect, member changes (P1)
- customer anonymisation, account deletion request and execution
- break-glass sessions (outside the database)

Each record holds actor, store, entity, action, minimal before/after, timestamp and request reference. Audit rows are written in the same transaction as the change.

## 9. Negative authorization tests (architectural requirements)
These tests are **mandatory** before the external pilot and run in CI against the local Supabase stack. Each test uses two stores (A, B), two users, and the anonymous and service-role contexts.

| ID | Test | Expected |
|---|---|---|
| NT-01 | User B selects from every business table and view with A's data present | 0 rows |
| NT-02 | User B calls every `api.*` function with A's IDs | `NOT_FOUND` (no existence leak), no side effects |
| NT-03 | User A attempts INSERT, UPDATE or DELETE on every business table directly | `permission denied` |
| NT-04 | Anonymous caller (anon key, no JWT) reads any table or calls any `api.*` | Denied |
| NT-05 | `service_role` calls `api.approve_order`, `cancel_order`, `transition_order`, `adjust_stock` | `FORBIDDEN` |
| NT-06 | A function receives mixed references (A's order with B's variant) | `NOT_FOUND`; no row created |
| NT-07 | User B reads or writes Storage objects under A's prefix (direct path and signed-URL request) | Denied |
| NT-08 | Unverified-email owner approves | `EMAIL_NOT_VERIFIED` |
| NT-09 | Staff without `orders.approve` approves (P1) | `FORBIDDEN` |
| NT-10 | Client sets `status` or `stock_on_hand` via any PostgREST path (PATCH, upsert) | Denied |
| NT-11 | `internal.*` functions called with a user JWT through PostgREST | Not exposed (404) or denied |
| NT-12 | AI system path attempts to create a draft with a status other than draft or pending | Rejected |
| NT-13 | Deep link to another store's order in the app | GL-04 (not found) with no data rendered |
| NT-14 | Reused idempotency key with a different payload | `IDEMPOTENCY_KEY_REUSED` |
| NT-15 | Expired or forged JWT | 401 |

A generated test enumerates all tables and all `api.*` functions from the catalog (`pg_class`, `pg_proc`), so a **new table or function without a negative test fails CI**.
