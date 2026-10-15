# ADR-007: AI: Claude via an Edge Function; structured output; the server renders facts

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
The AI must use trusted data, never mutate authoritative state, and never invent prices or stock (Phase 1 §8).

## Options considered
(a) Call the AI from the client (rejected: key exposure). (b) **A server-side Edge Function with an `AiProvider` interface.** (c) A self-hosted model (rejected: ops cost, quality in Sorani unproven).

## Decision
The Edge Function `ai-assist` loads context **with the caller's JWT** (so RLS applies), minimises personal data, and calls `claude-opus-5-5` with a JSON-schema structured output. It validates the schema and business references, then writes drafts and suggestions through `api.*` functions. Prices, fees and totals in replies are **placeholders rendered by the server** from catalog data. Full design in [ai-integration-architecture.md](../ai-integration-architecture.md).

## Consequences
The AI can be wrong but cannot cause a committed business change. Costs are proportional to usage.

## Risks
Cost (AD-07), latency, and Sorani quality (evaluated before the pilot).

## Reconsider when
The evaluation set shows a cheaper tier performs equally well; provider terms are unacceptable; latency exceeds the targets.
