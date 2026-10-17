# D. Ownership, authorization and tenant isolation

This implements Phase 3 `authorization-and-tenancy.md`, `backend-and-data-model.md`, `api-and-service-contracts.md` and ADR-002/003/005, limited to identity, stores, membership, delivery zones and account deletion. Migrations:

- `supabase/migrations/20261015170000_identity_stores_onboarding.sql`
- `supabase/migrations/20261015210000_account_deletion.sql`

## 1. Schemas and exposure

| Schema | Holds | Exposed by PostgREST | `anon` | `authenticated` |
|---|---|---|---|---|
| `app` | Tables and private helpers | **No** | nothing | `USAGE` only (needed by RLS and the views); `EXECUTE` on `app.is_member` only |
| `api` | Read views and mutation functions | **Yes** (the only schema in `config.toml`) | nothing | `SELECT` on the views; `EXECUTE` on the reviewed functions |
| `internal` | Sign-up trigger, purge job | No | nothing | nothing (`service_role` may run the purge) |

`auto_expose_new_tables=false`, and default privileges revoke `EXECUTE` from `PUBLIC` in every schema, so a new object is **closed by default**. The database test `01_catalog_guards` fails if:
- any `app` table lacks RLS;
- `anon` or `authenticated` holds any write privilege;
- `anon` can execute anything;
- an `api` function is not `SECURITY DEFINER` with `search_path=''`;
- an `api` view is not `security_invoker`;
- the `api` surface differs from the reviewed list.

## 2. Tables (minimal by brief)

| Table | Purpose | Key rules |
|---|---|---|
| `app.profiles` | One row per auth user (sign-up trigger) | Terms version and acceptance time. Display preferences stay on the device in P0. |
| `app.stores` | The seller's business | Name 1–60 characters (trimmed); phone `^\+9647[0-9]{9}$`; currency IQD or USD; reply locale `ckb` or `en`; city; payment switches with at least one on; `onboarding_step`; `currency_locked_at`; `deletion_requested_at`; `version` |
| `app.store_members` | Who may act in a store | Role `owner` (P0) plus a `permissions` JSON for later staff; **one owner per store** and **one store per user** (unique indexes) |
| `app.delivery_zones` | Delivery areas and fees | Unique active name per store (case-insensitive); fee 0–10,000,000 IQD; soft deactivation; `version` |
| `app.audit_events` | Who changed what | Written by every mutation in the same transaction; members may read their own store's events |
| `app.idempotency_keys` | Replay of retried mutations | `(user_id, key)`, request hash, stored response |
| `app.account_deletion_requests` | Pending and completed deletions | One pending request per user; RLS with **no policy** (unreadable through the API) |

No catalogue, inventory, order, conversation, AI, billing or analytics tables were created.

## 3. Reads: RLS through security-invoker views

- RLS is enabled on every `app` table. The policies are **SELECT-only**: `app.is_member(store_id)` for store data, and `auth.uid() = id` for the user's own profile.
- `app.is_member` requires an **active** membership in a store **not marked for deletion**. It is `SECURITY DEFINER` so that the policy on `store_members` does not recurse.
- The client reads `api.stores` and `api.delivery_zones`. Both are `security_invoker`, so the caller's RLS applies, and they expose only the columns the app needs.
- `authenticated` has **no INSERT, UPDATE or DELETE** on any table or view. Every write goes through §4.

## 4. Writes: authorizing `api` functions

| Function | Authorization | Notes |
|---|---|---|
| `get_my_context()` | Signed-in end user | Email, verification, role, store, pending deletion |
| `create_store(...)` | End user, no pending deletion, no existing store | Idempotent; creator becomes owner |
| `update_store(id, expected_version, changes, key)` | `settings.manage` in that store | Field allow-list; optimistic version; currency lock; audited with only the changed fields |
| `advance_onboarding(id, step)` | `settings.manage` | Forward only |
| `upsert_zone(...)` / `deactivate_zone(...)` | `settings.manage` | Zone must belong to **that** store (a guessed id from another store returns `NOT_FOUND`); 50-zone limit |
| `request_account_deletion(confirm_name)` | End user, **password sign-in within 5 minutes** (JWT `amr`), owner, exact store name | §6 |

