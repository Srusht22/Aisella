# ADR-013: Client session storage in the platform keystore

**Status:** Proposed (Phase 3) · **Date:** 2026-10-15 · **Supersedes:** —

## Context
`supabase_flutter` persists the session (including the refresh token) using a pluggable local storage.

## Options considered
Default storage; secure storage.

## Decision
Provide a `LocalStorage` implementation backed by `flutter_secure_storage` (Keychain or Keystore). Clear it on sign-out. The anon key is public by design and is protected by RLS; **no** service-role or provider key ever reaches the client.

## Consequences
Tokens are protected at rest.

## Risks
Device compromise remains out of scope.

## Reconsider when
A platform keystore incompatibility found in Phase 5.
