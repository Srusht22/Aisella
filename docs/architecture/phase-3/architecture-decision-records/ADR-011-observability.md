# ADR-011: Observability: Sentry + Supabase logs + domain health tables

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
The pilot needs crash visibility, error IDs for support, and AI and channel health without heavy tooling.

## Options considered
Sentry, Crashlytics, a full OpenTelemetry stack.

## Decision
Use **Sentry** (client and Edge Functions) with PII scrubbing; Supabase platform logs; `ai_runs` and (in P1) `channel_connections` health fields queried by an ops view; alerts through Sentry plus a daily summary job.

## Consequences
Low cost and effort.

## Risks
The free Sentry quota may be exceeded *(verify)*.

## Reconsider when
More than one on-call person, or service-level objectives agreed with paying customers.
