# Aisellia — Phase 7: orders, drafts, seller approval and the order lifecycle

**Status:** Complete. **Waiting for owner approval. Phase 8 has not started.**
**Baselines:**
- [Phase 1 product spec](../../product/phase-1-product-specification.md): §6.3–6.5, BR-20…BR-25, BR-30…BR-37, BR-40…BR-44, BR-46;
- [Phase 2 design](../../design/phase-2/04-screen-specifications.md#6-orders): OR-01…OR-11;
- [Phase 3 architecture](../../architecture/phase-3/backend-and-data-model.md#44-orders-and-fulfilment): §4.4 data model, §6.1–6.5 transactions, contracts §3.7;
- [Phase 6 integration contract](../phase-6/e-integration-contract.md): how orders may move stock.

A signed-in seller can now:
- create a manual order, which is saved as a **draft** or as **needs approval** (the server decides from completeness, never approved);
- review an order with live stock, changed prices and unsellable items shown, then **approve it explicitly** in a confirmation sheet. Approval is owner-only and deducts stock atomically;
- reject a draft, cancel an approved order (stock comes back once), and move an order through preparing, out for delivery, delivered (with cash collected), delivery failed and returned (restock or write-off per line);
- edit a draft, or an approved order before dispatch (the stock difference is applied);
- search and filter orders, read the full history, copy a confirmation message to send themselves;
- see real order counts on Today.

Everything is persisted in the local Supabase stack and scoped to the seller's store by the database. Nothing was deployed, and no message is sent to any customer.

| # | Document | Contents |
|---|---|---|
| A | [Data model](a-data-model.md) | Tables, columns, constraints, indexes, JSON contract |
| B | [Order lifecycle](b-order-lifecycle.md) | Statuses, allowed transitions, who may do what, editing rules |
| C | [Approval security](c-approval-security.md) | The approval gate, authorization, trust boundaries, isolation |
| D | [Inventory integration](d-inventory-integration.md) | Stock at approval, edits, cancel, returns; locks; reconciliation |
| E | [Audit and history](e-audit-and-history.md) | Status events, audit rows, what the history screen shows |
| F | [Future integration contract](f-integration-contract.md) | What Phase 8 (AI drafting) and messaging must use and respect |
| G | [Test report](g-test-report.md) | Commands, results, failures found and fixed, what could not be run |
| H | [Completion report](h-phase-7-completion-report.md) | Summary, files, commits, limitations, decisions, next steps |
| I | [Security hardening](i-security-hardening.md) | AI execution role, grants and quotas; retention jobs; customer privacy (added after acceptance) |
