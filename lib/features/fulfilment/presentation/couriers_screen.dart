import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/config/features.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/formatting/money.dart';
import '../../../core/formatting/phone.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/form_widgets.dart';
import '../../common/fulfilment_labels.dart';
import '../../common/order_labels.dart';
import '../../store/application/workspace_controller.dart';
import '../application/fulfilment_providers.dart';
import '../domain/fulfilment.dart';

/// The store's couriers (Phase 10): who delivers, the cash each still owes
/// for delivered orders, and recording the cash they hand over.
class CouriersScreen extends ConsumerWidget {
  const CouriersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final couriers = ref.watch(couriersProvider(true));
    final Widget body = switch (couriers) {
      AsyncError(:final error) => ErrorState(
        cause: error is ApiException
            ? fulfilmentErrorText(l10n, error)
            : l10n.errorServer,
        onRetry: () => ref.invalidate(couriersProvider(true)),
      ),
      AsyncData(:final value) when value.isEmpty => EmptyState(
        icon: AppIcons.truck,
        title: l10n.couriersEmpty,
        action: AppButton(
          label: l10n.addCourier,
          icon: AppIcons.plus,
          onPressed: () => showCourierSheet(context),
        ),
      ),
      AsyncData(:final value) => ListView(
        children: [
          ContentWidth(
            maxWidth: LayoutTokens.maxWidthForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.s12),
                for (final c in value) ...[
                  _CourierCard(courier: c),
                  const SizedBox(height: Space.s8),
                ],
                const SizedBox(height: Space.s8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: AppButton(
                    label: l10n.addCourier,
                    icon: AppIcons.plus,
                    variant: AppButtonVariant.secondary,
                    onPressed: () => showCourierSheet(context),
                  ),
                ),
                const SizedBox(height: Space.s32),
              ],
            ),
          ),
        ],
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
    return Scaffold(
      backgroundColor: p.bgCanvas,
      appBar: AppBar(title: Text(l10n.couriersTitle)),
      body: body,
    );
  }
}

class _CourierCard extends ConsumerWidget {
  const _CourierCard({required this.courier});

