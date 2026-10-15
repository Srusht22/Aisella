import 'package:flutter/material.dart';

import '../../../core/l10n/l10n.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../common/form_page.dart';

/// Terms of Service and Privacy Policy (ST-10). The legal documents do not
/// exist yet (owner action, legal review AD-06), so the screen says so
/// instead of showing invented terms.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FormPage(
      title: l10n.termsAndPrivacy,
      children: [
        Text(
          l10n.termsPendingBody,
          style: context.type.bodyLarge.copyWith(
            color: context.palette.textPrimary,
          ),
        ),
      ],
    );
  }
}
