# ADR-012: Messaging: channel adapters with persisted webhook ingestion (P1)

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
Each channel differs in auth, windows and webhook signing. Duplicate deliveries must not duplicate orders.

## Options considered
A per-channel adapter interface; a third-party aggregator.

## Decision
Use a `ChannelAdapter` interface in Edge Functions: verify signature → persist `webhook_events` (unique per external event ID) → acknowledge fast → enqueue → normalise → process idempotently. Outbound sends go through a send queue with send-state reconciliation. Details in [messaging-integration-architecture.md](../messaging-integration-architecture.md).

## Consequences
Adding a channel means implementing one adapter.

## Risks
Platform policy changes.

## Reconsider when
An aggregator offers verified Iraqi coverage and cost advantages.
