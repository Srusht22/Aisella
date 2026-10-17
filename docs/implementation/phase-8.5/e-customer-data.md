# E. Customer data: anonymisation and retention

## 1. The order-notes gap (open since Phase 7, doc I §5 item 4)

**Before:** `api.anonymize_customer` cleared the customer's own fields:
- name, phones, area, landmark and address details;
- the customer note;
- the conversation text behind the order.

It left five seller-written notes untouched: `internal_note`, `courier_note`, `payment_note`, `closed_note`, and the `note` of each status-history event. Those often repeat the customer, for example "Nzar called from 0750 111 2233, leave at the gate". The order's audit rows held the same notes. A test reproduced it: after a customer was anonymised, a note on another order still held their number.

**Fix** (`20261019100000_customer_notes_redaction.sql`). When an owner deletes a customer:

| What | Change |
|---|---|
| The five notes of every order being anonymised | The customer's name and phone numbers are replaced with `[redacted]`. The rest of the note stays, because it is the seller's business record. |
| Names | The full name, then each word of three letters or more. Matching ignores case. A Latin word must stand alone, so "Ali" leaves "Alice" alone. An Arabic-script word may carry a suffix ("نزارەکە"). |
| Phone numbers | The 10 national digits in any common writing: 07…, 7…, 964…, +964…, 00964…; spaces, dots or dashes; Western, Arabic-Indic or Persian digits. A different or longer number is left alone. |
| The order's audit rows | The same redaction inside every text value, at any depth, plus the existing field redaction |
| Orders anonymised **earlier** | Their names are already gone, but their notes are searched for the **requested number** and it is redacted |
| Status history | Still append-only. Only `note` may change, and only inside this function under the existing redaction flag. Every other change or deletion is still refused (`AS002`). |
| The result and the audit | Report `notes_redacted` (a count, never text) |

**Not changed:**
- **Nothing is deleted.** No migration touches existing data: redaction happens only when an owner asks to delete a customer.
- Status, totals, lines, the history rows and who did what all stay.
- Orders still in progress keep their data and are reported as skipped, as before.

**Limits:**
- A name written differently in a note is not found: a nickname, a spelling variant, or a different script.
- A phone written with fewer than its 10 national digits is not found.
- An order **of another customer still in progress** that mentions this customer is not touched. Example: "friend of 0750 …".
- Matching is by phone number only (Phase 7 I §5 item 6).
- The seller can still review and edit notes manually; there is no UI for this in the app yet.

**Tests:** `supabase/tests/database/17_customer_notes_retention.test.sql` covers:
- 10 phone formats, including two that must not match;
- name rules (whole name, words, Latin boundary, Sorani suffix, short names);
- JSON at any depth;
- an end-to-end anonymisation of delivered and rejected orders with internal, payment, courier, closing and history notes in English and Sorani, plus an earlier-anonymised order;
- an unrelated order in progress that must stay untouched;
- audit rows free of the name and number but keeping the rest of the note;
- append-only enforcement.

Suite 13's expected results now include `notes_redacted`.

## 2. Retention jobs (Phase 8), now tested

| Job | Rule | Now tested |
|---|---|---|
| `internal.purge_ai_run_outputs` | AI run outputs, validation errors and the phone map cleared after 90 days. Status, tokens and cost kept. | Old run cleared; recent run kept; metrics kept |
| `internal.purge_message_bodies` | Message bodies and suggestion text cleared 12 months after the conversation's last activity. Metadata kept and marked purged. | Old conversation cleared; recent one kept; suggestion text cleared |
| Both | A retention under one day is refused and recorded as failed; `internal.job_health()` reports them | Refusal, its record, job health |

## 3. Remaining recommendations

1. **An app screen for "Delete this customer".** It is API-only today, so a seller cannot exercise the right without help.
2. **Match by more than one number.** Let the owner enter several numbers of the same customer in one request.
3. **A data-processing note for sellers** about what is sent to the AI provider ([C §2](c-provider-data-and-cost.md#2-proposed-ad-08-data-terms-and-geography-owner-decision)).
