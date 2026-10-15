// Generates lib/design_system/tokens/tokens.g.dart from the Phase 2 token file.
//
//   dart run tool/gen_tokens.dart          # write
//   dart run tool/gen_tokens.dart --check  # exit 1 if the generated file is stale
//
// The JSON (docs/design/phase-2/tokens/aisellia-tokens.json) is the single source
// of truth for colours, type, spacing, radii, layout and motion (Phase 2 §09).
// ignore_for_file: avoid_print, avoid_dynamic_calls
import 'dart:convert';
import 'dart:io';

const _source = 'docs/design/phase-2/tokens/aisellia-tokens.json';
const _target = 'lib/design_system/tokens/tokens.g.dart';

void main(List<String> args) {
  final json =
      jsonDecode(File(_source).readAsStringSync()) as Map<String, dynamic>;
  final target = File(_target);
  final tmp = Directory.systemTemp.createTempSync('tokens');
  final formatted = File('${tmp.path}/tokens.g.dart')
    ..writeAsStringSync(_generate(json));
  final fmt = Process.runSync('dart', ['format', formatted.path]);
  if (fmt.exitCode != 0) {
    print(fmt.stderr);
    exit(2);
  }
  final out = formatted.readAsStringSync();
  tmp.deleteSync(recursive: true);
  if (args.contains('--check')) {
    if (!target.existsSync() || target.readAsStringSync() != out) {
      print('$_target is stale. Run: dart run tool/gen_tokens.dart');
      exit(1);
    }
    print('$_target is up to date.');
    return;
  }
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(out);
  print('Wrote $_target');
}

String _camel(String key) {
  final parts = key.split(RegExp(r'[.\-]'));
  return parts.first +
      parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join();
}

String _color(String hex) => 'Color(0xFF${hex.substring(1).toUpperCase()})';

String _num(num v) => v is int ? '$v.0' : '$v';

