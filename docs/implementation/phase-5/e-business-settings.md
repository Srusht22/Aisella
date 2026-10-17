# E. Persistent business settings

## 1. What persists, and where

| Setting | Screen (Phase 2) | Stored in | Rules |
|---|---|---|---|
| Store name | Store profile ST-02 | `app.stores.name` | 1–60 characters, trimmed |
| Contact phone | ST-02 | `app.stores.contact_phone` | Iraqi mobile, normalized to E.164 `+9647XXXXXXXXX`; local, international and Eastern-digit input accepted |
| City | ST-02 | `app.stores.business_city` | 1–60 characters |
| Currency | ST-02 | `app.stores.currency` | IQD or USD; **locked** once `currency_locked_at` is set. Nothing sets it in Phase 5, because the lock is meant for the first order. |
| Customer reply language | ST-02 | `app.stores.reply_locale` | `ckb` or `en`. Stored for the AI phase; nothing uses it yet. |
| Delivery zones | ST-03 | `app.delivery_zones` | Add, edit (fee, time text, name) and remove (soft). Unique active names per store; fee 0–10,000,000 IQD; 50 per store |
| Payment methods | ST-04 | `app.stores.cod_enabled`, `other_payment_enabled` | At least one on (database constraint and function check) |
| Terms version accepted | Sign up | `app.profiles.terms_version`, `terms_accepted_at` | Set by the sign-up trigger |
| Onboarding progress | Setup | `app.stores.onboarding_step` | Forward only |
| Account deletion request | ST-08 | `app.account_deletion_requests`, `app.stores.deletion_requested_at` | See [D §6](d-ownership-and-authorization.md#6-account-deletion) |

**Device-only (unchanged from Phase 4, by design):** app language, digit style, theme and reduced motion. They are kept in `shared_preferences` (`settings.locale`, `settings.digits`, `settings.theme`, `settings.motion`), because they are needed **before** sign-in and are per device.

**Not persisted** (no feature yet): store policies (US-007), customers and connected channels. Their Store-menu rows open the honest "not available yet" screen from Phase 4. There are also no settings yet for notifications, staff, logo, opening hours or AI tone.

## 2. Editing behaviour

- **Server first.** Forms start from the server's current values. Save sends **only the changed fields** (`update_store` takes a change set) together with the store's `version`. The screen shows "Saved" only after the server confirms, and the new values come from the server's response.
- **Unsaved changes** are detected against the saved store (`StoreBasicsValues.differsFrom`). Leaving the profile screen with unsaved edits asks "Discard changes?" (`UnsavedChangesGuard`).
- **Conflicts:** if another device saved first, the server returns `CONFLICT_VERSION`. The screen reloads the latest values quietly, keeps the seller on the page, and says "This was changed on another device. The latest version is shown — check it and save again."
- **Validation:** client checks give immediate feedback. Server field errors are shown on the same fields.
- **Retries:** the same edit reuses its idempotency key (`IntentKey`), so a retry after a lost response does not apply the change twice.
- **Zones:** removing a zone asks for confirmation. A removed zone's name can be reused, and editing a stale zone is a conflict.

## 3. Verified

- `03_store_rules` (pgTAP, 41 assertions) covers:
  - every field rule;
  - the allow-list, empty change sets and type checks;
  - version conflicts;
  - the currency lock;
  - the payment rule;
  - audit of the changed fields only;
  - zone uniqueness, edit, conflict, removal and reuse;
  - forward-only onboarding.
- `onboarding_settings_test.dart` (widget) covers:
  - the profile sending only the changed field;
  - conflict reload without claiming success;
  - zones list, add and remove (zone edits and stale-version conflicts are covered in pgTAP);
  - the payments rule;
  - the account screen and deletion.
- `backend_integration_test.dart` covers create, replay, limit, update and zones through the real PostgREST.
