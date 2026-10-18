import 'package:flutter/material.dart';

import '../../../core/l10n/l10n.dart';
import '../../common/form_page.dart';
import 'auth_page.dart';

/// Terms of Service and Privacy Policy (ST-10), opened from Settings. Shows
/// the same plain-language summary as the sign-up sheet; the reviewed legal
/// text does not exist yet (owner action, legal review AD-06).
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) => FormPage(
    title: context.l10n.termsAndPrivacy,
    children: const [TermsSummary()],
  );
}
