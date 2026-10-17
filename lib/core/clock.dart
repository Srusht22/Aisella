import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The current time. Screens read it through this provider instead of
/// calling `DateTime.now()` directly, so tests can fix the date.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
