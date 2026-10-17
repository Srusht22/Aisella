# I. Security hardening before Phase 8

This milestone was authorized after Phase 7 was accepted and before Phase 8. Its scope:

- the AI draft boundary;
- idempotency-key retention;
- AI quotas;
- customer-data privacy in the audit.

It has no AI provider, no model calls, no customer messaging and no deployment. It supersedes [F §1](f-integration-contract.md) item 1 ("run as the seller's request with the end-user JWT"): the AI now has its own role and never acts with a seller's token.

| Milestone | Commit | Migration | Tests |
|---|---|---|---|
| A. AI draft boundary and quotas | `3c34290` | `20261017200000_ai_draft_boundary.sql` | pgTAP 01 (guards), 11 (69); `supabase/tests/api/ai_role_api_test.py` (17 HTTP checks) |
| B. Retention jobs | `81afa33` | `20261017210000_maintenance_jobs.sql` | pgTAP 12 (16) |
| C. Customer privacy | `2f28a18` | `20261017220000_customer_privacy.sql` | pgTAP 13 (33); 08 updated |

## 1. The AI execution role

| Property | Value |
|---|---|
| Role | `aisellia_ai`: `NOLOGIN NOINHERIT`, no `CREATEDB`, `CREATEROLE` or `BYPASSRLS` attributes, member of no role |
| How it is reached | A JWT with `"role": "aisellia_ai"`. PostgREST switches to that role; `authenticator` is granted it. |
| Schema access | `USAGE` on `api` only, plus `public`, which holds no data. No table privileges anywhere. |
| Functions | `EXECUTE` on exactly one function, `api.ai_upsert_draft(p_grant, p_ref, p_order, p_idempotency_key)` |
| Refused | `approve_order`, `reject_draft`, `cancel_order`, `transition_order`, `record_return`, `record_cod`, `update_draft`, `get_order`, `create_order`, grant management, every table and view, and storage. All return 42501 / HTTP 401–403. |

The guard test 01 fails if any of these widen: an attribute, a role membership, a second function, a reachable table, or another schema.

**Store identity.** The AI never names a store. The owner creates a grant with `api.create_ai_draft_grant(store, ai_ref?, label?, valid_hours ≤ 168)`. That function requires the owner and `ai.manage`. It returns a secret (`aig_` + 64 hex characters) exactly once and stores only its SHA-256.

`ai_upsert_draft` derives the store from the grant. The grant must be unrevoked and unexpired, and must match `ai_ref` when the grant is scoped to one conversation. Owners list grants (without secrets) with `api.list_ai_draft_grants` and revoke them with `api.revoke_ai_draft_grant`. A grant from store B cannot see, reference or change anything in store A: A's product reads as `unknown`.

**What the AI can write.** The AI can create or update one order per `(store, ai_ref)`, and only while that order is `draft` or `pending_approval`. Otherwise it gets `DRAFT_CLOSED`.

The server checks:

- product ownership, sellability and stock (`exceeds_stock`);
- quantities and required fields, through the same `order_field_errors` as manual orders.

The server computes:

- prices, from the current catalog;
- the zone fee;
- totals and status.

The payload keys `price`, `unit_price`, `total`, `subtotal`, `delivery_fee`, `status`, `approved_by`, `discount` and `internal_note` are refused, as is any other unknown key. No stock moves. The response holds only the order id, status, total and issues. It never echoes customer data back.

**Seller edits.** When a seller saves a draft, `update_draft` records the changed fields in `orders.seller_edited`. Later AI updates leave those fields alone and report them in `skipped_fields`. Once the order has been approved, rejected or cancelled, the AI gets `DRAFT_CLOSED` and changes nothing.

**Accountability.**

- Status events carry `actor_system = 'ai'`.
- Audit rows `order.ai_create` / `order.ai_update` carry `actor: 'ai'` and the grant id.
- The history shows the actor as AI.

**Quotas.** Limits live in `app.ai_limits` and can be changed by an operator, not through the API:

| Limit | Default | Error |
|---|---|---|
| Calls per grant per minute | 20 | `RATE_LIMITED` (scope `grant`, `retry_after_seconds`) |
| New AI orders per store per day | 50 | `RATE_LIMITED` (scope `store`); updates are not counted |
| Active grants per store | 10 | `LIMIT_EXCEEDED` |
| Grant lifetime | 168 h | `VALIDATION_FAILED` |

Every call is logged in `app.ai_requests`: grant, store, order and outcome, never the payload. Replays with the same idempotency key are not counted.

