// Shared helpers for the backend tests (tag `backend`): a LOCAL Supabase stack
// only. See backend_integration_test.dart for how to run them.
import 'dart:convert';
import 'dart:io';

import 'package:aisellia/features/auth/data/auth_repository.dart';
import 'package:aisellia/features/auth/domain/auth_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

final backendUrl = Platform.environment['SUPABASE_TEST_URL'] ?? '';
final backendKey = Platform.environment['SUPABASE_TEST_PUBLISHABLE_KEY'] ?? '';
final mailpitUrl = Platform.environment['MAILPIT_TEST_URL'] ?? '';

String? get backendSkip {
  if (backendUrl.isEmpty || backendKey.isEmpty || mailpitUrl.isEmpty) {
    return 'Set SUPABASE_TEST_URL, SUPABASE_TEST_PUBLISHABLE_KEY and '
        'MAILPIT_TEST_URL to run against a local Supabase stack.';
  }
  final hosts = [Uri.parse(backendUrl).host, Uri.parse(mailpitUrl).host];
  if (hosts.any((h) => h != '127.0.0.1' && h != 'localhost')) {
    return 'Backend tests only run against a local stack.';
  }
  return null;
}

class MemoryStorage extends GotrueAsyncStorage {
  final _values = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => _values[key];
  @override
  Future<void> setItem({required String key, required String value}) async =>
      _values[key] = value;
  @override
  Future<void> removeItem({required String key}) async => _values.remove(key);
}

/// A client as the app builds it: publishable key, PKCE, `api` schema.
SupabaseClient backendClient() => SupabaseClient(
  backendUrl,
  backendKey,
  authOptions: AuthClientOptions(pkceAsyncStorage: MemoryStorage()),
  postgrestOptions: const PostgrestClientOptions(schema: 'api'),
);

final backendRun = DateTime.now().millisecondsSinceEpoch;
var _seq = 0;
String uniqueEmail(String who) => '$who-$backendRun-${_seq++}@example.test';
const testPassword = 'correct-horse-battery';

Future<Map<String, dynamic>> _getJson(Uri uri) async {
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(uri)).close();
    return jsonDecode(await res.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

/// Waits for the newest email to [to] and returns the first auth link in it.
Future<Uri> linkFromMail(String to, {String type = 'signup'}) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    final list = await _getJson(
      Uri.parse(
        '$mailpitUrl/api/v1/search?query=${Uri.encodeQueryComponent('to:"$to"')}',
      ),
    );
    final messages = (list['messages'] as List?) ?? const [];
    if (messages.isNotEmpty) {
      final id = (messages.first as Map)['ID'];
      final message = await _getJson(
        Uri.parse('$mailpitUrl/api/v1/message/$id'),
      );
      final text = '${message['Text']}\n${message['HTML']}';
      final match = RegExp(r'https?://[^\s"<>]+/auth/v1/verify\?[^\s"<>]+')
          .allMatches(text)
          .map((m) => m.group(0)!.replaceAll('&amp;', '&'));
      final link = match.where((l) => l.contains('type=$type')).firstOrNull;
      if (link != null) return Uri.parse(link);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  throw StateError('No $type email for $to');
}

/// Opens an email link like a browser would, without following the redirect
/// to the app; returns the redirect target (the deep link).
Future<Uri> openLink(Uri link) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(link)
      ..followRedirects = false;
    final res = await req.close();
    await res.drain<void>();
    return Uri.parse(res.headers.value(HttpHeaders.locationHeader) ?? '');
  } finally {
    client.close();
  }
}

/// Signs up and verifies through the real email, returning the signed-in
/// client.
Future<SupabaseClient> verifiedSeller(String email) async {
  final client = backendClient();
  final auth = SupabaseAuthRepository(client);
  expect(
    await auth.signUp(
      email: email,
      password: testPassword,
      termsVersion: '2026-10',
    ),
    SignUpOutcome.verificationRequired,
  );
  final redirect = await openLink(await linkFromMail(email));
  expect(redirect.toString(), startsWith(AuthLinks.callback));
  await auth.signIn(email: email, password: testPassword);
  return client;
}
