# ADR-009: Region eu-central-1 and the network-reachability contingency

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
No Supabase Middle East region is listed. Supabase documented ISP-level blocks of `supabase.co` in the UAE (2025), Yemen and India (2026). Iraqi reachability is unknown.

## Options considered
Frankfurt; Mumbai; another provider.

## Decision
Use **Frankfurt (eu-central-1)**, subject to the M0 checks: (1) reachability and latency from pilot sellers' real networks (mobile and fixed); (2) behaviour with a Supabase custom domain. The client takes its API base URL from build configuration so that a custom domain or a thin reverse proxy can be introduced without an app redesign.

## Consequences
Region change later means migrating the project.

## Risks
Blocks or high latency; a custom domain may not help with IP-level blocks.

## Reconsider when
M0 measurements fail (block, or p90 latency above about 400 ms for simple reads).
