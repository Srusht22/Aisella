// Rejects physical-direction geometry in lib/ so layouts mirror in RTL
// (docs/architecture/phase-3/flutter-architecture.md §10 and §14).
// Use the Directional variants (EdgeInsetsDirectional, AlignmentDirectional,
// PositionedDirectional, BorderRadiusDirectional, TextAlign.start/end).
//
// A line that genuinely needs a physical side (for example, a shape that
// must not mirror) can opt out with a trailing `// rtl-ok: <reason>`.
//
//   dart run tool/check_directional.dart
// ignore_for_file: avoid_print
import 'dart:io';

final _patterns = <RegExp, String>{
  RegExp(r'EdgeInsets\.only\([^)]*\b(left|right):'):
      'EdgeInsetsDirectional.only',
  RegExp(r'EdgeInsets\.fromLTRB\('): 'EdgeInsetsDirectional.fromSTEB',
  RegExp(r'\bAlignment\.(top|center|bottom)(Left|Right)\b'):
      'AlignmentDirectional',
  RegExp(r'\bTextAlign\.(left|right)\b'): 'TextAlign.start/end',
  RegExp(r'\bPositioned\([^)]*\b(left|right):'): 'PositionedDirectional',
  RegExp(
    r'BorderRadius\.only\([^)]*\b(topLeft|topRight|bottomLeft|bottomRight):',
  ): 'BorderRadiusDirectional.only',
  RegExp(r'\bBorder\([^)]*\b(left|right):'): 'BorderDirectional',
};

void main() {
  final violations = <String>[];
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.contains('/gen/'))
      .toList();
  for (final file in files) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.contains('// rtl-ok:')) continue;
      for (final MapEntry(key: re, value: fix) in _patterns.entries) {
        if (re.hasMatch(line)) {
          violations.add('${file.path}:${i + 1}: use $fix — ${line.trim()}');
        }
      }
    }
  }
  if (violations.isEmpty) {
    print('Directional geometry OK (${files.length} files).');
    return;
  }
  violations.forEach(print);
  exit(1);
}