String _generate(Map<String, dynamic> j) {
  final b = StringBuffer()
    ..writeln('// GENERATED CODE — DO NOT EDIT.')
    ..writeln('// Source: $_source (version ${j['version']}).')
    ..writeln('// Regenerate with: dart run tool/gen_tokens.dart')
    ..writeln()
    ..writeln("import 'package:flutter/material.dart' show ThemeExtension;")
    ..writeln("import 'package:flutter/widgets.dart';")
    ..writeln();

  // ---- Colour palette as a ThemeExtension --------------------------------
  final light = (j['color'] as Map)['light'] as Map<String, dynamic>;
  final dark = (j['color'] as Map)['dark'] as Map<String, dynamic>;
  final colorKeys = light.keys
      .where((k) => (light[k] as Object) is String)
      .toList();
  final opacityKeys = light.keys
      .where((k) => (light[k] as Object) is num)
      .toList();

  b
    ..writeln('/// Semantic colour palette (Phase 2 §2). Access via')
    ..writeln('/// `context.palette` (see design_system/theme/theme_ext.dart).')
    ..writeln('@immutable')
    ..writeln(
      'final class AiselliaPalette extends ThemeExtension<AiselliaPalette> {',
    )
    ..writeln('  const AiselliaPalette({');
  for (final k in [...colorKeys, ...opacityKeys]) {
    b.writeln('    required this.${_camel(k)},');
  }
  b.writeln('  });');
  b.writeln();
  for (final k in colorKeys) {
    b.writeln('  /// `$k`');
    b.writeln('  final Color ${_camel(k)};');
  }
  for (final k in opacityKeys) {
    b.writeln('  /// `$k`');
    b.writeln('  final double ${_camel(k)};');
  }
  void instance(String name, Map<String, dynamic> m) {
    b.writeln();
    b.writeln('  static const AiselliaPalette $name = AiselliaPalette(');
    for (final k in colorKeys) {
      b.writeln('    ${_camel(k)}: ${_color(m[k] as String)},');
    }
    for (final k in opacityKeys) {
      b.writeln('    ${_camel(k)}: ${_num(m[k] as num)},');
    }
    b.writeln('  );');
  }

  instance('light', light);
  instance('dark', dark);
  b
    ..writeln()
    ..writeln('  @override')
    ..writeln('  AiselliaPalette copyWith() => this;')
    ..writeln()
    ..writeln('  @override')
    ..writeln(
      '  AiselliaPalette lerp(covariant AiselliaPalette? other, double t) {',
    )
    ..writeln('    if (other == null) return this;')
    ..writeln('    return AiselliaPalette(');
  for (final k in colorKeys) {
    final f = _camel(k);
    b.writeln('      $f: Color.lerp($f, other.$f, t)!,');
  }
  for (final k in opacityKeys) {
    final f = _camel(k);
    b.writeln('      $f: $f + (other.$f - $f) * t,');
  }
  b
    ..writeln('    );')
    ..writeln('  }')
    ..writeln('}')
    ..writeln();

  // ---- Spacing, radius, border, layout, media, icon ---------------------
  b.writeln('/// 4-point spacing scale (Phase 2 §4.1). Names equal values.');
  b.writeln('abstract final class Space {');
  (j['space'] as Map<String, dynamic>).forEach((k, v) {
    b.writeln('  static const double s$k = ${_num(v as num)};');
  });
  b.writeln('}');
  b.writeln();
  b.writeln('/// Corner radii (Phase 2 §5). Only these four exist.');
  b.writeln('abstract final class Radii {');
  (j['radius'] as Map<String, dynamic>).forEach((k, v) {
    b.writeln('  static const double $k = ${_num(v as num)};');
  });
  b.writeln('}');
  b.writeln();
  final border = j['border'] as Map<String, dynamic>;
  final pencil = border['pencil'] as Map<String, dynamic>;
  b
    ..writeln(
      '/// Stroke widths and the pencil dash pattern (Phase 2 §1.1, §5).',
    )
    ..writeln('abstract final class Strokes {')
    ..writeln(
      '  static const double hairline = ${_num(border['hairline'] as num)};',
    )
    ..writeln(
      '  static const double control = ${_num(border['control'] as num)};',
    )
    ..writeln('  static const double focus = ${_num(border['focus'] as num)};')
    ..writeln('  static const double pencil = ${_num(pencil['width'] as num)};')
    ..writeln(
      '  static const double pencilDash = ${_num(pencil['dash'] as num)};',
    )
    ..writeln(
      '  static const double pencilGap = ${_num(pencil['gap'] as num)};',
    )
    ..writeln('}')
    ..writeln();
  final layout = j['layout'] as Map<String, dynamic>;
  final bp = layout['breakpoints'] as Map<String, dynamic>;
  final gutter = layout['gutter'] as Map<String, dynamic>;
  final maxW = layout['maxWidth'] as Map<String, dynamic>;
  final small = layout['compactSmall'] as Map<String, dynamic>;
  b.writeln('/// Layout constants (Phase 2 §4.2).');
  b.writeln('abstract final class LayoutTokens {');
  bp.forEach(
    (k, v) => b.writeln(
      '  static const double breakpoint${k[0].toUpperCase()}${k.substring(1)} = ${_num(v as num)};',
    ),
  );
  b.writeln(
    '  static const double compactSmallMaxWidth = ${_num(small['maxWidth'] as num)};',
  );
  b.writeln(
    '  static const double compactSmallMaxHeight = ${_num(small['maxHeight'] as num)};',
  );
  gutter.forEach(
    (k, v) => b.writeln(
      '  static const double gutter${k[0].toUpperCase()}${k.substring(1)} = ${_num(v as num)};',
    ),
  );
  maxW.forEach(
    (k, v) => b.writeln(
      '  static const double maxWidth${k[0].toUpperCase()}${k.substring(1)} = ${_num(v as num)};',
    ),
  );
  for (final k in [
    'minTouchTarget',
    'rowMinHeight',
    'appBarHeight',
    'bottomNavHeight',
    'stickyActionBarMinHeight',
  ]) {
    b.writeln('  static const double $k = ${_num(layout[k] as num)};');
  }
  b.writeln('}');
  b.writeln();
  final icon =
      (j['icon'] as Map<String, dynamic>)['size'] as Map<String, dynamic>;
  final media = j['media'] as Map<String, dynamic>;
  final thumb = media['thumb'] as Map<String, dynamic>;
  b
    ..writeln('/// Icon and media sizes (Phase 2 §6, §7).')
    ..writeln('abstract final class Sizes {')
    ..writeln('  static const double iconSm = ${_num(icon['sm'] as num)};')
    ..writeln('  static const double iconMd = ${_num(icon['md'] as num)};')
    ..writeln('  static const double iconLg = ${_num(icon['lg'] as num)};');
  thumb.forEach(
    (k, v) => b.writeln(
      '  static const double thumb${k[0].toUpperCase()}${k.substring(1)} = ${_num(v as num)};',
    ),
  );
  b
    ..writeln(
      '  static const double thumbRadius = ${_num(media['thumbRadius'] as num)};',
    )
    ..writeln(
      '  static const double avatar = ${_num((media['avatar'] as Map)['size'] as num)};',
    )
    ..writeln(
      '  static const double storeLogo = ${_num((media['storeLogo'] as Map)['size'] as num)};',
    )
    ..writeln('}')
    ..writeln();

  // ---- Type scale --------------------------------------------------------
  final styles = ((j['typography'] as Map)['styles'] as Map)
      .cast<String, dynamic>();
  b
    ..writeln('/// One entry of the per-script type scale (Phase 2 §3.2).')
    ..writeln('@immutable')
    ..writeln('final class TypeSpec {')
    ..writeln('  const TypeSpec({')
    ..writeln('    required this.size,')
    ..writeln('    required this.line,')
    ..writeln('    required this.weight,')
    ..writeln('    this.trackingEm = 0,')
    ..writeln('    this.uppercase = false,')
    ..writeln('    this.tabular = false,')
    ..writeln('  });')
    ..writeln('  final double size;')
    ..writeln('  final double line;')
    ..writeln('  final int weight;')
    ..writeln('  final double trackingEm;')
    ..writeln('  final bool uppercase;')
    ..writeln('  final bool tabular;')
    ..writeln('}')
    ..writeln()
    ..writeln(
      '/// Type scale per script: `en` (Latin) and `ckb` (Arabic script).',
    )
    ..writeln('abstract final class TypeScaleTokens {');
  for (final script in ['en', 'ckb']) {
    styles.forEach((name, v) {
      final s = (v as Map)[script] as Map<String, dynamic>;
      final features = (s['features'] as List?)?.cast<String>() ?? const [];
      b.writeln(
        '  static const TypeSpec ${_camel(name)}${script == 'en' ? 'En' : 'Ckb'} = TypeSpec('
        'size: ${_num(s['size'] as num)}, line: ${_num(s['line'] as num)}, weight: ${s['weight']}'
        '${s['tracking'] != null && (s['tracking'] as num) != 0 ? ', trackingEm: ${_num(s['tracking'] as num)}' : ''}'
        '${s['case'] == 'upper' ? ', uppercase: true' : ''}'
        '${features.contains('tnum') ? ', tabular: true' : ''});',
      );
    });
  }
  b.writeln('}');
  b.writeln();

  // ---- Motion -------------------------------------------------------------
  final motion = j['motion'] as Map<String, dynamic>;
  final dur = motion['duration'] as Map<String, dynamic>;
  final ease = motion['easing'] as Map<String, dynamic>;
  final spring = (motion['spring'] as Map)['sheet'] as Map<String, dynamic>;
  final stagger = motion['stagger'] as Map<String, dynamic>;
  final dist = motion['distance'] as Map<String, dynamic>;
  final skel = motion['skeleton'] as Map<String, dynamic>;
  b.writeln('/// Motion tokens (Phase 2 §06). Use through `Motion`, which');
  b.writeln('/// applies the reduced-motion preference.');
  b.writeln('abstract final class MotionTokens {');
  dur.forEach(
    (k, v) =>
        b.writeln('  static const Duration $k = Duration(milliseconds: $v);'),
  );
  ease.forEach((k, v) {
    if (v is List) {
      b.writeln(
        '  static const Cubic $k = Cubic(${v.map((e) => _num(e as num)).join(', ')});',
      );
    } else {
      b.writeln('  static const Curve $k = Curves.linear;');
    }
  });
  b
    ..writeln(
      '  static const double springMass = ${_num(spring['mass'] as num)};',
    )
    ..writeln(
      '  static const double springStiffness = ${_num(spring['stiffness'] as num)};',
    )
    ..writeln(
      '  static const double springDamping = ${_num(spring['damping'] as num)};',
    )
    ..writeln(
      '  static const Duration staggerPerItem = Duration(milliseconds: ${stagger['perItemMs']});',
    )
    ..writeln('  static const int staggerMaxItems = ${stagger['maxItems']};')
    ..writeln(
      '  static const double distanceSmall = ${_num(dist['small'] as num)};',
    )
    ..writeln(
      '  static const double distanceMedium = ${_num(dist['medium'] as num)};',
    )
    ..writeln(
      '  static const Duration skeletonDelay = Duration(milliseconds: ${skel['delayMs']});',
    )
    ..writeln(
      '  static const Duration skeletonPulse = Duration(milliseconds: ${skel['pulseMs']});',
    )
    ..writeln(
      '  static const double skeletonMinOpacity = ${_num(skel['minOpacity'] as num)};',
    )
    ..writeln(
      '  static const double longContentCrossfadeThreshold = ${_num(motion['longContentCrossfadeThreshold'] as num)};',
    )
    ..writeln('}');
  return b.toString();
}
