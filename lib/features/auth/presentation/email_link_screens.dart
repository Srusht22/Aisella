import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/route_guard.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/api_error_text.dart';
import '../../common/form_page.dart';
import '../../common/form_widgets.dart';
import '../application/auth_controller.dart';
import '../domain/auth_status.dart';
import '../domain/credentials.dart';
import 'auth_widgets.dart';

/// Provider-side resend frequency (supabase/config.toml `max_frequency`).
const resendCooldown = Duration(seconds: 60);

/// Counts down the resend cooldown (AU-05/AU-06: visible and announced).
mixin _Cooldown<T extends StatefulWidget> on State<T> {
  Timer? _timer;
  int _remaining = 0;

  void startCooldown() {
    _timer?.cancel();
    setState(() => _remaining = resendCooldown.inSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _remaining--);
      if (_remaining <= 0) t.cancel();
    });
  }

  bool get coolingDown => _remaining > 0;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// AU-06 Verify email, adapted to the provider (Phase 5 decision P5-D1):
/// Supabase requires the address to be verified before the first sign-in, so
/// this screen waits for the link instead of offering "Continue setup".
/// Opening the link on this phone signs the seller in and continues setup.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key, required this.email});

  final String email;

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen>
    with _Cooldown {
  bool _busy = false;
  AuthFailure? _failure;

  @override
  void initState() {
    super.initState();
    // An email was just sent by sign-up: the provider refuses another one
    // within the cooldown.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) startCooldown();
    });
  }

  Future<void> _resend() async {
    if (_busy || coolingDown || widget.email.isEmpty) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .resendVerification(widget.email);
      if (!mounted) return;
      startCooldown();
      showAppSnackBar(context, context.l10n.verificationSent);
    } on AuthError catch (e) {
      if (mounted) setState(() => _failure = e.failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    return FormPage(
      showBack: false,
      bottom: formActions(
        primary: AppButton(
          label: coolingDown ? l10n.resendIn(_remaining) : l10n.resendEmail,
          variant: AppButtonVariant.secondary,
          loading: _busy,
          loadingLabel: l10n.sendingResetLink,
          expand: true,
          onPressed: coolingDown || widget.email.isEmpty ? null : _resend,
        ),
      ),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Icon(AppIcons.envelopeSimple, size: 40, color: p.brandPrimary),
        ),
        const SizedBox(height: Space.s16),
        FormHeading(
          title: l10n.verifyTitle,
          body: l10n.verifyBody(Bidi.ltr(widget.email)),
        ),
        if (_failure != null)
          FormErrorBanner(message: authFailureText(l10n, _failure!)),
        Text(
          l10n.verifyOtherDevice,
          style: type.body.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: Space.s8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => context.go(
              Uri(
                path: Routes.signIn,
                queryParameters: {'email': widget.email},
              ).toString(),
            ),
            child: Text(l10n.backToSignIn),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => context.go(Routes.signUp),
            child: Text(l10n.wrongEmail),
          ),
        ),
      ],
    );
  }
}

/// AU-05 Reset password: the response is identical whether or not an
/// account exists (US-003).
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail});

  final String? initialEmail;

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen>
    with _Cooldown {
  late final _email = TextEditingController(text: widget.initialEmail ?? '');
  bool _submitted = false;
  bool _busy = false;
  String? _sentTo;
  AuthFailure? _failure;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || coolingDown) return;
    setState(() {
      _submitted = true;
      _failure = null;
    });
    if (validateEmail(_email.text) != null) return;
    final email = normalizeEmail(_email.text);
    setState(() => _busy = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .requestPasswordReset(email);
      if (!mounted) return;
      setState(() => _sentTo = email);
      startCooldown();
    } on AuthError catch (e) {
      if (mounted) setState(() => _failure = e.failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final sent = _sentTo != null;
    return FormPage(
      bottom: formActions(
        primary: AppButton(
          label: !sent
              ? l10n.sendResetLink
              : coolingDown
              ? l10n.resendIn(_remaining)
              : l10n.resendEmail,
          variant: sent ? AppButtonVariant.secondary : AppButtonVariant.primary,
          loading: _busy,
          loadingLabel: l10n.sendingResetLink,
          expand: true,
          onPressed: coolingDown ? null : _send,
        ),
      ),
      children: [
        FormHeading(title: l10n.resetTitle, body: sent ? null : l10n.resetBody),
        if (_failure != null)
          FormErrorBanner(message: authFailureText(l10n, _failure!)),
        AnimatedSwitcher(
          duration: Motion.fade(context, MotionTokens.md),
          child: sent
              ? Semantics(
                  key: const ValueKey('sent'),
                  liveRegion: true,
                  child: Text(
                    l10n.resetSent(Bidi.ltr(_sentTo!)),
                    style: type.bodyLarge.copyWith(color: p.textPrimary),
                  ),
                )
              : EmailField(
                  key: const ValueKey('form'),
                  controller: _email,
                  enabled: !_busy,
                  error: _submitted
                      ? emailIssueText(l10n, validateEmail(_email.text))
                      : null,
                  onChanged: (_) => setState(() {}),
                ),
        ),
        const SizedBox(height: Space.s16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => context.go(Routes.signIn),
            child: Text(l10n.backToSignIn),
          ),
        ),
      ],
    );
  }
}

/// Opened from a password-reset link: the seller holds a restricted recovery
/// session and must choose a new password (or cancel, which signs out).
class NewPasswordScreen extends ConsumerStatefulWidget {
  const NewPasswordScreen({super.key});

  @override
  ConsumerState<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

class _NewPasswordScreenState extends ConsumerState<NewPasswordScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _submitted = false;
  bool _busy = false;
  AuthFailure? _failure;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _mismatch => _confirm.text != _password.text;

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _submitted = true;
      _failure = null;
    });
    if (validateNewPassword(_password.text) != null || _mismatch) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final changed = context.l10n.passwordChanged;
    try {
      await ref
          .read(authControllerProvider.notifier)
          .updatePassword(_password.text);
      // Shown only after the provider confirmed the change.
      showSnackOn(messenger, changed);
    } on AuthError catch (e) {
      if (mounted) setState(() => _failure = e.failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FormPage(
      showBack: false,
      bottom: formActions(
        primary: AppButton(
          label: l10n.savePassword,
          loadingLabel: l10n.savingPassword,
          loading: _busy,
          expand: true,
          onPressed: _save,
        ),
        secondary: AppButton(
          label: l10n.cancel,
          variant: AppButtonVariant.tertiary,
          onPressed: _busy
              ? null
              : () => ref.read(authControllerProvider.notifier).signOut(),
        ),
      ),
      children: [
        FormHeading(title: l10n.newPasswordTitle),
        if (_failure != null)
          FormErrorBanner(message: authFailureText(l10n, _failure!)),
        PasswordField(
          controller: _password,
          label: l10n.fieldNewPassword,
          helper: l10n.passwordHelper,
          newPassword: true,
          enabled: !_busy,
          textInputAction: TextInputAction.next,
          error: _submitted
              ? passwordIssueText(l10n, validateNewPassword(_password.text))
              : null,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.s16),
        PasswordField(
          controller: _confirm,
          label: l10n.fieldConfirmPassword,
          newPassword: true,
          enabled: !_busy,
          error: _submitted && _mismatch ? l10n.errPasswordMismatch : null,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
        ),
      ],
    );
  }
}
