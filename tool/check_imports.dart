// Enforces the layer boundaries from docs/architecture/phase-3/flutter-architecture.md §2:
//
// * presentation/ code must not import backend SDKs or data/ layers directly
//   (it reads providers exposed by data/ or application/ files instead —
//   in Phase 4 data/ files expose providers, so presentation may import a
//   feature's own data/ provider file but never a backend SDK);
// * a feature may not import another feature's data/ or presentation/;
// * design_system/ must not import features/ or app/;
// * once a feature has an application/ layer, presentation/ code must not
//   import that feature's data/ layer (providers live in application/).
//
//   dart run tool/check_imports.dart
// ignore_for_file: avoid_print
import 'dart:io';

const _forbiddenSdks = ['package:supabase', 'package:http/', 'package:dio/'];

final _root = Directory.current.absolute.uri;

/// Repo-relative path of an import (`lib/...`), or the import itself for
/// other packages and `dart:` libraries.
String _resolve(File from, String imp) {
  if (imp.startsWith('package:aisellia/')) {
    return 'lib/${imp.substring('package:aisellia/'.length)}';
  }
  if (imp.contains(':')) return imp;
  final abs = from.absolute.uri.resolve(imp).toString();
  return abs.startsWith(_root.toString())
      ? abs.substring(_root.toString().length)
      : abs;
}

void main() {
  final violations = <String>[];
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.contains('/gen/'));
  final importRe = RegExp(r'''^import\s+['"]([^'"]+)['"]''', multiLine: true);

  final withApplication = {
    for (final dir in Directory(
      'lib/features',
    ).listSync().whereType<Directory>())
      if (Directory('${dir.path}/application').existsSync())
        dir.uri.pathSegments.where((s) => s.isNotEmpty).last,
  };

  for (final file in files) {
    final path = file.path.replaceAll(r'\', '/');
    final imports = importRe
        .allMatches(file.readAsStringSync())
        .map((m) => m.group(1)!);
    final feature = RegExp(r'lib/features/([^/]+)/').firstMatch(path)?.group(1);

    for (final imp in imports) {
      final resolved = _resolve(file, imp);

      if (path.contains('/presentation/') &&
          _forbiddenSdks.any(imp.startsWith)) {
        violations.add('$path: presentation imports backend SDK $imp');
      }
      if (path.startsWith('lib/design_system/') &&
          (resolved.contains('lib/features/') ||
              resolved.contains('lib/app/'))) {
        violations.add('$path: design_system must not import $imp');
      }
      final dataLayer = RegExp(r'lib/features/([^/]+)/data/')
          .firstMatch(resolved);
      if (path.contains('/presentation/') &&
          dataLayer != null &&
          withApplication.contains(dataLayer.group(1))) {
        violations.add(
          '$path: presentation imports ${dataLayer.group(1)}/data (use its application layer)',
        );
      }
      final other = RegExp(r'lib/features/([^/]+)/(data|presentation)/')
          .firstMatch(resolved);
      if (feature != null &&
          other != null &&
          other.group(1) != feature &&
          other.group(1) != 'common') {
        violations.add(
          '$path: feature "$feature" imports ${other.group(1)}/${other.group(2)}',
        );
      }
    }
  }

  if (violations.isEmpty) {
    print('Import boundaries OK (${files.length} files).');
    return;
  }
  violations.forEach(print);
  exit(1);
}
