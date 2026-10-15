import 'package:flutter/material.dart';

import '../../design_system/components/feedback.dart';
import '../../design_system/components/status.dart';
import '../../design_system/icons/app_icons.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';

/// Inline danger banner at the top of a form (P-ERR-ACTION).
class FormErrorBanner extends StatelessWidget {
  const FormErrorBanner({super.key, required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s16),
    child: AppBanner(
      tone: Tone.danger,
      icon: AppIcons.warningCircle,
      title: message,
      action: action,
    ),
  );
}

/// Screen heading used by auth and setup forms.
class FormHeading extends StatelessWidget {
  const FormHeading({super.key, required this.title, this.body});

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final type = context.type;
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: type.titleLarge.copyWith(color: p.textPrimary),
            ),
          ),
          if (body != null) ...[
            const SizedBox(height: Space.s8),
            Text(body!, style: type.body.copyWith(color: p.textSecondary)),
          ],
        ],
      ),
    );
  }
}
