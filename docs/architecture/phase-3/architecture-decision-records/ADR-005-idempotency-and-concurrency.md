# ADR-005: Idempotency keys and optimistic versioning for mutations

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
Mobile networks drop responses; sellers double-tap; webhooks are delivered more than once.

## Options considered
(a) Rely on UI debouncing. (b) **Server-side idempotency keys plus row versions.** (c) Exactly-once messaging infrastructure.

## Decision
Retryable mutations take a client-generated UUID `idempotency_key`. The server stores `(user_id, key) → request_hash, response` for 7 days and replays the stored response. Reusing a key with a different request returns `IDEMPOTENCY_KEY_REUSED`. Edits take `expected_version` and return `CONFLICT_VERSION` on mismatch. Webhooks deduplicate on `(channel, external_event_id)`. Prototype T6 and T11 confirm the behaviour.

## Consequences
Safe retries everywhere; the client must keep the key for the lifetime of one user intent.

## Risks
Keys reused across intents by client bugs; tested in Flutter unit tests.

## Reconsider when
—
