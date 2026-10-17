# E. Audit and history

## 1. Status events (BR-34)
`app.order_status_events` gets exactly one row per status change. Each row records:
- from and to;
- the actor: the user, or `validation` for the automatic draft ↔ pending re-evaluation;
- the reason and note;
- the time.

Creation is one event (∅ → draft or pending approval), so history is never empty. The table is append-only: a trigger refuses updates and deletes, except during the account purge.

## 2. Audit rows
Every order mutation writes `app.audit_events` in the same transaction:

| Action | Before / after |
|---|---|
| `order.create` | after: the full editable state including lines |
| `order.update_draft` | Only the fields that changed, before and after (`app.jsonb_changed`) |
| `order.approve` | status; after: total, price choices, stock changes |
| `order.reject`, `order.cancel` | status, reason; cancel: restocked lines |
| `order.edit` | Changed fields, before and after, plus `stock_diff` |
| `order.transition` | status and the payload (courier note, reason, cash) |
| `order.return` | Line decisions and restocked units |
| `order.cod` | Cash before and after, and the amount |
| `order.note` | Internal note before and after |
| `order.confirmation_marked_sent` | The seller's "I sent this" |

Stock changes are additionally in `inventory_movements` with the order id and the actor.

## 3. History screen (OR-11)
`api.order_history` merges:
- the status events;
- the audit rows for edits, notes, cash and confirmation marks.

They come oldest first. Within one request an edit sorts before the status change it caused.

The screen shows each entry's:
- actor: You, a team member, or System;
- date and time;
- reason and note;
- for edits, `field: before → after`, with phones formatted and lines summarized as "2 × Beige Abaya · M".

The order detail shows the three latest events and a link to the full history.

## 4. Personal data
The audit holds the customer name and phone as they changed. Phase 3 §7 requires anonymizing them with the customer (BR-72). That job doesn't exist yet: customers aren't modelled in P0 ([H §6](h-phase-7-completion-report.md#6-decisions-needing-owner-sign-off), P7-D1). The account purge removes all orders, history and audit rows of a deleted store.
