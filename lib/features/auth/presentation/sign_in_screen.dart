import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/route_guard.dart';
import '../../../core/config/app_config.dart';
import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/api_error_text.dart';
import '../../common/form_widgets.dart';
import '../application/auth_controller.dart';
import '../domain/auth_status.dart';
import '../domain/credentials.dart';
import 'auth_page.dart';
import 'auth_widgets.dart';

/// AU-04 Sign in (Phase 1 US-002). Success needs no navigation here: the
/// router moves the seller on when the session state changes.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, this.initialEmail});

  final String? initialEmail;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  late final _email = TextEditingController(text: widget.initialEmail ?? '');
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
        validateExistingPassword(_password.text) != null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .signIn(email: normalizeEmail(_email.text), password: _password.text);
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

  void _openVerify() => context.go(
    Uri(
      path: Routes.verifyEmail,
      queryParameters: {'email': normalizeEmail(_email.text)},
    ).toString(),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final auth = ref.watch(authControllerProvider);
    final expired =
        auth is SignedOut && auth.reason == SignedOutReason.sessionExpired;

    return AuthPage(
      title: l10n.signInTitle,
      subtitle: l10n.signInSubtitle,
      icon: AppIcons.sparkleFill,
      card: [
        if (expired && _failure == null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s16),
            child: AppBanner(
              tone: Tone.info,
              icon: AppIcons.info,
              title: l10n.sessionExpiredBanner,
            ),
          ),
        if (_failure != null)
          FormErrorBanner(
            message: authFailureWithDetail(
              l10n,
              _failure!,
              isProduction: ref.read(appConfigProvider).isProduction,
              detail: _detail,
            ),
            action: _failure == AuthFailure.emailNotConfirmed
                ? TextButton(
                    onPressed: _openVerify,
                    child: Text(l10n.resendEmail),
                  )
                : null,
          ),
        AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EmailField(
                controller: _email,
                enabled: !_busy,
                error: _submitted
                    ? emailIssueText(l10n, validateEmail(_email.text))
                    : null,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.s16),
              PasswordField(
                controller: _password,
                label: l10n.fieldPassword,
                enabled: !_busy,
                error: _submitted
                    ? passwordIssueText(
                        l10n,
                        validateExistingPassword(_password.text),
                      )
                    : null,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            onPressed: _busy
                ? null
                : () => context.go(
                    Uri(
                      path: Routes.forgotPassword,
                      queryParameters: {
                        if (_email.text.trim().isNotEmpty)
                          'email': normalizeEmail(_email.text),
                      },
                    ).toString(),
                  ),
            child: Text(l10n.forgotPassword),
          ),
        ),
        const SizedBox(height: Space.s8),
        AppButton(
          label: l10n.signIn,
          loadingLabel: l10n.signingIn,
          loading: _busy,
          expand: true,
          onPressed: _submit,
        ),
      ],
      footer: [
        AuthSwitchLink(
          prompt: l10n.newToAisellia,
          action: l10n.welcomeCreateAccount,
          onPressed: _busy ? null : () => context.go(Routes.signUp),
        ),
      ],
    );
  }
}
