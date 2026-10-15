import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/route_guard.dart';

import '../../core/backend/api.dart';
import '../../core/backend/idempotency.dart';
import '../../core/formatting/bidi.dart';
import '../../core/formatting/money.dart';
import '../../core/l10n/l10n.dart';
import '../../core/settings/app_settings.dart';
import '../../design_system/components/app_button.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/components/inputs.dart';
import '../../design_system/components/overlays.dart';
import '../../design_system/components/rows.dart';
import '../../design_system/components/status.dart';
import '../../design_system/icons/app_icons.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../auth/application/auth_controller.dart';
import '../auth/domain/auth_status.dart';
import '../common/api_error_text.dart';
import '../common/form_page.dart';
import '../common/form_widgets.dart';
import '../common/store_forms.dart';
import '../store/application/workspace_controller.dart';
import '../store/domain/store.dart';
import '../store/domain/store_validation.dart';

/// ST-02 Store profile. Shows server values; edits are local until Save
/// succeeds (unsaved changes are kept distinct and guarded on Back).
class StoreProfileScreen extends ConsumerStatefulWidget {
  const StoreProfileScreen({super.key});

  @override
  ConsumerState<StoreProfileScreen> createState() => _StoreProfileScreenState();
}

class _StoreProfileScreenState extends ConsumerState<StoreProfileScreen> {
  StoreBasicsValues? _values;
  Store? _base;
  final _intent = IntentKey();
  bool _busy = false;
  ApiException? _error;

  StoreBasicsValues _valuesFor(Store store) {
    if (_values == null || _base?.id != store.id) {
      _discardValues();
      _values = StoreBasicsValues(from: store, defaultReplyLocale: 'ckb')
        ..addListener(_changed);
      _base = store;
    }
    return _values!;
  }

