import 'package:flutter/material.dart';

import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../domain/credentials.dart';

String? emailIssueText(AppLocalizations l10n, EmailIssue? issue) =>
    switch (issue) {
      EmailIssue.required => l10n.errEmailRequired,
      EmailIssue.invalid => l10n.errEmailInvalid,
      null => null,
    };

String? passwordIssueText(AppLocalizations l10n, PasswordIssue? issue) =>
    switch (issue) {
      PasswordIssue.required => l10n.errPasswordRequired,
      PasswordIssue.tooShort => l10n.errPasswordTooShort,
      null => null,
    };

/// Email field: always LTR (Phase 2 AU-03 §17), email keyboard and autofill.
class EmailField extends StatelessWidget {
  const EmailField({
    super.key,
    required this.controller,
    this.error,
    this.enabled = true,
    this.onChanged,
    this.newAccount = false,
  });

  final TextEditingController controller;
  final String? error;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final bool newAccount;

  @override
  Widget build(BuildContext context) => AppTextField(
    label: context.l10n.fieldEmail,
    controller: controller,
    error: error,
    ltr: true,
    enabled: enabled,
    onChanged: onChanged,
    keyboardType: TextInputType.emailAddress,
    textInputAction: TextInputAction.next,
    autofillHints: [
      if (newAccount) AutofillHints.newUsername else AutofillHints.username,
      AutofillHints.email,
    ],
  );
}

/// "Prompt? Action" line, for example "Already have an account? Sign in".
class AuthSwitchLink extends StatelessWidget {
  const AuthSwitchLink({
    super.key,
    required this.prompt,
    required this.action,
    required this.onPressed,
  });

  final String prompt;
  final String action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final type = context.type;
    final p = context.palette;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(prompt, style: type.body.copyWith(color: p.textSecondary)),
        TextButton(onPressed: onPressed, child: Text(action)),
      ],
    );
  }
}
