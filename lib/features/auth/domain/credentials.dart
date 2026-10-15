/// Client-side checks for auth forms. They give fast feedback only: the
/// provider validates again and its answer is authoritative.
library;

/// Phase 1 Journey A: at least 8 characters (also configured in Supabase Auth).
const minPasswordLength = 8;

/// Version of the Terms and Privacy Policy the seller accepts at sign-up.
/// Recorded on the profile by the sign-up trigger.
const currentTermsVersion = '2026-10';

enum EmailIssue { required, invalid }

enum PasswordIssue { required, tooShort }

/// Trims surrounding whitespace; addresses are otherwise sent as typed (the
/// provider normalises case).
String normalizeEmail(String input) => input.trim();

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

EmailIssue? validateEmail(String input) {
  final email = normalizeEmail(input);
  if (email.isEmpty) return EmailIssue.required;
  if (!_emailPattern.hasMatch(email)) return EmailIssue.invalid;
  return null;
}

/// For sign-in: only presence is checked, so existing passwords set under
/// another policy still work.
PasswordIssue? validateExistingPassword(String input) =>
    input.isEmpty ? PasswordIssue.required : null;

/// For sign-up and password changes.
PasswordIssue? validateNewPassword(String input) {
  if (input.isEmpty) return PasswordIssue.required;
  // Count characters (code points), not UTF-16 units.
  if (input.runes.length < minPasswordLength) {
    return PasswordIssue.tooShort;
  }
  return null;
}