  final Courier courier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final currency =
        ref.watch(workspaceProvider).value?.store?.currency ?? Currency.iqd;
    final c = courier;
    String m(int v) => money(context, v, currency, digits);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.bgSurface,
        border: Border.all(color: p.borderHairline, width: Strokes.hairline),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    Bidi.auto(c.name),
                    style: type.bodyStrong.copyWith(color: p.textPrimary),
                  ),
                ),
                if (!c.active)
                  StatusBadge(
                    label: l10n.courierInactive,
                    icon: AppIcons.prohibit,
                  ),
              ],
            ),
            if (c.phone != null)
              Text(
                PhoneNumbers.display(c.phone!),
                style: type.caption.copyWith(color: p.textSecondary),
              ),
            const SizedBox(height: Space.s8),
            if (Features.deliveryTracking)
              Text(
                c.owed > 0
                    ? l10n.courierOwes(
                        m(c.owed),
                        Digits.display('${c.owedOrders}', digits),
                      )
                    : l10n.courierOwesNothing,
                style: type.body.copyWith(
                  color: c.owed > 0 ? p.warningFg : p.textSecondary,
                ),
              ),
            if (Features.deliveryTracking && c.carryingOrders > 0)
              Text(
                l10n.courierCarrying(
                  m(c.carrying),
                  Digits.display('${c.carryingOrders}', digits),
                ),
                style: type.caption.copyWith(color: p.textSecondary),
              ),
            const SizedBox(height: Space.s8),
            Wrap(
              spacing: Space.s8,
              children: [
                if (Features.deliveryTracking && c.owed > 0)
                  AppButton(
                    label: l10n.settleCourier,
                    icon: AppIcons.money,
                    onPressed: () => showSettleSheet(context, c, currency),
                  ),
                AppButton(
                  label: l10n.edit,
                  icon: AppIcons.pencilSimple,
                  variant: AppButtonVariant.tertiary,
                  onPressed: () => showCourierSheet(context, courier: c),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Adds a courier, or edits one ([courier]) including deactivating it.
Future<void> showCourierSheet(BuildContext context, {Courier? courier}) =>
    showAppSheet<void>(
      context: context,
      title: courier == null
          ? context.l10n.addCourier
          : context.l10n.editCourier,
      builder: (_) => _CourierForm(courier: courier),
    );

class _CourierForm extends ConsumerStatefulWidget {
  const _CourierForm({this.courier});

  final Courier? courier;

  @override
  ConsumerState<_CourierForm> createState() => _CourierFormState();
}

class _CourierFormState extends ConsumerState<_CourierForm> {
  late final _name = TextEditingController(text: widget.courier?.name ?? '');
  late final _phone = TextEditingController(
    text: widget.courier?.phone == null
        ? ''
        : PhoneNumbers.display(widget.courier!.phone!),
  );
  final _intent = IntentKey();
  bool _saving = false;
  String? _nameError;
  String? _phoneError;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save({bool? active}) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final name = _name.text.trim();
    final rawPhone = _phone.text.trim();
    final phone = rawPhone.isEmpty
        ? null
        : PhoneNumbers.normalizeIraqMobile(rawPhone);
    setState(() {
      _nameError = name.isEmpty || name.length > 60
          ? l10n.errCourierNameRequired
          : null;
      _phoneError = rawPhone.isNotEmpty && phone == null
          ? l10n.errPhoneInvalid('0750 123 4567')
          : null;
    });
    if (_nameError != null || _phoneError != null) return;
    final isActive = active ?? widget.courier?.active ?? true;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(fulfilmentActionsProvider)
          .saveCourier(
            existing: widget.courier,
            name: name,
            phone: phone,
            active: isActive,
            idempotencyKey: _intent.forPayload('$name|$phone|$isActive'),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnackOn(messenger, l10n.courierSaved);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = fulfilmentErrorText(l10n, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = widget.courier;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          FormErrorBanner(message: _error!),
          const SizedBox(height: Space.s12),
        ],
        AppTextField(
          key: const ValueKey('courier-name'),
          label: l10n.fieldCourierName,
          controller: _name,
          error: _nameError,
          enabled: !_saving,
        ),
        const SizedBox(height: Space.s12),
        AppTextField(
          key: const ValueKey('courier-phone'),
          label: l10n.fieldCourierPhoneOptional,
          controller: _phone,
          error: _phoneError,
          ltr: true,
          keyboardType: TextInputType.phone,
          enabled: !_saving,
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.save,
          loading: _saving,
          expand: true,
          onPressed: _saving ? null : _save,
        ),
        if (c != null) ...[
          const SizedBox(height: Space.s8),
          AppButton(
            label: c.active ? l10n.deactivateCourier : l10n.reactivateCourier,
            variant: AppButtonVariant.tertiary,
            expand: true,
            onPressed: _saving ? null : () => _save(active: !c.active),
          ),
        ],
      ],
    );
  }
}

/// Records cash a courier handed over; the server applies it to the
/// courier's oldest delivered orders and never above what is owed.
Future<void> showSettleSheet(
  BuildContext context,
  Courier courier,
  Currency currency,
) => showAppSheet<void>(
  context: context,
  title: context.l10n.settleTitle(courier.name),
  builder: (_) => _SettleForm(courier: courier, currency: currency),
);

class _SettleForm extends ConsumerStatefulWidget {
  const _SettleForm({required this.courier, required this.currency});

  final Courier courier;
  final Currency currency;

  @override
  ConsumerState<_SettleForm> createState() => _SettleFormState();
}

class _SettleFormState extends ConsumerState<_SettleForm> {
  final _amount = TextEditingController();
  final _intent = IntentKey();
  bool _saving = false;
  String? _amountError;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final amount = int.tryParse(
      Digits.normalize(_amount.text).replaceAll(RegExp(r'[\s,]'), ''),
    );
    if (amount == null || amount <= 0) {
      setState(() => _amountError = l10n.errAmountInvalid);
      return;
    }
    if (amount > widget.courier.owed) {
      setState(() => _amountError = l10n.errAmountExceeds);
      return;
    }
    setState(() {
      _saving = true;
      _amountError = null;
      _error = null;
    });
    try {
      final s = await ref
          .read(fulfilmentActionsProvider)
          .settle(
            widget.courier,
            amount: amount,
            idempotencyKey: _intent.forPayload('${widget.courier.id}|$amount'),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnackOn(messenger, l10n.settledSnack(s.allocations.length));
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = fulfilmentErrorText(l10n, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final digits = ref.watch(settingsProvider).digits;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.settleBody,
          style: context.type.label.copyWith(
            color: context.palette.textSecondary,
          ),
        ),
        const SizedBox(height: Space.s8),
        Text(
          l10n.courierOwes(
            money(context, widget.courier.owed, widget.currency, digits),
            Digits.display('${widget.courier.owedOrders}', digits),
          ),
          style: context.type.body,
        ),
        const SizedBox(height: Space.s12),
        if (_error != null) ...[
          FormErrorBanner(message: _error!),
          const SizedBox(height: Space.s12),
        ],
        AppTextField(
          key: const ValueKey('settle-amount'),
          label: l10n.fieldAmount,
          controller: _amount,
          error: _amountError,
          ltr: true,
          keyboardType: TextInputType.number,
          enabled: !_saving,
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.settleCourier,
          loading: _saving,
          expand: true,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}
