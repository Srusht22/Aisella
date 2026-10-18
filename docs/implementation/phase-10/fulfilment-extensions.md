# Phase 10 (roadmap milestone R8): fulfilment extensions

**Status:** in progress (local only). Not to be confused with the Gemini verification report in this folder; see the [project status](../project-status.md).

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
