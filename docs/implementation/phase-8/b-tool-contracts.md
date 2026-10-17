# B. Tool and function contracts

The model has **no callable tools**: it returns one JSON document per run, and every operation below runs on the trusted backend. The model can only *propose* data inside that document. None of these operations is exposed to it.

## 1. Seller functions (role `authenticated`, the seller's own JWT)

Every function requires an end user. The store comes from the caller's membership: another store's id returns `NOT_FOUND`.

| Function | Permission | Input (validated) | Result |
|---|---|---|---|
| `api.list_conversations(store, filter, limit, offset)` | member | filter ∈ open, needs_reply, needs_you, waiting, closed, sandbox, all | Rows and counts |
| `api.get_conversation(store, id)` | member | — | Messages (last 200), current suggestion, last run, draft summary, AI usage |
| `api.create_conversation(store, source, label, messages, key)` | conversations.manage | source enum; 1–20 messages `{direction, body}`, each 1–4,000 chars, 20,000 in total; label ≤ 60 | `{id}`; idempotent. Only a hash of the text is kept with the key. |
| `api.import_messages(store, id, messages, key)` | conversations.manage | As above; at most 2,000 messages per conversation | `{messages_added}`; idempotent |
| `api.record_seller_reply(store, id, body, key)` | conversations.manage | 1–4,000 chars | Saved as `seller_written` / `marked_sent` |
| `api.update_conversation(store, id, version, fields)` | conversations.manage | customer_label, ai_paused, status ∈ needs_reply, waiting, closed (never needs_you) | The conversation |
| `api.request_ai_assist(store, id, mode, key)` | conversations.manage | mode ∈ reply, draft | `{run_id, status, replayed}`. Refused with `AI_DISABLED`, `AI_PAUSED`, `NOTHING_TO_ANSWER`, `AI_BUSY` or `RATE_LIMITED`. |
| `api.get_ai_run(store, run)` | member | — | Run status and error code |
| `api.copy_suggestion(store, suggestion, text?, key)` | conversations.manage | ≤ 4,000 chars | Outbound message, state `copied`, `edited` flag |
| `api.mark_message_sent(store, message)` | conversations.manage | copied → marked_sent only | — |
| `api.dismiss_suggestion(store, suggestion)` | conversations.manage | — | — |
| `api.delete_conversation(store, id)` | owner (`customers.delete`) | — | Messages, suggestions and runs deleted; the order stays |
| `api.list_policies / upsert_policy / delete_policy` | member / settings.manage | topic enum; body 1–1,000 chars; at most 30 per store | Policy rows; audited |
| `api.set_ai_enabled(store, enabled)` | owner (`ai.manage`) | — | Audited |
| `api.ai_usage(store, days)` | `ai.manage` | 1–90 days | Calls, outcomes, tokens, estimated cost per day |

## 2. Worker functions (role `aisellia_ai_worker` only)

| Function | Input | Checks | Result |
|---|---|---|---|
| `api.ai_claim_run(run)` | run id | Run is queued and was created less than 60 s ago; the store's AI is on and the conversation is not paused | `{run_id, mode, context}` (see [C](c-business-data-retrieval.md)). Stores the run's allowed ids and the phone-token map. |
| `api.ai_complete_run(run, output, meta)` | Model output and usage | Run is running and was claimed less than 120 s ago, then the pipeline below | `{status, suggestion_id, order_id, escalated}` or `AI_INVALID_OUTPUT` |
| `api.ai_fail_run(run, status, code, meta)` | status ∈ timeout, provider_error, refused, rate_limited, invalid_output | Run is running | Records the outcome; a refusal sets "Needs you" |
| `api.ai_run_state(run)` | run id | — | Status (for reconciliation) |

**`ai_complete_run` pipeline (in order):**
1. **Strict shape** (`app.ai_output_errors`). Any unknown key fails the whole output with `AI_INVALID_OUTPUT`, including `status`, `price` on a line, `approved_by` or `total`. Nothing is persisted except the run record.
2. **Escalation.** The model's reasons are added to this database's own checks:
   - manipulation patterns in English, Sorani and Arabic in new customer text;
   - order-status questions;
   - a field still unanswered after two clarification rounds.
3. **Reply rendering.** Fact segments become current values. A reference outside the run's ids, or to a missing value, fails the reply.
4. **Reply guard** (`app.reply_guard`). Rejects text segments containing:
   - money (4+ digits, thousands separators, currency words);
   - stock counts;
   - discounts;
   - delivery promises and guarantees;
   - "confirmed / approved / sent / shipped" claims, in English, Sorani or Arabic.

   A failing reply is replaced by the server's holding reply and the reason is flagged.
5. **Draft merge** (only for buying intent or `mode = draft`, never when escalated). See [D](d-order-draft-integration.md).
6. **Persist.** The suggestion is saved and earlier open ones are superseded. The conversation's status, intent, missing fields and clarification counters are updated. The run is marked succeeded. The phone map is erased.

## 3. Model output contract (`p8.1`)

```json
{
  "intent": "price_inquiry | availability_inquiry | product_details | recommendation | delivery_inquiry | policy_inquiry | payment_inquiry | place_order | order_status | modify_order | greeting | other",
  "reply_language": "ckb | ar | en",
  "reply": [{"text": "…"} | {"fact": "variant_price", "ref": "<variant_id>"}],
  "clarification": [ same segments ],
  "extraction": null | {
    "customer_name": {"value": "…", "basis": "stated|inferred"} | null,
    "phone": {"token": "PHONE_1"} | null, "phone2": … ,
    "zone_id": "<zone_id from context>" | null, "city_text": … , "area": … , "landmark": … ,
    "address_details": … , "payment_method": "cod|other" | null, "customer_note": … ,
    "lines": [{"candidate_variant_ids": ["…"], "customer_text": "…", "quantity": 2 | null,
               "quantity_basis": "stated|inferred"}],
    "conflicts": [{"field": "quantity", "note": "…"}]
  },
  "missing_fields": ["product","variant","quantity","customer_name","customer_phone","zone","area","payment_method"],
  "escalation": {"required": true|false, "reasons": ["complaint", …, "suspected_manipulation", …]}
}
```

Facts:
- `store_name`;
- `product_name`, `variant_label`, `variant_price`, `variant_availability`;
- `zone_name`, `zone_fee`, `zone_time_text`;
- `policy_text`;
- `payment_methods`.

Prices, totals, fees, statuses and approval fields have **no place** in the contract.

## 4. Edge Function HTTP contract

`POST /functions/v1/ai-assist`
- **Authentication:** `Authorization: Bearer <seller JWT>`; the gateway verifies the JWT.
- **Body:** `{store_id, conversation_id, mode, idempotency_key}`, at most 2 KB, ids as UUIDs.
- **Success:** `200 {ok: true, data: {run_id, status, suggestion_id?, order_id?, escalated?, correlation_id}}`. A failed run is also a 200, with `status` set to `timeout`, `provider_error`, `refused`, `rate_limited` or `invalid_output`.
- **Refusals:** `{ok: false, error: {code, details}}` with:
  - 401 or 403 (authentication);
  - 404 `NOT_FOUND` (another seller's conversation);
  - 409 `AI_DISABLED`, `AI_PAUSED`, `AI_BUSY`, `NOTHING_TO_ANSWER` or `IDEMPOTENCY_KEY_REUSED`;
  - 422 (input);
  - 429 `RATE_LIMITED`, with `Retry-After`;
  - 503 `AI_UNAVAILABLE`.
- **CORS:** only for origins listed in `AI_ALLOWED_ORIGINS`. The mobile app sends no Origin header.
