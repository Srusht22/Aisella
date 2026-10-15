# ADR-006: Flutter: Riverpod 3 for state and DI; go_router for navigation

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
Phase 2 requires per-tab stacks, deep links, an auth redirect and consistent async states. Small team.

## Options considered
State: Riverpod, Bloc, Provider, setState. Routing: go_router, auto_route, a hand-written Navigator 2.0.

## Decision
Use **flutter_riverpod 3.x** (Notifier/AsyncNotifier, written by hand without provider code generation, to keep the build simpler) and **go_router 18.x** with `StatefulShellRoute.indexedStack` for the four tabs. Details in [flutter-architecture.md](../flutter-architecture.md).

## Consequences
A single convention for loading, error and data states (`AsyncValue`) and for test overrides.

## Risks
Riverpod major-version churn (2 to 3 happened); pin versions.

## Reconsider when
State complexity needs event sourcing on the client (unlikely), or go_router fails a predictive-back or RTL requirement in Phase 4 testing.
