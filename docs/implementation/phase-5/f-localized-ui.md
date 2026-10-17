# F. Localized UI

## 1. New screens

Every Phase 5 screen is in Sorani (`ckb`, RTL, the default) and English, and follows the Phase 2 specifications and the Phase 4 design system. No hard-coded user-facing strings remain: `flutter analyze` and the review found none.

| Area | Screens |
|---|---|
| Entry | Starting (`/starting`), Workspace unavailable (Retry, Sign out), Account being deleted |
| Auth | Welcome AU-01, Sign in AU-02, Sign up AU-03, Terms and Privacy (states honestly that the documents are pending legal review, AD-06), Verify email AU-06, Forgot password AU-05, New password AU-05b |
| Setup | Store AU-07, Delivery zones AU-08, Payments AU-09; step indicator "Step n of 3" |
| Today | Setup checklist |
| Store settings | Store profile ST-02, Delivery zones ST-03 (with zone editor), Payments ST-04, Account ST-07, Delete account ST-08 |

## 2. Strings

- **165 new message keys**: from 136 to 301 per language. Sorani and English have exactly the same key set, enforced by a test.
- Placeholders use ICU (`{seconds}` for the resend countdown, `{email}`, `{date}`, `{example}` for the phone format, `{done} of {total}`).
- **Errors**:
  - `apiErrorText` and `authFailureText` map each `ApiErrorCode` and `AuthFailure` to localized text; codes a screen cannot recover from share a general "could not save" message, and raw server text is never shown;
  - field rules map to field messages;
  - an `INTERNAL` error shows its reference, for example "Something went wrong on our side. Ref: 3FA2C1B0".
- **Dates:** the new `dayMonthYear` formatter gives "29 October 2026" and "29ی تشرینی یەکەمی 2026". It is used for the deletion date and respects the digit-style setting.
- **Sorani wording is machine-drafted** and needs review by a native speaker before release (Phase 2 DD-04, still open).

## 3. RTL and bidi

- Email, password, phone and fee inputs are **LTR inside RTL layouts**. A test checks every text field on the Sorani sign-in screen.
- Emails inside sentences are wrapped with `Bidi.ltr`, so `seller@example.com` does not reorder inside Sorani text. The phone format example (`+964 750 123 4567`) is isolated the same way. The visual review found and fixed it rendering reversed in RTL.
- No literal bidi control characters appear in the ARB files (test), and no physical left/right geometry appears in the code (`tool/check_directional.dart`).
- **Eastern Arabic and Persian digits** are accepted in the phone and fee fields and normalized before they are sent.

## 4. Accessibility

- Text fields expose their label, value and error as one semantics node. A new test covers this after a `MergeSemantics` approach broke the semantics tree.
- Password fields have a show/hide button with a localized tooltip.
- Progress is announced: busy buttons, the step indicator and the checklist progress ("n of 5 done", with each item's state in its label).
- The auth and setup screens were rendered at **200% text scale on 360×640** in both languages without overflow (test).
- Destructive actions use the danger style and need confirmation: sign out, sign out everywhere, remove zone, delete account.

## 5. Visual review

Eight new golden screenshots cover Welcome (en), Sign in (ckb), Sign up (en), Verify (ckb), Setup store (ckb), Setup zones (en), Setup payments (ckb, dark) and the Today checklist (ckb). Together with Phase 4's goldens that makes 27. Issues found while reviewing them were fixed before commit:
- the duplicated Welcome fragment;
- off-center tablet panels;
- the reversed phone example;
- snackbars queuing instead of replacing each other;
- a stale controller after a conflict reload.
