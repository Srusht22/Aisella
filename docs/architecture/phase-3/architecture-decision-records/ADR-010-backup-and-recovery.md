# ADR-010: Backups: daily platform backups + nightly encrypted logical dump; PITR deferred (needs approval)

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
Phase 1 NFR-10 *proposed* PITR of at least 7 days. Supabase Pro includes 7 days of daily backups. PITR is an add-on (about $100/month for 7 days) that also requires at least Small compute *(verify)*, which would roughly multiply pilot infrastructure cost several times over.

## Options considered
(a) Daily backups only. (b) **Daily backups plus a nightly encrypted logical dump to separate storage.** (c) Enable PITR now.

## Decision
Option (b) for the pilot: recovery point objective ≤ 24 h, plus a **restore rehearsal before the pilot**. Enable PITR before commercialization or when daily order volume makes 24 h of loss unacceptable. **This deviates from the NFR-10 proposal and requires owner approval (AD-05).**

## Consequences
Up to 24 h of data could be lost in a disaster; mitigated by the small pilot and seller-side chat history.

## Risks
A dump job failure goes unnoticed (alert on job failure).

## Reconsider when
More than about 20 orders per day per seller, or any paying customer.
