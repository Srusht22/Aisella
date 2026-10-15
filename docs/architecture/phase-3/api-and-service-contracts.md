# API and service contracts

**Phase 3** · Status: **Proposed — pending owner approval** · Related: [data model](backend-and-data-model.md), [authorization](authorization-and-tenancy.md), [AI](ai-integration-architecture.md)

> These contracts are **conceptual**. They describe Supabase PostgREST reads, RPC calls to `api.*` functions, and Edge Function endpoints. Shapes are illustrative examples with **sample data**; exact signatures are fixed in Phases 5–8. No REST layer is added beyond what Supabase provides (ADR-002).

## 1. Transport
| Kind | How | Auth |
|---|---|---|
| Reads | PostgREST `GET /rest/v1/<view or table>?select=…` with filters, or `supabase.from(…).select()` | User JWT; RLS |
| Mutations | `POST /rest/v1/rpc/<function>` (`supabase.rpc`) | User JWT; function checks |
| Edge Functions | `POST /functions/v1/<name>` | User JWT, verified inside the function |
| Files | Storage upload with the user JWT (the policy checks the path), downloads via short-lived signed URLs | User JWT |
| Webhooks (P1) | `POST /functions/v1/channel-webhook-<channel>` | Platform signature, no user JWT |

## 2. Common conventions

**Success envelope** (RPC and Edge):
```json
{ "ok": true, "data": { "...": "..." } }
```

**Error envelope.** Business errors are *returned*, not thrown, so the client receives structured codes. Unexpected errors are logged with a reference, and the client sees only `INTERNAL` plus the reference.
```json
{ "ok": false,
  "error": { "code": "INSUFFICIENT_STOCK",
             "message_key": "error.insufficient_stock",
             "details": { "items": [ { "item_id": "…", "requested": 2, "available": 1 } ] },
             "ref": "7F3K-21" } }
```

