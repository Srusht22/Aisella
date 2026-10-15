# ADR-002: All business mutations go through database functions; clients may only read

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
Phase 1 requires server-enforced rules (approval, stock, transitions, audit). With Supabase, clients could write tables directly under RLS, but RLS `WITH CHECK` cannot express multi-row invariants (stock deduction plus status plus history in one transaction).

## Options considered
(a) Direct table writes under RLS plus triggers. (b) **RPC functions for every mutation; SELECT-only grants on tables.** (c) A custom API service.

## Decision
Grant the `authenticated` role **SELECT only** on business tables (filtered by RLS). Every mutation is a `SECURITY DEFINER` function in schema `api` with `search_path = ''`. Each function (1) resolves `auth.uid()`, (2) checks membership and permission explicitly (a definer function bypasses RLS, so it never relies on it), (3) validates, (4) mutates in one transaction, (5) writes audit and history, and (6) honours an idempotency key where the operation is retryable. Functions callable only by trusted server code live in schema `internal`, are executable only by `service_role`, and are never reachable by end users.

## Consequences
One uniform authorization point, which is easy to test with pgTAP and negative tests. More SQL code. The client contract is a stable list of named operations ([api-and-service-contracts.md](../api-and-service-contracts.md)).

## Risks
A function that forgets its explicit membership check is a cross-tenant hole. Mitigations: a shared `app.require_member(store, permission)` helper, code review checklist, and a mandatory negative test per function ([testing strategy](../testing-and-quality-strategy.md)).

## Reconsider when
Business logic becomes hard to maintain in plpgsql (for example more than about 3,000 lines), which would justify moving orchestration into a typed service while keeping the same contracts.
