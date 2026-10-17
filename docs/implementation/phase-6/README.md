# Aisellia — Phase 6: product catalog, variants, images and inventory

**Status:** Complete. **Waiting for owner approval. Phase 7 has not started.**
**Baselines:**
- [Phase 1 product spec](../../product/phase-1-product-specification.md): Journey B, US-010…US-017, BR-12…BR-18, BR-64, BR-71;
- [Phase 2 design](../../design/phase-2/04-screen-specifications.md#8-products-and-inventory): PR-01…PR-07, §2.4 inventory indicators, §7 product media;
- [Phase 3 architecture](../../architecture/phase-3/backend-and-data-model.md#42-catalog-and-inventory): §4.2 data model, ADR-002…ADR-005, authorization §3, contracts §3.3 and §4;
- [Phase 5](../phase-5/README.md): auth, store ownership and the `api` conventions this phase reuses.

A signed-in seller can now:
- create, edit, archive and restore products, with up to 2 option types and up to 100 variants;
- add up to 5 photos (camera or gallery), stored privately;
- adjust stock with a reason and read the full inventory history;
- search, filter and sort the catalog.

Everything is persisted in the local Supabase stack and scoped to the seller's store by the database. Nothing was deployed.

| # | Document | Contents |
|---|---|---|
| A | [Data model](a-data-model.md) | Tables, columns, constraints, indexes, JSON contract |
| B | [Inventory rules](b-inventory-rules.md) | Tracking, quantities, adjustments, low stock, concurrency |
| C | [Security and authorization](c-security-and-authorization.md) | Store scoping, RLS, functions, storage policies, tests |
| D | [Image storage](d-image-storage.md) | Bucket, upload pipeline, access, cleanup, configuration |
| E | [Integration contract](e-integration-contract.md) | What Phase 7 (orders) and Phase 8 (AI) must use and respect |
| F | [Test report](f-test-report.md) | Commands, results, failures found and fixed, what could not be run |
| G | [Completion report](g-phase-6-completion-report.md) | Summary, files, migration, commits, limitations, decisions, next steps |