Every function follows the same pattern:
- `app.require_end_user()` refuses `anon` and also `service_role`, so the backend can never act as a seller by accident.
- `app.require_permission(store, perm)` returns **`NOT_FOUND`** for non-members and for random ids alike, so a store's existence is never revealed.
- Validation errors are reported per field.
- Business errors are raised as SQLSTATE `AS001` and returned in the envelope `{ok:false,error:{code,details}}`.
- Unexpected errors return `INTERNAL` with a short reference only. The details go to the server log, never to the client.

The `ApiErrorCode` values the client handles are: `VALIDATION_FAILED`, `UNAUTHENTICATED`, `FORBIDDEN`, `NOT_FOUND`, `CONFLICT_VERSION`, `LIMIT_EXCEEDED`, `CURRENCY_LOCKED`, `IDEMPOTENCY_KEY_REUSED`, `RATE_LIMITED`, `REAUTHENTICATION_REQUIRED` and `INTERNAL`, plus the client-side `network` and `timeout`.

## 5. Tenant isolation: evidence

Isolation is tested at **two levels**. The Phase 3 test IDs NT-01 to NT-10 are used in the test names.

1. **pgTAP, in the database** (`02_tenant_isolation`, 27 assertions). Seller B cannot read A's stores, zones, memberships or audit trail, either through the views or directly. B cannot update A's store, edit, add or remove A's zones, or advance A's onboarding. A random id gives the same `NOT_FOUND` as A's real id. B cannot reach A's zone through B's own store id. Direct `UPDATE` and `DELETE` on tables and views are refused, and B cannot make themselves a member of A's store. `anon` can do nothing, and `service_role` cannot call seller mutations. A's data is unchanged at the end.
2. **End to end through the real stack** (`test/backend`). These tests use real GoTrue JWTs and real PostgREST calls, through the app's own repositories:
   - the same isolation checks with forged ids;
   - a direct `PATCH` on `api.stores` refused (direct `INSERT`, `UPDATE` and `DELETE` are covered in pgTAP);
   - the `app` schema and its helpers unreachable through PostgREST;
   - an anonymous caller refused;
   - a **forged JWT** (claims `role: authenticated`, invalid signature) rejected.

**The tests are not vacuous.** Each guard was removed in turn on the local database. The suite then failed, and it passed again after `supabase db reset`:

| Mutation | Failing assertions |
|---|---|
| `app.is_member` always returns `true` (RLS effectively off) | 17 |
| `app.require_permission` skips the membership check | 8 |
| `grant update on app.stores to authenticated` | 2 |

## 6. Account deletion

Phase 1 US-004 and D-13, Phase 2 ST-08, Phase 3 authorization §3.1.

1. **The seller asks** in the app: Store → Account → Delete account. The screen explains what is deleted and when. The seller re-enters their password, which triggers a fresh sign-in, and types the store name.
2. **The server checks** that the JWT's `amr` shows a **password sign-in within the last 5 minutes** (`REAUTHENTICATION_REQUIRED` otherwise) and that the name matches exactly. The client cannot skip either check.
3. **Access ends at once.**
   - The store gets `deletion_requested_at`, so `is_member` becomes false: every read returns nothing and every mutation returns `NOT_FOUND`.
   - `get_my_context` reports `deletion_pending` and the date, and the router shows "Your account is being deleted" with Sign out as the only action.
   - Creating a new store is refused while the request is pending.
   - Repeating the request returns the same schedule.
4. **The purge runs** after **14 days**. `internal.purge_due_account_deletions()` deletes zones, the audit trail, memberships, the store, the idempotency keys and then the **auth user**; the profile, sessions and identities cascade. It runs daily at 03:17 UTC through `pg_cron` (job `aisellia-purge-account-deletions`). Only `service_role` and the cron job may run it; the database tests show that `authenticated` cannot.

Not done, and documented as risks in I:
- the confirmation email (needs the production SMTP sender);
- cancelling from the app (a support procedure for now);
- a deletion receipt kept after the purge (the request row keeps only ids and dates).

## 7. Hardening details

- Every `SECURITY DEFINER` function sets `search_path=''` and fully qualifies every name.
- The `app.fail`, `ok` and `err` helpers are not callable by clients.
- The sign-up trigger reads only `terms_version`, truncated to 32 characters, from user metadata. Nothing else from client-controlled metadata is trusted.
- The request hash for idempotency covers the normalized payload, so a reused key with a different payload is refused (`IDEMPOTENCY_KEY_REUSED`).
- Currency is locked once `currency_locked_at` is set. Phase 5 has no orders, so nothing sets it yet; the guard and its test are in place for the orders phase.