## 2. Retention jobs

| Job (pg_cron) | Schedule (UTC) | Function | Deletes |
|---|---|---|---|
| `aisellia-purge-idempotency-keys` | 03:23 daily | `internal.purge_idempotency_keys(default 7 days)` | `app.idempotency_keys` older than 7 days |
| `aisellia-purge-ai-request-log` | 03:29 daily | `internal.purge_ai_request_log(default 7 days)` | `app.ai_requests` older than 7 days |

**Safety.**

- A retention under one day is refused, recorded as failed, and deletes nothing.
- Only `service_role` (and the cron owner) can run the jobs.
- Errors are caught, recorded with their SQL state and raised as warnings.

**Observability.** Every run is written to `app.job_runs`: start, finish, status and rows affected, never data. `internal.job_health()` reports a job as `stale` when its last run failed or it has had no successful run in 36 hours.

After a key is purged, a retry that reuses it is processed as new. Clients keep a key for seconds to minutes, and the status guards still prevent a second approval, cancellation or stock movement.

## 3. Customer privacy

**Minimisation.** An insert trigger stores customer phones in order audit rows masked, for example `+964750***2233`. Diffs are computed on the real values first, so a phone change is still recorded even when both masked forms look alike.

**Integrity.** `app.audit_events` is append-only, even for the database owner. An update may change only `before`/`after`, and only under the redaction flag set by `anonymize_customer`. Who did what, and when, can never change. A delete happens only inside the account purge. Anything else raises `AS002`.

**Erasure.** `api.anonymize_customer(store, phone, idempotency_key)` is owner only. Staff are refused even with `customers.delete`. It covers Phase 1 BR-72. For every delivered, rejected, cancelled or returned order of that store whose first or second phone matches, it:

- clears the customer's name, both phones, area, landmark, address details and customer note, and sets `customer_anonymized_at`;
- rebuilds the search fields, so the order can no longer be found by those values;
- replaces those values in the order's audit rows with `[redacted]`;
- deletes stored idempotency responses for those orders, which repeated the contact data;
- writes a `customer.anonymize` audit row holding counts only.

| Kept | Removed |
|---|---|
| Status, number, lines, prices, totals, fee, discount, COD | Name, phones, area, landmark, address details, customer note |
| Status history, stock movements, returns | The same values inside the order's audit rows |
| Who approved, edited and closed, and when; zone name; the seller's internal note | Stored API responses for those orders |

Orders still in progress keep their data and are reported as `skipped_in_progress`, so a delivery is never broken. The function is idempotent. Its stored request holds a hash of the phone, not the phone. Other customers and other sellers' orders are untouched.

## 4. How to run the tests

```bash
bash supabase/tests/run_db_tests.sh                     # 13 suites, 538 assertions
eval "$(supabase status -o env | grep -E '^(JWT_SECRET|API_URL|PUBLISHABLE_KEY)=')"
SUPABASE_TEST_URL=$API_URL SUPABASE_TEST_PUBLISHABLE_KEY=$PUBLISHABLE_KEY SUPABASE_TEST_JWT_SECRET=$JWT_SECRET \
  python3 -I supabase/tests/api/ai_role_api_test.py      # 17 HTTP checks, local stack only
```

The HTTP test refuses any non-local URL. Unlike pgTAP, it leaves its two test sellers in the local database.

## 5. Open points for Phase 8

> Phase 8 resolved points 1 and 3, and part of 4 and 5: see [Phase 8 H §2](../phase-8/h-phase-8-completion-report.md#2-known-risks-from-the-hardening-report-and-how-this-phase-addresses-them).
> Phase 8.5 resolved point 4 (order notes are now redacted on anonymisation): see [Phase 8.5 E](../phase-8.5/e-customer-data.md).

1. **Issuing AI tokens in production.** The local test mints `aisellia_ai` JWTs with the project's JWT secret. In production that secret must stay in the server-side AI worker only, never in the app. A short-lived token or asymmetric signing keys are preferable. This has not been decided or deployed.
2. **Refused calls count toward the per-minute rate**, including validation failures. This is intentional, against probing, but should be revisited with real traffic.
3. **The client shows the `ai` actor as "System".** Phase 8 adds the label and the UI.
4. **Not redacted on anonymisation:** status-event notes, `closed_note`, `courier_note`, `payment_note` and `internal_note`. These are seller-written, but they could contain customer details.
5. **No UI yet** for grants or customer deletion; they are API only.
6. **Anonymisation matches by phone number only.** A customer who used another number must be anonymised per number.
