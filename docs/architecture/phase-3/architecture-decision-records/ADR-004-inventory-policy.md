# ADR-004: Inventory: deduct at approval; ledger plus maintained balance; no draft reservations

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
Phase 1 BR-14, BR-15 and BR-20 to BR-22. AI drafts for chats that never convert must not lock stock. Duplicate or concurrent approvals must not double-deduct.

## Options considered
(a) Reserve at draft. (b) **Deduct at approval.** (c) Deduct at dispatch. For storage: (i) a balance column only, (ii) a ledger only, computing the sum on read, (iii) **a ledger plus a balance column maintained in the same transaction.**

## Decision
Deduct at approval, all-or-nothing, with row locks on the variants in deterministic order. Every change is an append-only `inventory_movements` row written in the same transaction as `product_variants.stock_on_hand`. A `CHECK (stock_on_hand >= 0)` acts as a backstop. A scheduled reconciliation verifies that balance equals the sum of movements. Proven in the prototype: 20 parallel approvals for 5 units gave exactly 5 approved, 15 INSUFFICIENT_STOCK, invariant held.

## Consequences
Approval can fail with INSUFFICIENT_STOCK when stock was sold meanwhile; the UI handles this (Phase 2 §5.6). Reads stay cheap.

## Risks
Sellers with fast-moving stock may want reservations (P1 option).

## Reconsider when
Pilot data shows frequent approval failures caused by stock sold between draft and approval.
