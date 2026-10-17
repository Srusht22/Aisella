# D. Order-draft integration

AI drafts are ordinary Phase 7 orders (`app.orders`). The differences are:
- `origin = 'ai'`;
- `ai_ref = 'conversation:<id>'`;
- `conversations.order_id` links back to the conversation;
- `is_test` is copied from a sandbox conversation.

There is no parallel order system.

## 1. When a draft is written

Inside `api.ai_complete_run`, through `app.ai_merge_draft`, only when all of these hold:
- the output is valid;
- the run is **not escalated**;
- the intent is `place_order`, or the seller pressed "Prepare draft order" (`mode = draft`);
- the extraction proposes at least one value or line.

## 2. Validation (every value is untrusted)

| Proposal | Rule |
|---|---|
| Customer name | Trimmed, ≤ 80 chars |
| Phone, phone2 | Only a token issued for this run (`PHONE_n`), mapped back from the run's server-side map. An unknown token is dropped. |
| Zone | Must be a zone id from this run's context, otherwise dropped. A city text is used when no zone matches. |
| Area, landmark, details, note | Trimmed and length-limited |
| Payment method | Only if the store offers it |
| Contradictions (`conflicts`) | The field is not written; for product, variant or quantity, the lines are not written |
| Lines | Candidates are filtered to the run's ids, this store, active and sellable. 1 candidate is a resolved line priced from the catalog. Several variants of one product are `variant_needed`. Several products are `choose_product` (≤ 3 kept). None is `not_in_catalog`. A missing or invalid quantity becomes 1, marked **inferred**. A quantity above stock is kept and flagged; approval checks stock again. |
| Anything else | Rejected by the strict shape before the merge |

`app.order_field_errors` (the Phase 7 rules) runs on the merged state. A field it refuses is dropped and reported, not forced. The status is computed by the server:
- `pending_approval` only when the order is complete and every line is resolved and confirmed;
- otherwise `draft`, with issues.

## 3. Seller edits and lifecycle

- **Seller edits win.** `update_draft` records the edited fields in `orders.seller_edited`. The AI skips them, and the zone and city are treated as one field.
- **After the seller approves, rejects or cancels,** the AI cannot touch the order. The merge returns `draft_closed`, and the suggestion carries that flag so the seller knows why.
- **Unresolved lines block approval** through their `unresolved` issue. The order screen shows what the customer asked for and the candidates; the seller picks the product in the editor.

## 4. Duplicates

- **One AI order per conversation, ever.** A unique index on `(store_id, ai_ref)` means a repeated run updates the existing draft.
- **A retried request with the same key returns the same run** (unique `(requested_by, idempotency_key)`). The model is not called again (end-to-end test step "a retried request with the same key calls the model once").
- **One run at a time per conversation** (`AI_BUSY`).
- **Lost connection:** if the connection is lost after `ai_complete_run`, the worker reads `ai_run_state` before deciding. It never writes twice blindly (pipeline tests).
- **Daily quota:** at most `drafts_per_store_per_day` (50) new AI orders per store, under an advisory lock.

## 5. The approval gate (non-negotiable)

- `api.approve_order` requires the store owner's own session (`require_end_user`, owner only, `pending_approval` only), unchanged from Phase 7.
- **The worker role has no `EXECUTE` on it** (guard test 01; end-to-end test: `42501`). The seller cannot hand in AI output either.
- **Status values come only from the server.** A `status` key in the output fails it; drafts are created as draft or pending_approval only.
- The reply guard removes "confirmed / approved / sent / shipped" claims in three languages. The customer confirmation text remains the Phase 7 server-generated text for approved orders only, sent by the seller themselves.

**Tests.**
- **pgTAP 15:**
  - complete draft → pending_approval, never approved;
  - after the seller approves, the AI changes nothing;
  - manipulated model output → escalation, no draft;
  - forbidden keys → refused;
  - another store's ids → dropped.
- **Deno end-to-end:** draft pending approval, `approved_by = system` (nobody), worker cannot approve.
