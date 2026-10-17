# B. Order lifecycle

## 1. Statuses (Phase 1 §6.4)
| Status | Seller label | Stock | Sales | Editable |
|---|---|---|---|---|
| `draft` | Draft | None | No | Everything (`update_draft`) |
| `pending_approval` | Needs approval | None | No | Everything (`update_draft`) |
| `rejected` | Rejected (terminal) | None | No | Internal note |
| `approved` | Approved | Deducted | Yes | Items, quantities, customer, delivery, discount, payment (`edit_approved_order`) |
| `processing` | Preparing | Held | Yes | Same as approved |
| `dispatched` | Out for delivery | Held | Yes | Internal note |
| `delivered` | Delivered | Held | Yes | Internal note; cash |
| `delivery_failed` | Delivery failed | Held | Yes (pending resolution) | Internal note |
| `returned` | Returned (terminal) | Restocked per line | No | Internal note |
| `cancelled` | Cancelled (terminal) | Restored | No | Internal note |

`draft` ↔ `pending_approval` is decided by the server after every creation and edit, from the BR-36 completeness check (`app.order_issues`). An order is pending when all of these are present:
- name and phone;
- a zone or another place;
- area;
- delivery fee;
- payment method;
- at least one resolved line with a confirmed quantity.

## 2. Allowed transitions (BR-30)
The table `app.order_transitions` holds exactly these. A trigger refuses any other status change, whoever writes the row.

| From | To | Function | Who | Requirements |
|---|---|---|---|---|
| (new) | draft / pending_approval | `create_order` | Member with `orders.create_draft` | Server decides |
| draft ↔ pending_approval | — | (system, after an edit) | — | Completeness |
| draft, pending_approval | rejected | `reject_draft` | `orders.reject` | Reason; note for Other |
| pending_approval | approved | `approve_order` | **Owner only**, confirmed email | See [C](c-approval-security.md) |
| approved | processing | `transition_order` | `orders.fulfil` | — |
| approved, processing | dispatched | `transition_order` | `orders.fulfil` | Complete delivery details |
| approved, processing | cancelled | `cancel_order` | `orders.cancel` | Reason; restock |
| dispatched | delivered | `transition_order` | `orders.fulfil` | Optional cash collected ≤ due |
| dispatched | delivery_failed | `transition_order` | `orders.fulfil` | Reason; note for Other |
| delivery_failed | dispatched | `transition_order` | `orders.fulfil` | Complete delivery details |
| dispatched, delivery_failed | returned | `record_return` | `orders.fulfil` | A decision for every line |

In P0 only owners exist, and owners hold every permission. There is **no generic "set status"**: `transition_order` accepts only `processing`, `dispatched`, `delivered` and `delivery_failed`.

## 3. Behaviour on conflicts and repeats
- Every mutation checks `expected_version`. A stale version gives `CONFLICT_VERSION` with the current version and status, and the app re-reads the order.
- A transition that is not allowed from the current status gives `INVALID_TRANSITION` with `current_status`. The app shows the order as it is now. For approval, "already approved" is reported as such ([C §3](c-approval-security.md#3-repeats-races-and-lost-answers)).
- Every stock-moving or status-changing call takes an idempotency key. A repeat with the same key returns the stored answer without side effects. The same key with a different request gives `IDEMPOTENCY_KEY_REUSED`.

## 4. Screens
| Status | Screen | Sticky action | Overflow |
|---|---|---|---|
| draft, pending_approval | OR-02 review | Reject · **Approve order** (disabled with a reason while details are missing or items can't be sold) | Edit, Internal note, Full history |
| approved | OR-05 detail | Mark out for delivery · **Mark as preparing** | Edit, Copy confirmation, Note, History, Cancel |
| processing | OR-05 | **Mark out for delivery** | Edit, Copy confirmation, Note, History, Cancel |
| dispatched | OR-05 | Delivery failed · **Mark delivered** | Copy confirmation, Mark returned, Note, History |
| delivery_failed | OR-05 | Mark returned · **Try again** | Copy confirmation, Note, History |
| delivered with cash due | OR-05 | **Record cash** | Copy confirmation, Note, History |
| terminal | OR-05 | none | Note, History |

The editor (OR-06) refuses to open for an order after dispatch: "This order can't be edited".

## 5. Totals and prices
- Line unit price = approved price if set, else the quoted price.
- Subtotal = Σ quantity × unit price.
- Total = subtotal − discount + delivery fee (BR-24).
- Cash due = total for cash on delivery, else 0.

All of these are computed in `app.order_recompute`, in the same statement that writes the discount and fee, so the CHECKs always hold. A quoted price is the catalog price when the line was added. Kept lines keep their quote when a draft is edited. At approval, a changed price must be chosen explicitly (`PRICE_CHANGED`, BR-23).

Lines added to an approved order are priced at the current catalog price. Kept lines keep their approved price.
