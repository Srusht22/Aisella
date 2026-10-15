# ADR-008: Background work: Supabase Queues (pgmq) + pg_cron + Edge Functions

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
P0 needs scheduled jobs (reconciliation, idempotency-key cleanup, deletion after the grace period, retention purges). P1 needs webhook processing and send retries.

## Options considered
(a) **Postgres-native queues and cron.** (b) An external queue such as SQS or Pub/Sub. (c) A dedicated worker server.

## Decision
Use pgmq queues and pg_cron schedules that invoke Edge Functions or SQL procedures. A visibility timeout gives retries; a dead-letter table catches poison messages.

## Consequences
No extra infrastructure; jobs are transactional with the data.

## Risks
Throughput limits are irrelevant at pilot scale.

## Reconsider when
Sustained queue latency above 1 minute or volumes beyond a single database's comfort.
