# Design proof: approval, tenancy and inventory consistency

> **Not a migration and not production code.** This is a minimal, throwaway schema used in Phase 3 to check that the proposed design ([ADR-002](../../architecture-decision-records/ADR-002-mutations-through-database-functions.md), [ADR-003](../../architecture-decision-records/ADR-003-tenant-isolation.md), [ADR-004](../../architecture-decision-records/ADR-004-inventory-policy.md), [ADR-005](../../architecture-decision-records/ADR-005-idempotency-and-concurrency.md)) behaves as claimed on real PostgreSQL. Phase 6 and 7 write the real migrations, with full tests.

**What it simulates:**
- Supabase's `auth.uid()` (reading the JWT claim from a session setting)
- The `authenticated` and `service_role` roles
- SELECT-only grants on business tables, with RLS by store membership
- A `SECURITY DEFINER` `api.approve_order` with:
  - explicit owner check
  - email-verification check
  - status and version check
  - deterministic row locks on variants
  - price and stock re-validation
  - an atomic ledger write
  - idempotency-key replay

**How to run:** you need a disposable PostgreSQL 16+ server where you are superuser.

```
PROOF_PSQL_ARGS="-h <host> -p <port> -U <superuser>" bash run.sh
```

It creates and overwrites a database named `proof`.

## Results recorded on 2026-10-15 (PostgreSQL 16.15, local throwaway server)

| # | Check | Result |
|---|---|---|
| T1 | Store B's user selects store A's variants | 0 rows (RLS) |
| T2 | Store A's user selects own variants | 1 row |
| T3 | Store A's user updates `stock_on_hand` directly | `permission denied` |
| T4 | Store B's user approves store A's order | `NOT_FOUND` (no existence leak) |
| T5 | `service_role` (the AI path) approves | `FORBIDDEN` |
| T6 | Two concurrent approvals of the same order | One `approved`; the other `INVALID_TRANSITION` (already approved) |
| T7 | Approving an order needing 2 units with 1 left | `INSUFFICIENT_STOCK` with details; no stock change |
| T9, T12 | Stock equals the sum of movements | true |
| T11 | Replaying a successful approval with the same idempotency key | Identical response; exactly 1 movement for the order |
| T13 | Approval after the catalog price changed, with no seller choice | `PRICE_CHANGED` with quoted and current prices |
| T14 | 20 parallel approvals of different orders competing for 5 units | 5 approved, 15 `INSUFFICIENT_STOCK`, final stock 0, invariant true |

**Not covered here** (covered by the test strategy):
- Supabase's real Auth, PostgREST and Storage policies
- Edit and cancel transitions
- Audit tables
- Performance under load
