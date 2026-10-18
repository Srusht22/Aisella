import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/route_guard.dart';
import '../../../core/config/app_config.dart';
import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/api_error_text.dart';
import '../../common/form_page.dart';
import '../../common/form_widgets.dart';
import '../application/auth_controller.dart';
import '../domain/auth_status.dart';
import '../domain/credentials.dart';
import 'auth_widgets.dart';

/// AU-03 Sign up (Phase 1 US-001).
class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _submitted = false;
  bool _busy = false;
  AuthFailure? _failure;
  String? _detail;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _submitted = true;
      _failure = null;
    });
    if (validateEmail(_email.text) != null ||
        validateNewPassword(_password.text) != null) {
      return;
    }
    setState(() => _busy = true);
    final email = normalizeEmail(_email.text);
    try {
      final outcome = await ref
          .read(authControllerProvider.notifier)
          .signUp(
            email: email,
            password: _password.text,
            termsVersion: currentTermsVersion,
          );
      if (!mounted) return;
      if (outcome == SignUpOutcome.verificationRequired) {
        context.go(
          Uri(
            path: Routes.verifyEmail,
            queryParameters: {'email': email},
          ).toString(),
        );
      }
      // signedIn: the router moves on as soon as the session state changes.
    } on AuthError catch (e) {
      if (mounted) {
        setState(() {
          _failure = e.failure;
          _detail = e.detail;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final emailInUse = _failure == AuthFailure.emailInUse;
    final email = normalizeEmail(_email.text);

    return FormPage(
      bottom: formActions(
        primary: AppButton(
          label: l10n.welcomeCreateAccount,
          loadingLabel: l10n.creatingAccount,
          loading: _busy,
          expand: true,
          onPressed: _submit,
        ),
      ),
      children: [
        FormHeading(title: l10n.signUpTitle),
        if (_failure != null && !emailInUse)
          FormErrorBanner(
            message: authFailureWithDetail(
              l10n,
              _failure!,
              isProduction: ref.read(appConfigProvider).isProduction,
              detail: _detail,
            ),
          ),
        AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EmailField(
                controller: _email,
                newAccount: true,
                enabled: !_busy,
                error: emailInUse
                    ? l10n.errEmailInUse
                    : _submitted
                    ? emailIssueText(l10n, validateEmail(_email.text))
                    : null,
                onChanged: (_) => setState(() {
                  if (emailInUse) _failure = null;
                }),
              ),
              if (emailInUse)
                Wrap(
                  spacing: Space.s8,
                  children: [
                    TextButton(
                      onPressed: () => context.go(
                        Uri(
                          path: Routes.signIn,
                          queryParameters: {'email': email},
                        ).toString(),
                      ),
                      child: Text(l10n.signIn),
                    ),
                    TextButton(
                      onPressed: () => context.go(
                        Uri(
                          path: Routes.forgotPassword,
                          queryParameters: {'email': email},
                        ).toString(),
                      ),
                      child: Text(l10n.resetPassword),
                    ),
                  ],
                ),
              const SizedBox(height: Space.s16),
              PasswordField(
                controller: _password,
                label: l10n.fieldPassword,
                helper: l10n.passwordHelper,
                newPassword: true,
                enabled: !_busy,
                error: _submitted
                    ? passwordIssueText(
                        l10n,
                        validateNewPassword(_password.text),
                      )
                    : null,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.s16),
        Text(
          l10n.termsConsent,
          style: type.caption.copyWith(color: p.textSecondary),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => context.push(Routes.terms),
            child: Text(l10n.termsAndPrivacy),
          ),
        ),
        const SizedBox(height: Space.s8),
        AuthSwitchLink(
          prompt: l10n.alreadyHaveAccount,
          action: l10n.signIn,
          onPressed: _busy ? null : () => context.go(Routes.signIn),
        ),
      ],
    );
  }
}
