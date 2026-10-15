# ADR-003: Tenant isolation by store_id, membership and RLS

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
Different sellers must never see or change each other's data. Phase 1 P0 has one owner per store, with staff in P1, and the data model must allow many-to-many.

## Options considered
(a) A schema or database per tenant. (b) **A shared schema with `store_id` on every business row, plus RLS through a membership check.** (c) Application-level filtering only.

## Decision
Use a shared schema. Every business table carries a non-null `store_id`. Composite foreign keys `(store_id, id)` prevent cross-tenant references. RLS SELECT policies use `app.is_member(store_id)`. Storage object paths start with `store_id`. Details in [authorization-and-tenancy.md](../authorization-and-tenancy.md).

## Consequences
Simple operations at pilot scale. One failing policy could expose data, so negative tests for every table and function are mandatory.

## Risks
Policy mistakes; `service_role` misuse in Edge Functions.

## Reconsider when
An enterprise customer requires physical isolation, or tenant count or size makes a shared schema impractical.
