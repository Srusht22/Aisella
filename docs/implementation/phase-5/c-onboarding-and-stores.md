# C. Seller onboarding and store creation

## 1. Flow

After a seller verifies their email and signs in, the router reads `api.get_my_context()` and resumes setup at the first incomplete step. The server's `stores.onboarding_step` (`zones` → `payments` → `done`) is the only record of progress, so setup resumes correctly after an app restart, on another device, or after a reinstall.

| Step | Screen (Phase 2) | Fields | Server call | Persisted in |
|---|---|---|---|---|
| 1. Store | AU-07 | Store name (1–60 characters, trimmed); contact phone (Iraqi mobile, typed as `0750…`, `+964 750…` or Eastern digits, stored as E.164 `+9647XXXXXXXXX`); city; currency (IQD or USD, default IQD); reply language (Sorani or English, default the app language) | `api.create_store` | `app.stores` plus `app.store_members` (role `owner`) |
| 2. Delivery zones | AU-08 | Pre-filled suggestions (Sulaymaniyah, Erbil, Duhok, Halabja) that can be switched on, renamed and priced; delivery fee (whole IQD, 0–10,000,000, Western, Eastern Arabic or Persian digits); optional delivery time text. **Skippable** ("Skip for now"). | `api.upsert_zone` for each zone, then `api.advance_onboarding('payments')` | `app.delivery_zones` |
| 3. Payments | AU-09 | Cash on delivery; "Other (record only)", for payments the seller arranges themselves. Aisellia only records the choice and processes no payments. At least one must be on. | `api.update_store` (if changed), then `api.advance_onboarding('done')` | `app.stores` |

When step 3 finishes, the app shows "Your store is ready" and the router opens **Today**. Today shows a **setup checklist** ("Set up your store", *n of 5 done*):
- *Create your store*: always done at this point;
- *Add delivery zones*: done once one active zone exists, otherwise "To do", which opens the zone settings;
- *Add your first product*, *Try a practice conversation* and *Import a real customer message*: marked "In a later release", because those features belong to later phases. They are not faked as done.

## 2. Rules enforced on the server

The client validates first for immediate feedback. The **server's answer is authoritative** and is mapped back onto the same fields (`VALIDATION_FAILED` with `details.fields`, codes `required`, `too_long`, `invalid`, `duplicate` and `out_of_range`).

- **One store per seller (P0):** a unique index on `store_members(user_id)`, checked before insert. A race returns `LIMIT_EXCEEDED` and not a 500.
- **The creator becomes the owner** in the same transaction. A unique index allows one owner per store.
- **Only forward:** `advance_onboarding` never moves the step backwards, and repeating a step is harmless.
- **Zones:** active names are unique per store, compared case-insensitively. There are at most 50 active zones per store. Edits use optimistic versions, and removal is a soft `deactivate_zone`.
- **Payments:** a database check constraint and `update_store` both require at least one method.
- **Audit:** `store.create`, `store.update`, `store.onboarding`, `zone.*` and `account.deletion_requested` are written to `app.audit_events` in the same transaction.

## 3. Retries, double taps and lost responses

- **Double taps:** buttons disable while a request runs, and the widget tests show that one tap sends one request.
- **Idempotency:** each create or update carries an idempotency key. `IntentKey` keeps **one key per intent**: the same payload reuses its key, and a changed payload gets a new one. The server stores `(user_id, key) → response` and replays it; the same key with a different payload returns `IDEMPOTENCY_KEY_REUSED`.
- **Lost responses** (timeout, connection dropped after sending): `ApiException.outcomeUnknown`. For `create_store`, the controller **reconciles** by reloading the context. If the store exists, setup simply continues. `LIMIT_EXCEEDED` is reconciled the same way, which covers a store created by an earlier attempt whose response was lost.
- **Conflicts:** a stale `expected_version` returns `CONFLICT_VERSION`. The screen refreshes the store silently (`WorkspaceController.refresh`, which keeps the current page and data) and asks the seller to review and save again.
- **Offline:** nothing is queued. The seller sees "No connection" with Retry, and nothing is reported as saved until the server confirms.

## 4. What this phase does not do

- No products, stock, orders, conversations, AI replies or payments (Phase 1 roadmap, later milestones).
- No team members or invitations. The schema has `store_members.role` and `permissions` so later phases can add staff without a migration; P0 has owners only.
- No store logo or media (no storage bucket; storage is disabled in `config.toml`).
