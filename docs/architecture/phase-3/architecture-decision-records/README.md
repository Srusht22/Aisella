# Architecture decision records (Phase 3)

Status of all records: **Proposed — pending owner approval** unless noted. Format: context, options, decision, consequences, risks, reconsideration trigger.

| ADR | Title |
|---|---|
| [ADR-001](ADR-001-backend-platform.md) | Backend platform: Supabase on PostgreSQL |
| [ADR-002](ADR-002-mutations-through-database-functions.md) | All business mutations go through database functions; clients may only read |
| [ADR-003](ADR-003-tenant-isolation.md) | Tenant isolation by store_id, membership and RLS |
| [ADR-004](ADR-004-inventory-policy.md) | Inventory: deduct at approval; ledger plus maintained balance; no draft reservations |
| [ADR-005](ADR-005-idempotency-and-concurrency.md) | Idempotency keys and optimistic versioning for mutations |
| [ADR-006](ADR-006-flutter-state-and-routing.md) | Flutter: Riverpod 3 for state and DI; go_router for navigation |
| [ADR-007](ADR-007-ai-integration-boundary.md) | AI: Claude via an Edge Function; structured output; the server renders facts |
| [ADR-008](ADR-008-background-processing.md) | Background work: Supabase Queues (pgmq) + pg_cron + Edge Functions |
| [ADR-009](ADR-009-region-and-network-reachability.md) | Region eu-central-1 and the network-reachability contingency |
| [ADR-010](ADR-010-backup-and-recovery.md) | Backups: daily platform backups + nightly encrypted logical dump; PITR deferred (needs approval) |
| [ADR-011](ADR-011-observability.md) | Observability: Sentry + Supabase logs + domain health tables |
| [ADR-012](ADR-012-messaging-adapter.md) | Messaging: channel adapters with persisted webhook ingestion (P1) |
| [ADR-013](ADR-013-client-session-storage.md) | Client session storage in the platform keystore |
