import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/route_guard.dart';
import '../../../core/config/app_config.dart';
import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/api_error_text.dart';
import '../../common/form_widgets.dart';
import '../../common/store_forms.dart';
import '../../store/domain/store_validation.dart';
import '../application/auth_controller.dart';
import '../domain/auth_status.dart';
import '../domain/credentials.dart';
import 'auth_page.dart';
import 'auth_widgets.dart';

/// AU-03 Sign up (Phase 1 US-001).
class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _fullName = TextEditingController();
  final _storeName = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _submitted = false;
  bool _busy = false;
  AuthFailure? _failure;
  String? _detail;

  @override
  void dispose() {
    for (final c in [
      _fullName,
      _storeName,
      _phone,
      _email,
      _password,
      _confirm,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _submitted = true;
      _failure = null;
    });
    final (phone, phoneIssue) = parseContactPhone(_phone.text);
    if (_fullNameIssue != null ||
        validateStoreName(_storeName.text) != null ||
        phoneIssue != null ||
        validateEmail(_email.text) != null ||
        validateNewPassword(_password.text) != null ||
        _confirmIssue != null) {
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
            profile: SignUpProfile(
              fullName: _fullName.text.trim(),
              phone: phone!,
              storeName: _storeName.text.trim(),
            ),
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

  static const _maxFullName = 80;

  String? get _fullNameIssue {
    final n = _fullName.text.trim();
    if (n.isEmpty) return context.l10n.errFullNameRequired;
    if (n.runes.length > _maxFullName) {
      return context.l10n.errTooLongMax('$_maxFullName');
    }
    return null;
  }

  String? get _confirmIssue =>
      _confirm.text == _password.text ? null : context.l10n.errPasswordsDiffer;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final emailInUse = _failure == AuthFailure.emailInUse;
    final email = normalizeEmail(_email.text);

    return AuthPage(
      title: l10n.signUpTitle,
      subtitle: l10n.signUpSubtitle,
      icon: AppIcons.storefrontFill,
      card: [
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
              AppTextField(
                label: l10n.fieldFullName,
                controller: _fullName,
                enabled: !_busy,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                error: _submitted ? _fullNameIssue : null,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.s16),
              AppTextField(
                label: l10n.fieldStoreName,
                controller: _storeName,
                enabled: !_busy,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.organizationName],
                error: _submitted
                    ? fieldIssueText(
                        l10n,
                        'name',
                        validateStoreName(_storeName.text),
                      )
                    : null,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.s16),
              AppTextField(
                label: l10n.fieldPhone,
                controller: _phone,
                enabled: !_busy,
                ltr: true,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.telephoneNumber],
                helper: l10n.phoneHelper(phoneExample),
                error: _submitted
                    ? fieldIssueText(
                        l10n,
                        'phone',
                        parseContactPhone(_phone.text).$2,
                      )
                    : null,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.s16),
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
                textInputAction: TextInputAction.next,
              ),
              PasswordStrengthMeter(password: _password.text),
              const SizedBox(height: Space.s16),
              PasswordField(
                controller: _confirm,
                label: l10n.fieldConfirmPassword,
                newPassword: true,
                enabled: !_busy,
                error: _submitted ? _confirmIssue : null,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.s16),
        const TermsConsent(),
        const SizedBox(height: Space.s20),
        AppButton(
          label: l10n.welcomeCreateAccount,
          loadingLabel: l10n.creatingAccount,
          loading: _busy,
          expand: true,
          onPressed: _submit,
        ),
      ],
      footer: [
        AuthSwitchLink(
          prompt: l10n.alreadyHaveAccount,
          action: l10n.signIn,
          onPressed: _busy ? null : () => context.go(Routes.signIn),
        ),
      ],
    );
  }
}
