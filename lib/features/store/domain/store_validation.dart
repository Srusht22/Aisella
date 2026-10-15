import '../../../core/formatting/digits.dart';
import '../../../core/formatting/phone.dart';

/// Client-side checks mirroring the server rules in api.create_store /
/// update_store / upsert_zone. They give immediate feedback; the server's
/// answer (field codes) is authoritative and mapped to the same issues.
enum FieldIssue { required, tooLong, invalid, duplicate }

const maxStoreNameLength = 60;
const maxCityLength = 60;
const maxZoneNameLength = 40;
const maxDeliveryTimeLength = 40;
const maxFee = 10000000;

FieldIssue? validateStoreName(String input) {
  final name = input.trim();
  if (name.isEmpty) return FieldIssue.required;
  if (name.runes.length > maxStoreNameLength) return FieldIssue.tooLong;
  return null;
}

/// Returns the E.164 phone, or the issue. Accepts local (`0750…`),
/// international and Eastern-digit input (Phase 2 AU-07).
(String?, FieldIssue?) parseContactPhone(String input) {
  if (input.trim().isEmpty) return (null, FieldIssue.required);
  final e164 = PhoneNumbers.normalizeIraqMobile(input);
  return e164 == null ? (null, FieldIssue.invalid) : (e164, null);
}

FieldIssue? validateCity(String input) {
  final city = input.trim();
  if (city.isEmpty) return FieldIssue.required;
  if (city.runes.length > maxCityLength) return FieldIssue.tooLong;
  return null;
}

FieldIssue? validateZoneName(
  String input, {
  Iterable<String> taken = const [],
}) {
  final name = input.trim();
  if (name.isEmpty) return FieldIssue.required;
  if (name.runes.length > maxZoneNameLength) return FieldIssue.tooLong;
  final lower = name.toLowerCase();
  if (taken.any((t) => t.trim().toLowerCase() == lower)) {
    return FieldIssue.duplicate;
  }
  return null;
}

/// Parses a fee typed with Western, Eastern Arabic or Persian digits and
/// optional grouping separators. Whole units only (Phase 1 BR-12).
(int?, FieldIssue?) parseFee(String input) {
  final raw = Digits.normalize(input).replaceAll(RegExp(r'[\s,٬]'), '');
  if (raw.isEmpty) return (null, FieldIssue.required);
  if (!RegExp(r'^\d+$').hasMatch(raw)) return (null, FieldIssue.invalid);
  final value = int.tryParse(raw);
  if (value == null || value > maxFee) return (null, FieldIssue.invalid);
  return (value, null);
}

/// Maps a server field rule (`required`, `too_long`, `invalid`, `duplicate`,
/// `out_of_range`) to the issue the form shows.
FieldIssue fieldIssueFromServer(String rule) => switch (rule) {
  'required' => FieldIssue.required,
  'too_long' => FieldIssue.tooLong,
  'duplicate' => FieldIssue.duplicate,
  _ => FieldIssue.invalid,
};
