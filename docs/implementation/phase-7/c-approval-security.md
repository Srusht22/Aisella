# C. Approval security

## 1. The gate
`api.approve_order` is the **only** path to `approved`. In order:

1. **Caller.** `app.require_end_user()` refuses anonymous callers and any token whose role isn't `authenticated`, including `service_role`, so a backend or AI process cannot approve. The caller must be the store's **owner**: a staff member is refused even with an `orders.approve` permission (P0, decision P7-D3). The account's email must be confirmed (`EMAIL_NOT_VERIFIED`).
2. **Idempotency.** The key replays a stored answer; a different request under the same key is refused.
3. **Lock** the order row. A non-member, another store's id or a random id gets `NOT_FOUND`.
4. **Status and version.** A draft gives `INCOMPLETE_ORDER` with the issues. Any status other than `pending_approval` gives `INVALID_TRANSITION`. A stale version gives `CONFLICT_VERSION`.
5. **Completeness** is checked again (defensive).
6. **Lock** the products (`FOR SHARE`) and then the variants (`FOR UPDATE`), each in ascending id order.
7. **Re-validate every line** against the catalog as it is now:
   - unavailable (archived, inactive, untracked and unavailable) → `LINE_UNAVAILABLE`;
   - short → `INSUFFICIENT_STOCK` with requested and available;
   - a price that differs from the quote without a choice → `PRICE_CHANGED` with quoted and current.

   All or nothing: any refusal leaves the order and the stock unchanged.
8. **Deduct stock** with an `order_approved` movement for each tracked line, and set the approved prices and frozen snapshots.
9. **Commit.** Recompute the totals; set `approved_by`, `approved_at`, `cod_due` and the version; lock the store currency; write the status event and the audit row; store the idempotency answer.

Nothing in the app can approve without the OR-03 confirmation sheet. The sheet:
- ignores taps for 400 ms;
- requires an explicit price choice per changed line;
- shows the stock after approval;
- states that the customer is not messaged.

Creating, editing or saving a manual order never approves it. "Save and approve…" saves first, then opens the same sheet (BR-31).

## 2. Values the server never takes from the client
The order payload accepts only documented fields. These are refused as `VALIDATION_FAILED` with `{field: "unknown"}`, not ignored:
- `status`, `total`, `subtotal`, `approved_by`, `store_id`;
- a line `unit_price` or any other price.

Server-side values:
- prices, snapshots and fees come from the catalog and the zone;
- totals and status come from the server;
- the store is the one named in the request **and** authorized for the caller;
- a zone or variant from another store reads as `invalid` / `unknown`, exactly like a random id.

Tested:
- pgTAP `08` §"Nothing the server computes can be sent";
- the real-stack test "values the app must not decide are refused".

## 3. Repeats, races and lost answers
| Situation | Result |
|---|---|
| Double tap in the sheet | The input guard plus one key: one call (widget test) |
| Answer lost (timeout) | The app repeats once with the **same key**; the server replays the result (widget test: two calls, one approval) |
| Same order approved from 8 devices at once (new keys) | The order lock serializes them: exactly 1 succeeds, 7 get `INVALID_TRANSITION` with `current_status = approved`, stock is deducted once (real stack) |
| 6 orders compete for 3 units | Exactly 3 approvals succeed, 3 get `INSUFFICIENT_STOCK`, stock ends at 0 (real stack) |
| Approved meanwhile on another device | The app reports "already approved. Nothing changed." and shows the order |
| 5 simultaneous cancels | 1 succeeds, stock is restored once (real stack) |

## 4. Storage-level defence
Even a privileged SQL write cannot:
- change status outside the BR-30 table (for example rejected → approved, pending → delivered);
- set `approved` without an approver and a time (CHECK);
- insert an order as approved;
- rewrite or delete status history;
- delete an order or an ordered variant.

`authenticated` has no write privilege on any order table. RLS restricts reads to members. The transition table isn't readable by clients.

## 5. Tenant isolation
`10_order_isolation` (30 assertions) uses two sellers. Seller B gets `NOT_FOUND` from all 12 order functions on A's approved and pending orders, both through A's store id and through B's own. B also cannot:
- list or count A's orders, or find them by search;
- create in A's store;
- use A's products or zone on B's own orders.

RLS hides A's orders, lines, history and order movements, and direct writes are refused. Afterwards A's orders and stock are unchanged and anonymous calls are refused.

The real-stack test repeats the main checks through PostgREST with real tokens. Order numbers are per store: B also starts at #1001.

## 6. Guards updated
`01_catalog_guards` now has 17 assertions. It covers:
- the reviewed `api` list with the 15 new functions;
- every new table has RLS and no write grants;
- the history and transition guards exist;
- the transition table holds exactly 15 rows;
- `approved` is reachable only from `pending_approval` through `approve`.
