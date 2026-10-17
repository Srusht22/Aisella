# F. Integration contract for Phase 8 (AI drafting) and messaging

## 1. What an AI draft may and may not do
Phase 8 creates and updates **drafts only**. It must:

1. Run as the seller's request through an `api` function, with the end-user JWT. `service_role` and the AI can never call `approve_order`: `require_end_user` refuses them, and approval is owner-only. There must be no "approve" tool exposed to the model, and no server path that sets `approved`. The transition table and the status trigger forbid it anyway.
2. Use the existing columns, already in the schema:
   - `orders.origin = 'ai'`;
   - `order_items.resolution` (`choose_product`, `variant_needed`, `not_in_catalog`) with `variant_id` null and `customer_text`;
   - `quantity_basis = 'inferred'` for guessed quantities.

   Unresolved lines and inferred quantities are already BR-36 issues (`unresolved`, `quantity_inferred`), so such a draft stays `draft` and cannot be approved until the seller resolves or confirms them.
3. Take prices, fees, names and availability from the catalog and zones (Phase 6 E §1), never from model output (BR-24). The server sets quoted prices and snapshots; the order payload refuses price fields.
4. Respect seller edits: a re-run must not overwrite fields the seller edited (Phase 3 §6.1). Phase 8 needs a per-field provenance record (`orders.provenance` in Phase 3 §4.4 is **not yet a column**) and a dedicated `api` function, for example `upsert_ai_draft(conversation_id, …)`, with one open AI draft per conversation. Phase 8 must add that function and its guards. It must not reuse `update_draft`, which replaces the full state.
5. Never set `is_test` on a real store's order. Test orders (sandbox conversations) must carry `is_test = true`; reports and Today already exclude them, and stock never moves for them.

## 2. Reading orders
| Need | Use |
|---|---|
| Lists and counts | `api.list_orders`, `api.order_summary` (each count equals its list's total) |
| One order | `api.get_order` (`app.order_json`, [A §5](a-data-model.md#5-json-contract)) |
| History | `api.order_history` |
| Missing fields | `issues` in the order JSON (server-computed) |

## 3. Messaging boundary (BR-45…BR-47)
- Phase 7 sends **nothing** to customers. The confirmation message (OR-10) is composed on the device in the store's reply language. The seller copies it, and the app records only the seller's statement "I sent this" (`confirmation_marked_sent_at`). The UI never says "Sent".
- A future live channel must add its own send-attempt records (Phase 3: `channel_send_attempts`). It must reconcile before resending, and may send a confirmation only for `approved` and later (`OrderStatus.canConfirm`). It must never mark `confirmation_marked_sent_at` itself.
- No live WhatsApp, Instagram, Messenger or TikTok integration exists or is stubbed.

## 4. Invariants later phases must keep
- `approved` only through `approve_order`, from `pending_approval`, by the owner, with re-validation under locks.
- Stock moves only in order functions, with order-linked movements. Σ order movements = −Σ `stock_deducted`.
- Status changes only along `app.order_transitions`, and exactly one status event per change.
- Totals = Σ lines − discount + fee, computed by the server.
- Rejected, cancelled and returned orders stay in history (BR-32).
- Every new `api` function is added to `01_catalog_guards` and covered by an isolation suite.