| Code | Meaning | HTTP (Edge) | Client handling ([Flutter §8](flutter-architecture.md#8-error-handling)) | Retry? |
|---|---|---|---|---|
| `VALIDATION_FAILED` | Field errors in `details.fields{name: rule}` | 422 | Field errors | After fixing |
| `UNAUTHENTICATED` | Missing or expired JWT | 401 | Refresh → GL-02 | Same key |
| `FORBIDDEN` | Lacks permission, or not an end user | 403 | GL-03 | No |
| `NOT_FOUND` | Missing **or not in your store** | 404 | GL-04 | No |
| `CONFLICT_VERSION` | Stale `expected_version` | 409 | Reload | After reload |
| `INVALID_TRANSITION` | The status does not allow this | 409 | Show the current state | No |
| `INSUFFICIENT_STOCK`, `PRICE_CHANGED`, `LINE_UNAVAILABLE`, `INCOMPLETE_ORDER`, `EMAIL_NOT_VERIFIED`, `CURRENCY_LOCKED`, `LIMIT_EXCEEDED` | Business rules | 409 / 422 | Screen-specific | After the user acts |
| `IDEMPOTENCY_KEY_REUSED` | Same key, different payload | 409 | Bug; report | New intent |
| `RATE_LIMITED` | Too many requests (`details.retry_after_s`) | 429 | Banner | After the wait |
| `AI_UNAVAILABLE`, `AI_TIMEOUT`, `AI_INVALID_OUTPUT` | AI path failures | 503 / 504 / 502 | GL-08 / composer error | Yes (same key) |
| `UPSTREAM_ERROR` | SMTP or channel provider | 502 | Retry | Yes |
| `INTERNAL` | Unexpected (reference only) | 500 | P-ERR-* with the reference | Yes (same key) |

**Rules:**
- **Never returned to clients:** stack traces, SQL text, constraint names, table names, provider messages, secrets.
- **Idempotency:** every mutation marked "retry: key" takes `p_idempotency_key uuid` (RPC) or an `Idempotency-Key` header (Edge). The client creates the key per user intent ([Flutter §4](flutter-architecture.md#4-state-management-riverpod-3)).
- **Concurrency:** edits take `p_expected_version`.
- **Pagination:** keyset (`created_at`, `id`) with `limit` ≤ 50. No offset pagination on large lists.
- **Timeouts:** PostgREST statement timeout of 8 s for user roles (proposal); client timeouts in the Flutter doc; `ai-assist` uses a 30 s provider timeout inside a 35 s client timeout.
- **Rate limits (proposals, enforced server-side):**
  - Auth: Supabase built-in limits.
  - `ai-assist`: 30 requests per store per 10 minutes and a daily per-store cap (AD-07).
  - Imports: 60 per store per 10 minutes.
  - Other mutations: 120 per user per minute.

  Counters are kept in Postgres (sliding window per store or user).
- **Versioning:** function names are the contract. A breaking change creates `…_v2` while the old version is kept for one app release.

## 3. Operations by group

Notation used in the tables below: **P** = permission, **I** = inputs, **O** = outputs, **V** = validation failures, **C** = conflict behaviour, **R** = retry, **A** = audit.

### 3.1 Authentication and session
Uses Supabase Auth endpoints through `supabase_flutter`:
- sign-up, sign-in, refresh;
- password reset (the same response regardless of whether the account exists);
- resend verification;
- sign-out (revokes the refresh token).

Account deletion is the Edge Function `account-delete`:
- **P:** the user themselves, after re-authentication within the last 5 minutes.
- **O:** `{execute_after}`.
- **A:** ✓.

### 3.2 Store and settings
| Operation | P | I | O | V | C | R | A |
|---|---|---|---|---|---|---|---|
| `api.create_store` | Authenticated user without a store (P0) | name, contact_phone, currency, reply_locale, city | store_id | name 1–60, phone, currency enum | Second store in P0 → `LIMIT_EXCEEDED` | Key | ✓ |
| `api.update_store` | `settings.manage` | Fields, expected_version | store | Same; currency change after lock → `CURRENCY_LOCKED` | Version | Key | ✓ |
| `api.upsert_zone` / `api.deactivate_zone` | `settings.manage` | name, fee, time_text | zone | fee integer ≥ 0, unique name | Version | Key | ✓ |
| `api.upsert_policy` / `api.delete_policy` | `settings.manage` | topic, body | policy | ≤ 1,000 characters | Version | Key | ✓ |
| `api.update_profile` | Self | ui_locale, digit_style, theme, reduced_motion | profile | Enums | — | Safe | — |

### 3.3 Catalog and inventory
| Operation | P | I | O | V | C | R | A |
|---|---|---|---|---|---|---|---|
| `api.upsert_product` | `catalog.edit` (+`catalog.price`) | Product fields, option_types, variants[] (option_values, price_override, sku, initial stock for new tracked variants), expected_version | product with variants | Phase 1 US-010/011 limits; SKU unique; price > 0; stock ≥ 0 integer | Version | Key | ✓ (prices) |
| `api.set_product_status` | `catalog.edit` | status (active, inactive, archived) | product | Delete of a referenced product → archive only | Version | Key | ✓ |
| `api.adjust_stock` | `inventory.adjust` | variant_id, mode (add/remove/set), qty, reason, note | movement, new stock | result ≥ 0; reason required | Row lock; returns current stock in `details` on `VALIDATION_FAILED` | Key | ✓ |
| Image upload | `catalog.edit` | Storage PUT `store-media/{store_id}/products/{product_id}/{uuid}.jpg`, then `api.attach_image` | image row | ≤ 5 per product; MIME; size | — | Upload retry | ✓ |
| Reads | member | `v_product_list` (name, price range, stock state), variants, `inventory_movements` | — | — | — | — | — |

### 3.4 Customers
| Operation | P | I | O | Notes |
|---|---|---|---|---|
| `api.upsert_customer` | `customers.edit` (P0 owner) | name, phones[], addresses[] | customer, plus `match_suggestion` when a phone matches another customer | Never merges silently (US-041) |
| `api.anonymize_customer` | `customers.delete` | customer_id | ok | Anonymises orders' snapshots; audit ✓ |

### 3.5 Conversations and messages
| Operation | P | I | O | V / C | R | A |
|---|---|---|---|---|---|---|
| `api.create_conversation` | member | source (manual:…/sandbox), customer_id? | conversation | Sandbox flag immutable | Key | — |
| `api.import_messages` | member | conversation_id, texts[] (≤ 4,000 characters total), split flag, include_own flag | messages (state `imported`) | Empty → `VALIDATION_FAILED` | Key (no duplicates) | — |
| `api.record_reply_copied` | member | suggestion_id or text, edited flag | outbound message `copied` | — | Key | — |
| `api.mark_message_sent_by_seller` | member | message_id | state `marked_sent` | Only from `copied` | Key | — |
| `api.set_conversation_status` | member | status (closed, waiting), `handled` for escalations | conversation | Escalation can only be cleared explicitly | Version | ✓ (escalation) |

### 3.6 AI assistance: Edge Function `ai-assist`
**Purpose:** a grounded reply suggestion, plus a draft proposal when buying intent is present.
**Caller:** app (user JWT).
**P:** member.

**Request** (conceptual):
```json
POST /functions/v1/ai-assist
Idempotency-Key: 6c1e…   (new key per "generate/regenerate" intent)
{ "store_id": "…", "conversation_id": "…", "mode": "reply_and_extract" }
```

**Response** (success; sample data):
```json
{ "ok": true, "data": {
  "ai_run_id": "…",
  "suggestion": {
    "id": "…", "status": "suggested",
    "text": "The Beige Abaya in size M is available, price 35,000 IQD. Delivery to Erbil is 5,000 IQD. Please send your name and phone number to order.",
    "facts_used": [ {"type": "variant_price", "id": "…"}, {"type": "zone_fee", "id": "…"} ],
    "missing_fields": ["customer_name", "phone"],
    "escalation": { "required": false, "reasons": [] } },
  "draft": { "order_id": "…", "status": "draft", "issues": [ {"field": "customer_name", "kind": "missing"} ] },
  "intent": "price_inquiry" } }
```

| Aspect | Contract |
|---|---|
| **Validation failures** | `NOT_FOUND` (conversation not in store); `VALIDATION_FAILED` (no inbound messages) |
| **AI failures** | `AI_TIMEOUT`, `AI_UNAVAILABLE`, `AI_INVALID_OUTPUT` (nothing persisted except the `ai_runs` failure row); `RATE_LIMITED` |
| **Conflict** | If the seller edited draft fields since the last run, those fields are kept ("seller edits win"); the response lists the `skipped_fields` |
| **Retry** | Same key → the stored result. Regenerate → new key, and the previous suggestion becomes `superseded`. |
| **Audit** | `ai_runs` row (always); draft creation and update audited |

### 3.7 Orders: review, approval, lifecycle
| Operation | P | I | O | V | C | R | A |
|---|---|---|---|---|---|---|---|
| `api.create_order` (manual) | `orders.create_draft` | customer, delivery, lines[{variant_id, qty}], payment, notes | order (draft or pending) | References in store; qty 1–999 | — | Key | ✓ |
| `api.update_draft` | `orders.edit_draft` | order_id, expected_version, patch (field-level: customer, delivery, line ops: add, remove, resolve, set_qty, confirm_inferred, choose_conflict), discount (owner) | order (re-evaluated status, issues[]) | Field rules; discount ≤ subtotal | `CONFLICT_VERSION` | Key | ✓ (before and after) |
| **`api.approve_order`** | `orders.approve` + end user + verified email | order_id, expected_version, price_choices{item_id: quoted\|current} | order (approved, totals, stock_after[]) | `INCOMPLETE_ORDER`, `PRICE_CHANGED`, `INSUFFICIENT_STOCK`, `LINE_UNAVAILABLE`, `EMAIL_NOT_VERIFIED` | `CONFLICT_VERSION`; `INVALID_TRANSITION` (already approved, shown as success) | Key | ✓ + event |
| `api.reject_draft` | `orders.reject` | order_id, expected_version, reason, note | order (rejected) | Reason required | Version / transition | Key | ✓ + event |
| `api.edit_approved_order` | Owner (P0) | order_id, expected_version, patch | order + stock_diff[] | Only approved or processing; `INSUFFICIENT_STOCK` for increases | Version | Key | ✓ |
| `api.cancel_order` | `orders.cancel` + end user | order_id, expected_version, reason | order (cancelled), restocked[] | Only approved or processing | Version / transition | Key | ✓ + event |
| `api.transition_order` | `orders.fulfil` + end user | order_id, expected_version, to (processing, dispatched, delivered, delivery_failed), payload (courier_note, failure_reason, cod_collected) | order | Transition table; dispatch needs delivery details | Version / transition | Key | ✓ + event |
| `api.record_return` | `orders.fulfil` + end user | order_id, lines[{item_id, restock_qty, writeoff_qty}] | order (returned) | Every line decided; sums = qty | Transition | Key | ✓ + event + movements |
| `api.record_cod` | `orders.fulfil` | order_id, amount | order (cod_collected) | ≤ outstanding | — | Key | ✓ |
| `api.order_confirmation_text` | member | order_id, locale | text | Only for approved and later (BR-04) | — | Safe | — |
| Reads | member | `v_order_list`, `v_order_detail` (with lines, events, issues) | — | — | — | — | — |

**Approval example** (conceptual; sample data):
```json
POST /rest/v1/rpc/approve_order
{ "p_order_id": "0b9…", "p_expected_version": 7,
  "p_idempotency_key": "f1d2…", "p_price_choices": {} }

→ { "ok": true, "data": { "order_id": "0b9…", "number": 1042, "status": "approved", "version": 8,
     "total": 75000, "cod_due": 75000,
     "stock_after": [ { "variant_id": "…", "label": "Beige Abaya · M", "before": 4, "after": 2 } ] } }

→ { "ok": false, "error": { "code": "PRICE_CHANGED", "message_key": "error.price_changed",
     "details": { "items": [ { "item_id": "…", "quoted": 35000, "current": 38000 } ] }, "ref": "…" } }
```

### 3.8 Reporting
| Read | Definition |
|---|---|
| `v_today_attention(store_id)` | Counts per Phase 1 Journey G, excluding test orders |
| `v_summary(store_id, from, to)` | Approved count and value, delivered count, COD outstanding. Committed statuses only (approved, processing, dispatched, delivered, delivery_failed); excludes `is_test`, rejected, cancelled, returned (Phase 1 US-043) |

Each figure has a matching filtered list query, so totals reconcile (tested).

### 3.9 Channel connections (P1, outline)
- `channel-connect` (Edge): starts the OAuth or bot-token flow.
- `channel-callback`: verifies `state` (bound to user and store), stores the token in Vault, creates `channel_connections`.
- `api.disconnect_channel` → Edge revokes, deletes the Vault secret, marks disconnected.

Health is read through `v_channel_health`. Full design in [messaging-integration-architecture.md](messaging-integration-architecture.md).

### 3.10 Media
- **Upload:** compress on the client to 1600 px on the long edge, JPEG quality about 80, EXIF stripped; then `PUT` to Storage; then `api.attach_image`.
- **Display:** signed URLs valid for 1 hour, cached by URL path. Orphaned uploads (no `attach_image` within 24 h) are purged by a job.
