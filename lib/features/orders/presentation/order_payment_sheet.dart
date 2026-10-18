import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/form_widgets.dart';
import '../../common/fulfilment_labels.dart';
import '../../common/order_labels.dart';
import '../../fulfilment/application/fulfilment_providers.dart';
import '../../fulfilment/domain/fulfilment.dart';
import '../domain/order.dart';

/// Transfers and wallets are recorded on orders paid "other", while the
/// order is approved and not closed, until it is fully paid (Phase 10).
bool canRecordPayment(Order o) =>
    o.paymentMethod == PaymentMethod.other &&
    !o.isTest &&
    o.paidTotal < o.total &&
    const {
      OrderStatus.approved,
      OrderStatus.processing,
      OrderStatus.dispatched,
      OrderStatus.delivered,
      OrderStatus.deliveryFailed,
    }.contains(o.status);

Future<void> showRecordPaymentSheet(BuildContext context, Order order) =>
    showAppSheet<void>(
      context: context,
      title: context.l10n.recordPayment,
      builder: (_) => _RecordPaymentForm(order: order),
    );

class _RecordPaymentForm extends ConsumerStatefulWidget {
  const _RecordPaymentForm({required this.order});

  final Order order;

  @override
  ConsumerState<_RecordPaymentForm> createState() => _RecordPaymentFormState();
}

class _RecordPaymentFormState extends ConsumerState<_RecordPaymentForm> {
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _intent = IntentKey();
  PaymentChannel _method = PaymentChannel.fib;
  bool _saving = false;
  String? _amountError;
  String? _error;

  int get _left => widget.order.total - widget.order.paidTotal;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final amount = int.tryParse(
      Digits.normalize(_amount.text).replaceAll(RegExp(r'[\s,]'), ''),
    );
    if (amount == null || amount <= 0) {
      setState(() => _amountError = l10n.errAmountInvalid);
      return;
    }
    if (amount > _left) {
      setState(() => _amountError = l10n.errAmountExceeds);
      return;
    }
    final reference = _reference.text.trim();
    if (reference.length > 60) {
      setState(() => _error = l10n.errTooLongMax('60'));
      return;
    }
    setState(() {
      _saving = true;
      _amountError = null;
      _error = null;
    });
    try {
      await ref
          .read(fulfilmentActionsProvider)
          .recordPayment(
            widget.order,
            method: _method,
            amount: amount,
            reference: reference.isEmpty ? null : reference,
            idempotencyKey: _intent.forPayload(
              '${widget.order.id}|${_method.wire}|$amount|$reference',
            ),
          );
      navigator.pop();
      showSnackOn(messenger, l10n.paymentRecorded);
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
          l10n.recordPaymentBody,
          style: context.type.label.copyWith(
            color: context.palette.textSecondary,
          ),
        ),
        const SizedBox(height: Space.s8),
        Text(
          '${l10n.leftToPay}: ${money(context, _left, widget.order.currency, digits)}',
          style: context.type.body,
        ),
        const SizedBox(height: Space.s12),
        if (_error != null) ...[
          FormErrorBanner(message: _error!),
          const SizedBox(height: Space.s12),
        ],
        Text(l10n.fieldPaymentChannel, style: context.type.label),
        const SizedBox(height: Space.s4),
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s4,
          children: [
            for (final c in PaymentChannel.values)
              ChoiceChip(
                label: Text(paymentChannelLabel(l10n, c)),
                selected: _method == c,
                showCheckmark: false,
                onSelected: _saving ? null : (_) => setState(() => _method = c),
              ),
          ],
        ),
        const SizedBox(height: Space.s12),
        AppTextField(
          key: const ValueKey('payment-amount'),
          label: l10n.fieldAmount,
          controller: _amount,
          error: _amountError,
          ltr: true,
          keyboardType: TextInputType.number,
          enabled: !_saving,
        ),
        const SizedBox(height: Space.s12),
        AppTextField(
          key: const ValueKey('payment-reference'),
          label: l10n.fieldReferenceOptional,
          controller: _reference,
          enabled: !_saving,
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.recordPayment,
          loading: _saving,
          expand: true,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}
