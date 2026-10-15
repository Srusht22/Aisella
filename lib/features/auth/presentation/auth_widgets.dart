import 'package:flutter/material.dart';

import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/icons/app_icons.dart';
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

/// Password field with a labelled show/hide toggle (AU-03 §16).
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.error,
    this.helper,
    this.enabled = true,
    this.newPassword = false,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction = TextInputAction.done,
  });

  final TextEditingController controller;
  final String label;
  final String? error;
  final String? helper;
  final bool enabled;
  final bool newPassword;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction textInputAction;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppTextField(
      label: widget.label,
      controller: widget.controller,
      error: widget.error,
      helper: widget.helper,
      ltr: true,
      enabled: widget.enabled,
      obscureText: _obscure,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      textInputAction: widget.textInputAction,
      keyboardType: TextInputType.visiblePassword,
      autofillHints: [
        if (widget.newPassword)
          AutofillHints.newPassword
        else
          AutofillHints.password,
      ],
      suffix: IconButton(
        tooltip: _obscure ? l10n.showPassword : l10n.hidePassword,
        icon: Icon(_obscure ? AppIcons.eye : AppIcons.eyeSlash),
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
    );
  }
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