  /// Drops the edited values. The old controllers may still be attached to
  /// fields in the current frame, so they are disposed after it.
  void _discardValues() {
    final old = _values;
    _values = null;
    if (old == null) return;
    old.removeListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  void _changed() => setState(() {});

  bool get _dirty {
    final values = _values;
    final base = _base;
    return values != null && base != null && values.differsFrom(base);
  }

  @override
  void dispose() {
    _values?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final values = _values;
    final base = _base;
    if (_busy || values == null || base == null) return;
    final draft = values.validate();
    setState(() => _error = null);
    if (draft == null) return;
    final changes = values.changesFrom(base, draft);
    if (changes.isEmpty) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final saved = context.l10n.saved;
    try {
      final store = await ref
          .read(workspaceProvider.notifier)
          .updateStore(
            changes: changes,
            idempotencyKey: _intent.forPayload(changes.toString()),
          );
      _intent.reset();
      _base = store;
      showSnackOn(messenger, saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ApiErrorCode.validationFailed && e.fields.isNotEmpty) {
        values.applyServerIssues(e.fields);
      } else {
        if (e.code == ApiErrorCode.conflictVersion) {
          // Show the latest server values; the seller re-applies the change.
          await _refreshQuietly(ref);
          _discardValues();
        }
        setState(() => _error = e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final store = ref.watch(workspaceProvider).value?.store;
    if (store == null) return const SizedBox.shrink();
    final values = _valuesFor(store);
    return UnsavedChangesGuard(
      dirty: !_busy && _dirty,
      child: FormPage(
        title: l10n.menuStoreProfile,
        bottom: formActions(
          primary: AppButton(
            label: l10n.save,
            loadingLabel: l10n.saving,
            loading: _busy,
            expand: true,
            onPressed: _save,
          ),
        ),
        children: [
          if (_error != null)
            FormErrorBanner(message: apiErrorText(l10n, _error!)),
          StoreBasicsForm(
            values: values,
            enabled: !_busy,
            currencyLocked: store.currencyLocked,
          ),
        ],
      ),
    );
  }
}

/// ST-03 Delivery zones.
class DeliveryZonesScreen extends ConsumerWidget {
  const DeliveryZonesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final zones = ref.watch(zonesProvider);
    final store = ref.watch(workspaceProvider).value?.store;
    final digits = ref.watch(settingsProvider).digits;
    final locale = Localizations.localeOf(context);
    final currency = store?.currency ?? Currency.iqd;

    Future<void> edit([DeliveryZone? zone]) => showAppSheet<void>(
      context: context,
      title: zone == null ? l10n.addZone : l10n.editZone,
      builder: (_) => _ZoneEditor(
        zone: zone,
        currency: currency,
        taken: [
          for (final z in zones.value ?? const <DeliveryZone>[])
            if (z.id != zone?.id) z.name,
        ],
      ),
    );

    return FormPage(
      title: l10n.menuDeliveryZones,
      bottom: formActions(
        primary: AppButton(
          label: l10n.addZone,
          icon: AppIcons.plus,
          expand: true,
          onPressed: zones.hasValue ? edit : null,
        ),
      ),
      children: [
        switch (zones) {
          AsyncValue(:final value?) when value.isEmpty => AppBanner(
            tone: Tone.warning,
            icon: AppIcons.info,
            title: l10n.noZonesTitle,
            body: l10n.zonesWarning,
          ),
          AsyncValue(:final value?) => RowGroup(
            children: [
              for (final z in value)
                NavRow(
                  label: z.timeText == null
                      ? z.name
                      : '${z.name} · ${z.timeText}',
                  icon: AppIcons.mapPin,
                  trailing: Text(
                    Money.format(
                      z.fee,
                      currency,
                      locale: locale,
                      digits: digits,
                    ),
                  ),
                  onTap: () => edit(z),
                ),
            ],
          ),
          AsyncValue(:final error?) => ErrorState(
            cause: error is ApiException
                ? apiErrorText(l10n, error)
                : l10n.errorServer,
            onRetry: () => ref.invalidate(zonesProvider),
          ),
          _ => const SkeletonBlock(height: 168),
        },
        const SizedBox(height: Space.s16),
        Text(
          l10n.zoneFeeNote,
          style: context.type.caption.copyWith(color: p.textSecondary),
        ),
      ],
    );
  }
}

class _ZoneEditor extends ConsumerStatefulWidget {
  const _ZoneEditor({
    required this.zone,
    required this.currency,
    required this.taken,
  });

  final DeliveryZone? zone;
  final Currency currency;
  final List<String> taken;

  @override
  ConsumerState<_ZoneEditor> createState() => _ZoneEditorState();
}

class _ZoneEditorState extends ConsumerState<_ZoneEditor> {
  late final _name = TextEditingController(text: widget.zone?.name ?? '');
  late final _fee = TextEditingController(
    text: widget.zone == null ? '' : '${widget.zone!.fee}',
  );
  late final _time = TextEditingController(text: widget.zone?.timeText ?? '');
  final _intent = IntentKey();
  FieldIssue? _nameIssue;
  FieldIssue? _feeIssue;
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    _name.dispose();
    _fee.dispose();
    _time.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final (fee, feeIssue) = parseFee(_fee.text);
    setState(() {
      _error = null;
      _nameIssue = validateZoneName(_name.text, taken: widget.taken);
      _feeIssue = feeIssue;
    });
    if (_nameIssue != null || _feeIssue != null) return;
    final name = _name.text.trim();
    final time = _time.text.trim();
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final saved = context.l10n.zoneSaved;
    try {
      await ref
          .read(zoneActionsProvider)
          .save(
            existing: widget.zone,
            name: name,
            fee: fee!,
            timeText: time.isEmpty ? null : time,
            idempotencyKey: _intent.forPayload('$name\u0000$fee\u0000$time'),
          );
      navigator.pop();
      showSnackOn(messenger, saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == ApiErrorCode.validationFailed && e.fields.isNotEmpty) {
          _nameIssue = e.fields['name'] == null
              ? null
              : fieldIssueFromServer(e.fields['name']!);
          _feeIssue = e.fields['fee'] == null ? null : FieldIssue.invalid;
        } else {
          _error = e;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final zone = widget.zone;
    if (zone == null || _busy) return;
    final l10n = context.l10n;
    final confirmed = await showConfirmDialog(
      context: context,
      title: l10n.removeZoneTitle(zone.name),
      body: l10n.removeZoneBody,
      confirmLabel: l10n.remove,
      cancelLabel: l10n.cancel,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(zoneActionsProvider).remove(zone);
      navigator.pop();
      showSnackOn(messenger, l10n.zoneRemoved);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = _name.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null)
          FormErrorBanner(message: apiErrorText(l10n, _error!)),
        AppTextField(
          label: l10n.fieldAreaName,
          controller: _name,
          enabled: !_busy,
          error: fieldIssueText(l10n, 'zoneName', _nameIssue),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.s12),
        ZoneFields(
          feeLabel: name.isEmpty ? l10n.fieldFee : l10n.fieldFeeFor(name),
          fee: _fee,
          time: _time,
          currency: widget.currency,
          enabled: !_busy,
          feeError: fieldIssueText(l10n, 'fee', _feeIssue),
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.save,
          loadingLabel: l10n.saving,
          loading: _busy,
          expand: true,
          onPressed: _save,
        ),
        if (widget.zone != null) ...[
          const SizedBox(height: Space.s8),
          AppButton(
            label: l10n.removeZone,
            variant: AppButtonVariant.dangerOutline,
            expand: true,
            onPressed: _busy ? null : _remove,
          ),
        ],
      ],
    );
  }
}

/// ST-04 Payments: each switch saves immediately, with progress on the
/// switches and no success shown before the server confirms.
class PaymentsScreen extends ConsumerStatefulWidget {
  const PaymentsScreen({super.key});

  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends ConsumerState<PaymentsScreen> {
  bool _busy = false;
  String? _message;

  Future<void> _set({required bool cod, required bool other}) async {
    if (_busy) return;
    final l10n = context.l10n;
    if (!cod && !other) {
      setState(() => _message = l10n.errPaymentAtLeastOne);
      return;
    }
    final store = ref.read(workspaceProvider).value?.store;
    if (store == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(workspaceProvider.notifier)
          .updateStore(
            changes: {
              if (cod != store.codEnabled) 'cod_enabled': cod,
              if (other != store.otherPaymentEnabled)
                'other_payment_enabled': other,
            },
            idempotencyKey: newIdempotencyKey(),
          );
      showSnackOn(messenger, l10n.saved);
    } on ApiException catch (e) {
      if (e.code == ApiErrorCode.conflictVersion) {
        await _refreshQuietly(ref);
      }
      if (mounted) setState(() => _message = apiErrorText(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final store = ref.watch(workspaceProvider).value?.store;
    if (store == null) return const SizedBox.shrink();
    return FormPage(
      title: l10n.menuPayments,
      children: [
        if (_message != null) FormErrorBanner(message: _message!),
        RowGroup(
          children: [
            PaymentSwitches(
              cod: store.codEnabled,
              other: store.otherPaymentEnabled,
              onChanged: _busy ? null : _set,
            ),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: Space.s12),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }
}

/// ST-07 Account: email and verification state, password change by email
/// link, sign out here or everywhere.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  bool _busy = false;
  String? _message;

  Future<void> _changePassword(String email) async {
    if (_busy) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _message = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .requestPasswordReset(email);
      showSnackOn(messenger, l10n.changePasswordSent(Bidi.ltr(email)));
    } on AuthError catch (e) {
      if (mounted) setState(() => _message = authFailureText(l10n, e.failure));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOutEverywhere() async {
    final l10n = context.l10n;
    final confirmed = await showConfirmDialog(
      context: context,
      title: l10n.signOutAllTitle,
      body: l10n.signOutAllBody,
      confirmLabel: l10n.menuSignOut,
      cancelLabel: l10n.cancel,
      destructive: true,
    );
    if (confirmed) {
      await ref.read(authControllerProvider.notifier).signOut(allDevices: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final auth = ref.watch(authControllerProvider);
    final user = auth is SignedIn ? auth.user : null;
    if (user == null) return const SizedBox.shrink();
    return FormPage(
      title: l10n.accountTitle,
      children: [
        if (_message != null) FormErrorBanner(message: _message!),
        RowGroup(
          children: [
            FieldRow(
              label: l10n.fieldEmail,
              value: Text(
                user.email,
                textDirection: TextDirection.ltr,
                style: type.body.copyWith(color: p.textPrimary),
              ),
              caption: StatusBadge(
                label: user.emailVerified
                    ? l10n.emailVerified
                    : l10n.emailNotVerified,
                icon: user.emailVerified
                    ? AppIcons.checkCircle
                    : AppIcons.warningCircle,
                tone: user.emailVerified ? Tone.success : Tone.warning,
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.s24),
        RowGroup(
          children: [
            NavRow(
              label: l10n.changePassword,
              icon: AppIcons.lockKey,
              onTap: _busy ? null : () => _changePassword(user.email),
            ),
            NavRow(
              label: l10n.signOutAllDevices,
              icon: AppIcons.signOut,
              onTap: _busy ? null : _signOutEverywhere,
            ),
          ],
        ),
        const SizedBox(height: Space.s24),
        RowGroup(
          children: [
            NavRow(
              label: l10n.deleteAccount,
              icon: AppIcons.trash,
              iconColor: p.dangerFg,
              labelColor: p.dangerFg,
              onTap: _busy
                  ? null
                  : () => context.push(Routes.storeDeleteAccount),
            ),
          ],
        ),
      ],
    );
  }
}

/// Picks up the latest server state after a conflict without leaving the
/// screen. A failure here leaves the current values; the conflict message is
/// shown either way.
Future<void> _refreshQuietly(WidgetRef ref) async {
  try {
    await ref.read(workspaceProvider.notifier).refresh();
  } on ApiException {
    // Keep what is on screen.
  }
}

/// ST-08 Delete account: what will be deleted and the grace period, then the
/// password (re-authentication) and the store name. Failure leaves everything
/// intact and says so (US-004).
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  bool _submitted = false;
  String? _message;

  @override
  void dispose() {
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _delete(String? storeName) async {
    if (_busy) return;
    final l10n = context.l10n;
    setState(() {
      _submitted = true;
      _message = null;
    });
    if (_password.text.isEmpty ||
        (storeName != null && _name.text.trim() != storeName)) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .reauthenticate(_password.text);
      await ref
          .read(workspaceProvider.notifier)
          .requestAccountDeletion(_name.text.trim());
      // The router now shows the closed-account screen.
    } on AuthError catch (e) {
      if (mounted) {
        setState(
          () => _message =
              '${authFailureText(l10n, e.failure)} ${l10n.deleteFailedNothingDeleted}',
        );
      }
    } on ApiException {
      if (mounted) setState(() => _message = l10n.deleteFailedNothingDeleted);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final storeName = ref.watch(workspaceProvider).value?.store?.name;
    final nameMatches = storeName == null || _name.text.trim() == storeName;
    return FormPage(
      title: l10n.deleteAccount,
      bottom: formActions(
        primary: AppButton(
          label: l10n.deleteAccount,
          loadingLabel: l10n.deletingAccount,
          variant: AppButtonVariant.danger,
          loading: _busy,
          expand: true,
          onPressed: nameMatches && _password.text.isNotEmpty
              ? () => _delete(storeName)
              : null,
        ),
      ),
      children: [
        if (_message != null) FormErrorBanner(message: _message!),
        AppBanner(
          tone: Tone.danger,
          icon: AppIcons.warning,
          title: l10n.deleteAccountWhat,
          body: l10n.deleteAccountGrace,
        ),
        const SizedBox(height: Space.s24),
        Text(
          l10n.deleteAccountPassword,
          style: type.body.copyWith(color: p.textPrimary),
        ),
        const SizedBox(height: Space.s8),
        PasswordField(
          controller: _password,
          label: l10n.fieldPassword,
          enabled: !_busy,
          error: _submitted && _password.text.isEmpty
              ? l10n.errPasswordRequired
              : null,
          onChanged: (_) => setState(() {}),
        ),
        if (storeName != null) ...[
          const SizedBox(height: Space.s24),
          AppTextField(
            label: l10n.deleteAccountTypeName(storeName),
            controller: _name,
            enabled: !_busy,
            error: _submitted && !nameMatches
                ? l10n.errStoreNameMismatch
                : null,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
    );
  }
}
