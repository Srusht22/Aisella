# ADR-001: Backend platform: Supabase on PostgreSQL

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
Aisellia needs relational data (orders, lines, variants, ledgers), transactional inventory rules, strict tenant isolation, file storage, auth, server-side AI calls and, later, webhooks. A 1–2 person team will run a pilot of 3–5 sellers. Nothing has been provisioned yet.

## Options considered
(a) Supabase: managed Postgres, Auth, Storage, Edge Functions, Cron, Queues. (b) Firebase: Firestore, Auth, Functions, Storage. (c) A custom server plus managed Postgres plus an auth provider.

## Decision
Adopt **Supabase**, with one project per environment (production, staging) and a local stack for development and CI. Evaluation in [technology-decisions.md §2](../technology-decisions.md#2-backend-and-database).

## Consequences
Business invariants can be enforced in the database (constraints, row locks, RLS). Prototype: [proofs](../proofs/approval-consistency/README.md). The team must be competent in SQL, plpgsql and RLS. Edge Functions are TypeScript (Deno), so the backend logic language differs from Dart.

## Risks
Regional network blocking of `supabase.co` (ADR-009). Vendor pricing changes. Edge Function limits for long AI calls (400 s wall clock, 2 s CPU per request; *verify*).

## Reconsider when
Supabase is unreachable from target ISPs without workarounds; Edge Function limits block AI flows; costs exceed about 3× the estimate; a requirement appears that Postgres cannot serve.
