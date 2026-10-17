# Aisellia — Phase 5: authentication, seller onboarding, store creation and account management

**Status:** Complete. **Waiting for owner approval. Phase 6 has not started.**
**Baselines:**
- [Phase 1 product spec](../../product/phase-1-product-specification.md);
- [Phase 2 design spec](../../design/phase-2/README.md);
- [Phase 3 architecture](../../architecture/phase-3/README.md);
- [Phase 4 foundation](../phase-4/README.md).

Their pending decisions (D-xx, DD-xx, AD-xx) are still used as the working baseline. Phase 5 adds one new decision, **P5-D1**, which needs owner sign-off ([A §3](a-authentication.md#3-decision-p5-d1-verification-before-first-sign-in)).

Phase 5 replaces the Phase 4 placeholders with:
- real authentication through **Supabase Auth** (GoTrue);
- a session kept in the platform keystore;
- one navigation guard driven by server state;
- a store and its onboarding persisted in **Postgres**, with tenant isolation enforced in the database;
- account deletion with re-authentication.

It adds **only** user, store, membership, delivery-zone, audit, idempotency and deletion-request records. Phase 5 contains no catalogue, inventory, orders, AI, messaging, fulfilment, billing or analytics. Nothing has been deployed: all backend work ran against the **local** Supabase stack.

| # | Document | Contents |
|---|---|---|
| A | [Authentication](a-authentication.md) | Provider, configuration, each flow, decision P5-D1 |
| B | [Auth state and protected navigation](b-auth-state-and-routing.md) | Session storage, restore and revoke, `AuthController` (§4), route guard (§5) |
| C | [Onboarding and store creation](c-onboarding-and-stores.md) | Setup steps, persistence, retries and reconciliation, Today checklist |
| D | [Ownership and authorization](d-ownership-and-authorization.md) | Schema, RLS, `api` functions, tenant isolation, account deletion |
| E | [Business settings](e-business-settings.md) | What persists, where, and the rules on each field |
| F | [Localized UI](f-localized-ui.md) | New screens and strings, Sorani/English, RTL fixes |
| G | [Tests and results](g-test-results.md) | Exact commands, results and what each suite proves |
| H | [Setup and configuration](h-setup-and-configuration.md) | Local stack, app config, hosted-project checklist |
| I | [Completion report](i-phase-5-completion-report.md) | Summary, commits, risks, decisions needed, next steps |

In code comments, "Phase 5 §4" refers to [B §4](b-auth-state-and-routing.md#4-application-auth-state) and "Phase 5 §5" refers to [B §5](b-auth-state-and-routing.md#5-protected-navigation).

## Quick start

```sh
supabase start                      # local stack (Docker); see H for details
supabase status -o env              # copy API_URL and PUBLISHABLE_KEY into config/dev.json
flutter run --dart-define-from-file=config/dev.json
bash supabase/tests/run_db_tests.sh # 94 pgTAP assertions
flutter test                        # 144 unit/widget + 27 golden; 11 backend tests skip
SUPABASE_TEST_URL=… SUPABASE_TEST_PUBLISHABLE_KEY=… MAILPIT_TEST_URL=… \
  flutter test --tags backend       # 11 tests against the real local stack
```
