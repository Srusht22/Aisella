# C. Business data retrieval

`app.ai_build_context(run)` builds the model's context inside the database when the worker claims a run. It starts from the run's own store and conversation, so **it cannot contain another store's rows**, whatever the worker or the model asks for.

| Part | Source (current rows) | What is sent | What is never sent |
|---|---|---|---|
| Store | `stores` | Name, currency, default reply language, enabled payment methods | Contact phone, owner, account data |
| Policies | `store_policies` (active) | id, topic, text | Inactive policies |
| Zones | `delivery_zones` (active) | id, name, whether a delivery-time text exists | Fees (rendered by the server) |
| Catalog | Active products and variants | Product id, name, category, description (≤ 400 chars), option types; variant id, label, options, SKU, current price (for budget reasoning), availability label | Stock counts (only in_stock / low / out / available / unavailable, Phase 1 D-11), archived or inactive items, cost data |
| Conversation | Last 20 messages, ≤ 12,000 characters | Message id, from customer / seller, text with phone numbers and e-mails replaced by `[PHONE_n]` / `[EMAIL_n]` | Real phone numbers, e-mails, other conversations |
| Draft | The conversation's AI order, if any | Status, which fields are set, which the seller edited, lines, issues | Customer values already on the order, internal note, totals |
| State | `conversations` | Last intent and missing fields | — |

**Catalog size.**
- Up to 400 active variants (`assist_catalog_full_max_variants`): the whole catalog is sent, and cached as part of the store-context prompt block.
- Larger catalogs: the 40 variants (`assist_catalog_candidates`) whose names, labels, SKUs and categories best match the conversation text (`pg_trgm` word similarity), plus every variant already on the draft. `catalog_is_partial` tells the model.
- There is no vector database; Phase 3 found no need at pilot catalog sizes.

**Freshness.**
- The context is read at claim time, a few seconds before the model call.
- Facts are rendered again **at completion time** from current rows. A price or stock change between the two is reflected in the reply.
- A product archived in between renders nothing, and the reply falls back to the holding reply.
- Draft lines are priced at completion from the catalog. Approval revalidates prices and stock again (Phase 7, BR-23).

**Missing information.**
- **No written policy:** there is nothing to reference. A `policy_text` reference to anything else is an invalid reference, and only the holding reply is offered. The prompt tells the model to say the owner will confirm, or to escalate.
- **No delivery time for a zone:** `has_time_text: false`, and a `zone_time_text` reference fails.
- **Product not in the catalog:** there is no id the model can use. An order line becomes `not_in_catalog`, and a reply naming it can only use text, which may not state a price (reply guard).
- **Ambiguous product or variant:** up to 3 candidates. Unresolved lines are never auto-selected (Phase 1 §8.4).
