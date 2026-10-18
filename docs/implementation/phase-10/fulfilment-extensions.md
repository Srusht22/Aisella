# Phase 10 (roadmap milestone R8): fulfilment extensions

**Status:** implemented and tested **locally only** (2026-10-18). Nothing deployed; the migration has not been applied to any hosted database. Not to be confused with the Gemini verification report in this folder; see the [project status](../project-status.md).

**Source of scope:**
- [roadmap](../../architecture/phase-3/implementation-roadmap.md) R8: "Courier records, delivery lists, payment recording (P1)";
- [Phase 1 specification](../../product/phase-1-product-specification.md) items 14b and 15b:
  - 14b: courier records and printable delivery lists are P1; courier APIs are P2 and out of scope;
  - 15b: transfers and local wallets (record only) and courier settlement reconciliation are P1.

**Depends on:** R4 (Phase 7 orders), already done.

## Scope

1. **Courier records.**
   - Each store keeps its couriers (name and an optional phone) and can deactivate them.
   - An order dispatched with a courier keeps it; the free-text courier note stays as it is.
2. **Delivery lists.**
   - The seller groups ready orders (approved, processing or failed delivery) into a numbered list for one courier.
   - The list shows each stop: order number, customer, phones, address, items, and the cash to collect. It can be copied as text to hand over (printing needs no new dependency).
   - "Handed over" dispatches every order on the list in one step, all or nothing.
3. **Payment recording (record only).**
   - Payments by transfer or local wallet (FIB, FastPay, ZainCash, bank transfer, other) are recorded against an order with an optional reference.
   - Nothing moves money; the paid total can never exceed the order total.
4. **Courier settlement.**
   - For each courier: the cash on delivery still owed on delivered orders, and the cash being carried on dispatched orders.
   - A settlement of an amount handed over by a courier is spread over that courier's oldest outstanding orders, using the existing cash-collection records.

**Out of scope:**
- courier APIs and automatic delivery fees (P2);
- reports (Phase 11).

## Constraints

- Everything is local; the migration is not applied to any hosted database.
- No real customer data: tests use synthetic orders.
- Existing order invariants are unchanged: stock, approval, the transition table and the COD maximums.

## What was built

**Database** (`supabase/migrations/20261023100000_fulfilment_extensions.sql`):
- Tables: `app.couriers`, `app.delivery_lists`, `app.delivery_list_orders`, `app.order_payments` and `app.courier_settlements`.
- New columns: `orders.courier_id`, `orders.paid_total` (checked `<= total`), `stores.last_delivery_list_number` and `cod_collections.settlement_id`.
- Row-level security lets store members read; every write goes through a `SECURITY DEFINER` function with permission checks, idempotency keys and audit entries.
- Functions:
  - `api.list_couriers`, `api.upsert_courier` (needs `settings.manage`);
  - `api.list_delivery_lists`, `api.get_delivery_list`, `api.create_delivery_list`, `api.update_delivery_list` (set orders, hand over, cancel);
  - `api.record_payment`, `api.settle_courier`.
- Rules:
  - Hand-over dispatches every order on the list, or none: it fails with `INCOMPLETE_ORDER` and names the blocking orders.
  - A transfer can be recorded only on an order whose payment method is "other". A settlement can never exceed what the courier owes, and it is allocated oldest order first.
- Existing functions patched:
  - `transition_order` accepts a courier on dispatch;
  - `order_json` adds the courier, the payments and the delivery list;
  - the account purge deletes the new tables;
  - customer anonymisation redacts payment references, which may contain a wallet phone number.
- The AI and channel roles have no access to any of these functions.

**App (Flutter):**
- Couriers: Store › Couriers; add or edit, deactivate, record a settlement.
- Delivery lists: Orders › Delivery lists.
  - Create a list from the ready orders, pick a courier, change the orders, copy the list as text, cancel it, or hand it over.
  - Text copied from the list carries no bidirectional control characters.
- Order detail: the courier, the delivery list (opens the list), payments with "Paid" and "Left to pay", and a "Record payment" sheet.
- The dispatch sheet has a courier picker, including "Choose later".
- English, Sorani and Arabic strings: 65 new keys. The Sorani and Arabic strings are machine-drafted and await native review.

## Test results (local, 2026-10-18)

| Check | Result |
|---|---|
| pgTAP, all suites (new suite 25 has 41 assertions) | 1171 passed |
| HTTP role checks (`ai_role_api_test.py`) | 17 passed |
| Deno: `_channels` / `ai-assist` (unchanged this phase) | 55 / 74 passed |
| Flutter tests, including 13 new fulfilment tests | 336 passed |
| Flutter gates: format, analyze, import boundaries, directional geometry, tokens | clean |

Three order goldens were updated. They now include the new "Delivery lists" entry on the orders screen, which was reviewed visually.

**Commits:** `87a8184` (database) and the app and docs commit that follows it on `S.H_Branch`.

## Limitations and what is not verified

- Everything is local: there was no hosted migration or deployment, and nothing ran on a real device.
- Delivery lists are shared as copied text. Printing or PDF would need a new dependency and the owner's decision.
- No courier API (P2), and couriers have no app login.
- Payments are records only. Nothing is checked with FIB, FastPay, ZainCash or a bank.
- Reports on these figures belong to Phase 11 (R9).
- The new Sorani and Arabic strings need native review ([checklist](../pre-publication-checklist.md) C1).
