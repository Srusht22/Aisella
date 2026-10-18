import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
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
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../common/courier_picker.dart';
import '../../store/application/workspace_controller.dart';
import '../application/order_providers.dart';
import '../domain/order.dart';
import 'order_text.dart';

/// Time after presentation during which Confirm ignores taps, so a double
/// tap on Approve cannot pass through (Phase 2 §5.5, OR-03).
const kApproveInputGuard = Duration(milliseconds: 400);

// ---------------------------------------------------------------------------
// Shared sheet behaviour: one idempotency key per intent, P-LOAD-ACTION
// (inputs read-only, dismissal blocked), P-ERR-ACTION inside the sheet, and
// a refreshed order when the server says it changed meanwhile.
// ---------------------------------------------------------------------------

abstract class _ActionSheetState<T extends ConsumerStatefulWidget>
    extends ConsumerState<T> {
  final intent = IntentKey();
  bool busy = false;
  String? error;

  Order get order;

  /// Runs [action] with the key for [payload]; on success closes the sheet
  /// and shows [done] (when not null).
  Future<void> submit(
    Object payload,
    Future<String?> Function(String key) action,
  ) async {
    if (busy) return;
    final l10n = context.l10n;
    final digits = ref.read(settingsProvider).digits;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final done = await action(intent.forPayload(payload));
      intent.reset();
      if (!mounted) return;
      navigator.pop(true);
      if (done != null) showSnackOn(messenger, done);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ApiErrorCode.conflictVersion ||
          e.code == ApiErrorCode.invalidTransition ||
          e.code == ApiErrorCode.notFound) {
        ref.invalidate(orderProvider(order.id));
      }
      setState(() {
        busy = false;
        error = orderErrorText(l10n, e, digits: digits);
      });
    }
  }

  Widget errorBanner() => error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: Space.s12),
          child: AppBanner(
            tone: Tone.danger,
            icon: AppIcons.warningCircle,
            title: error!,
          ),
        );
}

Future<bool?> _sheet(BuildContext context, String title, Widget body) =>
    showAppSheet<bool>(context: context, title: title, builder: (_) => body);

/// Reason chips (single select) plus a note, required for "Other".
class _ReasonPicker extends StatelessWidget {
  const _ReasonPicker({
    required this.reasons,
    required this.selected,
    required this.onSelected,
    required this.note,
    required this.enabled,
    this.noteError,
  });

  final List<String> reasons;
  final String? selected;
  final ValueChanged<String> onSelected;
  final TextEditingController note;
  final bool enabled;
  final String? noteError;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s8,
          children: [
            for (final r in reasons)
              ChoiceChip(
                label: Text(reasonText(l10n, r)),
                selected: selected == r,
                showCheckmark: false,
                onSelected: enabled ? (_) => onSelected(r) : null,
              ),
          ],
        ),
        const SizedBox(height: Space.s12),
        AppTextField(
          label: selected == 'other'
              ? l10n.fieldNoteRequired
              : l10n.fieldNoteOptional,
          controller: note,
          maxLines: 3,
          enabled: enabled,
          error: noteError,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// OR-03 Approve (the explicit seller decision).
// ---------------------------------------------------------------------------

Future<void> showApproveSheet(BuildContext context, Order order) async {
  await _sheet(
    context,
    context.l10n.approveSheetTitle(orderNumber(order.number)),
    _ApproveSheet(order: order),
  );
}

class _ApproveSheet extends ConsumerStatefulWidget {
  const _ApproveSheet({required this.order});
  final Order order;

  @override
  ConsumerState<_ApproveSheet> createState() => _ApproveSheetState();
}

class _ApproveSheetState extends _ActionSheetState<_ApproveSheet> {
  bool _armed = false;
  Timer? _guard;

  /// itemId → 'quoted' | 'current'; no default (BR-23: an explicit choice).
  final _choices = <String, String>{};

  @override
  Order get order => widget.order;

  int get _choiceDelta => order.priceChanges
      .where((l) => _choices[l.id] == 'current')
      .fold(
        0,
        (d, l) => d + (l.current!.price - l.quotedUnitPrice!) * l.quantity,
      );

  @override
  void initState() {
    super.initState();
    _guard = Timer(kApproveInputGuard, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  @override
  void dispose() {
    _guard?.cancel();
    super.dispose();
  }

  Future<void> _approve() => submit(
    '${order.id}:${order.version}:${_choices.entries.map((e) => '${e.key}=${e.value}').join(',')}',
    (key) async {
      final l10n = context.l10n;
      final digits = ref.read(settingsProvider).digits;
      final outcome = await ref
          .read(orderActionsProvider)
          .approve(order, priceChoices: Map.of(_choices), idempotencyKey: key);
      if (outcome.alreadyApproved) return l10n.alreadyApproved;
      return outcome.stock.isEmpty
          ? l10n.orderApproved
          : l10n.orderApprovedStock(
              outcome.stock
                  .map(
                    (s) =>
                        '${itemName(s.name, s.label)} ${Bidi.ltr('${Digits.display('${s.before}', digits)} → ${Digits.display('${s.after}', digits)}')}',
                  )
                  .join(', '),
            );
    },
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    String m(int v) => money(context, v, order.currency, digits);
    final changes = order.priceChanges;
    final allChosen = changes.every((l) => _choices.containsKey(l.id));
    final tracked = [
      for (final l in order.lines)
        if (l.current?.trackStock ?? false) l,
    ];

    return PopScope(
      canPop: !busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            [
              Bidi.auto(order.customerName ?? ''),
              if (order.customerPhone != null)
                PhoneNumbers.display(order.customerPhone!),
            ].join(' · '),
            style: type.body.copyWith(color: p.textPrimary),
          ),
          Text(
            [
              if (order.place != null) Bidi.auto(order.place!),
              if (order.area != null) Bidi.auto(order.area!),
            ].join(' · '),
            style: type.label.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: Space.s12),
          for (final l in order.lines)
            Text(
              '${count(l.quantity, digits)} × ${itemName(l.name, l.variantLabel)}',
              style: type.body.copyWith(color: p.textPrimary),
            ),
          if (changes.isNotEmpty) ...[
            const SizedBox(height: Space.s12),
            AppBanner(
              tone: Tone.warning,
              icon: AppIcons.warning,
              title: l10n.pricesChangedTitle,
              body: l10n.pricesChangedBody,
            ),
            for (final l in changes) ...[
              const SizedBox(height: Space.s8),
              Text(
                itemName(l.name, l.variantLabel),
                style: type.label.copyWith(color: p.textSecondary),
              ),
              const SizedBox(height: Space.s4),
              AppSegmented<String>(
                options: [
                  ('quoted', l10n.priceQuoted(m(l.quotedUnitPrice!))),
                  ('current', l10n.priceCurrent(m(l.current!.price))),
                ],
                selected: _choices[l.id] ?? '',
                onChanged: busy
                    ? (_) {}
                    : (v) => setState(() => _choices[l.id] = v),
              ),
            ],
          ],
          if (tracked.isNotEmpty) ...[
            const SizedBox(height: Space.s12),
            Text(
              l10n.stockAfterApproval,
              style: type.label.copyWith(color: p.textSecondary),
            ),
            for (final l in tracked)
              Text(
                '${itemName(l.name, l.variantLabel)}: ${Bidi.ltr('${Digits.display('${l.current!.stockOnHand}', digits)} → ${Digits.display('${l.current!.stockOnHand - l.quantity}', digits)}')}',
                style: type.numericBody.copyWith(color: p.textPrimary),
              ),
          ],
          const SizedBox(height: Space.s12),
          Row(
            children: [
              Expanded(
                child: Text(
                  order.paymentMethod == PaymentMethod.cod
                      ? l10n.totalCashOnDelivery
                      : l10n.total,
                  style: type.bodyStrong.copyWith(color: p.textPrimary),
                ),
              ),
              Text(
                // The total for the chosen prices (the server recomputes it).
                allChosen ? m(order.total + _choiceDelta) : '—',
                style: type.numericTotal.copyWith(color: p.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: Space.s12),
          Text(
            l10n.approveStatement,
            style: type.label.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: Space.s16),
          errorBanner(),
          AppButton(
            label: l10n.confirmApproval,
            loading: busy,
            loadingLabel: l10n.approving,
            expand: true,
            onPressed: _armed && allChosen ? _approve : null,
          ),
          const SizedBox(height: Space.s8),
          AppButton(
            label: l10n.back,
            variant: AppButtonVariant.tertiary,
            expand: true,
            onPressed: busy ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OR-04 Reject draft and OR-09 Cancel order.
// ---------------------------------------------------------------------------

Future<void> showRejectSheet(BuildContext context, Order order) => _sheet(
  context,
  context.l10n.rejectTitle(orderNumber(order.number)),
  _ReasonSheet(order: order, cancel: false),
);

Future<void> showCancelSheet(BuildContext context, Order order) => _sheet(
  context,
  context.l10n.cancelTitle(orderNumber(order.number)),
  _ReasonSheet(order: order, cancel: true),
);

class _ReasonSheet extends ConsumerStatefulWidget {
  const _ReasonSheet({required this.order, required this.cancel});
  final Order order;
  final bool cancel;

  @override
  ConsumerState<_ReasonSheet> createState() => _ReasonSheetState();
}

class _ReasonSheetState extends _ActionSheetState<_ReasonSheet> {
  final _note = TextEditingController();
  String? _reason;
  bool _tried = false;

  @override
  Order get order => widget.order;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _noteMissing => _reason == 'other' && _note.text.trim().isEmpty;

  Future<void> _submit() {
    setState(() => _tried = true);
    if (_reason == null || _noteMissing) return Future.value();
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    final actions = ref.read(orderActionsProvider);
    final l10n = context.l10n;
    return submit('${order.id}:${order.version}:$_reason:$note', (key) async {
      if (widget.cancel) {
        await actions.cancel(
          order,
          reason: _reason!,
          note: note,
          idempotencyKey: key,
        );
        return l10n.orderCancelled;
      }
      await actions.reject(
        order,
        reason: _reason!,
        note: note,
        idempotencyKey: key,
      );
      return l10n.draftRejected;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final restock = [
      for (final l in order.lines)
        if (l.stockDeducted > 0) l,
    ];
    return PopScope(
      canPop: !busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.cancel
                ? (restock.isEmpty
                      ? l10n.cancelNoStockBody
                      : l10n.cancelRestockBody(
                          restock
                              .map(
                                (l) =>
                                    '${count(l.stockDeducted, digits)} × ${itemName(l.name, l.variantLabel)}',
                              )
                              .join(', '),
                        ))
                : l10n.rejectBody,
            style: type.body.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: Space.s16),
          if (_tried && _reason == null)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s8),
              child: Text(
                l10n.errReasonRequired,
                style: type.caption.copyWith(color: p.dangerFg),
              ),
            ),
          _ReasonPicker(
            reasons: widget.cancel ? cancelReasons : rejectReasons,
            selected: _reason,
            onSelected: (r) => setState(() => _reason = r),
            note: _note,
            enabled: !busy,
            noteError: _tried && _noteMissing ? l10n.errNoteRequired : null,
          ),
          const SizedBox(height: Space.s16),
          errorBanner(),
          AppButton(
            label: widget.cancel ? l10n.cancelOrder : l10n.rejectDraft,
            variant: AppButtonVariant.danger,
            loading: busy,
            expand: true,
            onPressed: _submit,
          ),
          const SizedBox(height: Space.s8),
          AppButton(
            label: widget.cancel ? l10n.keepOrder : l10n.back,
            variant: AppButtonVariant.tertiary,
            expand: true,
            onPressed: busy ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OR-08 Status updates.
// ---------------------------------------------------------------------------

Future<void> showDispatchSheet(BuildContext context, Order order) => _sheet(
  context,
  context.l10n.markOutForDelivery,
  _DispatchSheet(order: order),
);

class _DispatchSheet extends ConsumerStatefulWidget {
  const _DispatchSheet({required this.order});
  final Order order;

  @override
  ConsumerState<_DispatchSheet> createState() => _DispatchSheetState();
}

class _DispatchSheetState extends _ActionSheetState<_DispatchSheet> {
  late final _courier = TextEditingController(text: order.courierNote ?? '');
  late String? _courierId = order.courierId;

  @override
  Order get order => widget.order;

  @override
  void dispose() {
    _courier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final courier = _courier.text.trim();
    return PopScope(
      canPop: !busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.dispatchCheck,
            style: type.label.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: Space.s4),
          Text(
            [
              Bidi.auto(order.customerName ?? ''),
              if (order.customerPhone != null)
                PhoneNumbers.display(order.customerPhone!),
            ].join(' · '),
            style: type.body.copyWith(color: p.textPrimary),
          ),
          Text(
            [
              if (order.place != null) Bidi.auto(order.place!),
              if (order.area != null) Bidi.auto(order.area!),
              if (order.landmark != null) Bidi.auto(order.landmark!),
            ].join(' · '),
            style: type.body.copyWith(color: p.textPrimary),
          ),
          const SizedBox(height: Space.s16),
          // Phase 10: one of the store's couriers (optional), plus a note.
          CourierPicker(
            selected: _courierId,
            onChanged: busy ? null : (id) => setState(() => _courierId = id),
          ),
          const SizedBox(height: Space.s12),
          AppTextField(
            label: l10n.fieldCourierOptional,
            controller: _courier,
            enabled: !busy,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Space.s16),
          errorBanner(),
          AppButton(
            label: l10n.markOutForDelivery,
            loading: busy,
            expand: true,
            onPressed: () => submit(
              '${order.id}:${order.version}:dispatch:$courier:$_courierId',
              (key) async {
                await ref
                    .read(orderActionsProvider)
                    .transition(
                      order,
                      OrderStatus.dispatched,
                      payload: {
                        if (courier.isNotEmpty) 'courier_note': courier,
                        'courier_id': ?_courierId,
                      },
                      idempotencyKey: key,
                    );
                return l10n.markedOutForDelivery;
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showDeliveredSheet(BuildContext context, Order order) =>
    _sheet(context, context.l10n.markDelivered, _DeliveredSheet(order: order));

enum _Cash { all, none, part }

class _DeliveredSheet extends ConsumerStatefulWidget {
  const _DeliveredSheet({required this.order});
  final Order order;

  @override
  ConsumerState<_DeliveredSheet> createState() => _DeliveredSheetState();
}

class _DeliveredSheetState extends _ActionSheetState<_DeliveredSheet> {
  _Cash? _cash;
  final _amount = TextEditingController();
  bool _tried = false;

  @override
  Order get order => widget.order;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  bool get _cod =>
      order.paymentMethod == PaymentMethod.cod && order.codOutstanding > 0;

  int? get _collected => switch (_cash) {
    _Cash.all => order.codOutstanding,
    _Cash.none => 0,
    _Cash.part => parseAmount(_amount.text),
    null => null,
  };

  String? get _amountError {
    if (_cash != _Cash.part || !_tried) return null;
    final v = _collected;
    if (v == null || v <= 0) return context.l10n.errAmountInvalid;
    if (v > order.codOutstanding) return context.l10n.errCashTooHigh;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final digits = ref.watch(settingsProvider).digits;
    String m(int v) => money(context, v, order.currency, digits);
    return PopScope(
      canPop: !busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_cod) ...[
            Text(
              l10n.cashCollectedQuestion(m(order.codOutstanding)),
              style: context.type.body.copyWith(
                color: context.palette.textPrimary,
              ),
            ),
            const SizedBox(height: Space.s8),
            AppSegmented<_Cash?>(
              options: [
                (_Cash.all, l10n.cashYesAll),
                (_Cash.none, l10n.cashNotYet),
                (_Cash.part, l10n.cashPartly),
              ],
              selected: _cash,
              onChanged: busy ? (_) {} : (v) => setState(() => _cash = v),
            ),
            if (_cash == _Cash.part) ...[
              const SizedBox(height: Space.s12),
              AppTextField(
                label: l10n.fieldAmountCollected,
                controller: _amount,
                ltr: true,
                keyboardType: TextInputType.number,
                enabled: !busy,
                error: _amountError,
              ),
            ],
            const SizedBox(height: Space.s16),
          ],
          errorBanner(),
          AppButton(
            label: l10n.markDelivered,
            loading: busy,
            expand: true,
            onPressed: () {
              setState(() => _tried = true);
              if (_cod && (_cash == null || _amountError != null)) return;
              final collected = _cod ? _collected! : 0;
              submit('${order.id}:${order.version}:delivered:$collected', (
                key,
              ) async {
                await ref
                    .read(orderActionsProvider)
                    .transition(
                      order,
                      OrderStatus.delivered,
                      payload: {if (collected > 0) 'cod_collected': collected},
                      idempotencyKey: key,
                    );
                return l10n.markedDelivered;
              });
            },
          ),
        ],
      ),
    );
  }
}

Future<void> showFailedSheet(BuildContext context, Order order) => _sheet(
  context,
  context.l10n.deliveryFailedAction,
  _FailedSheet(order: order),
);

class _FailedSheet extends ConsumerStatefulWidget {
  const _FailedSheet({required this.order});
  final Order order;

  @override
  ConsumerState<_FailedSheet> createState() => _FailedSheetState();
}

class _FailedSheetState extends _ActionSheetState<_FailedSheet> {
  final _note = TextEditingController();
  String? _reason;
  bool _tried = false;

  @override
  Order get order => widget.order;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final noteMissing = _reason == 'other' && _note.text.trim().isEmpty;
    return PopScope(
      canPop: !busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_tried && _reason == null)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s8),
              child: Text(
                l10n.errReasonRequired,
                style: context.type.caption.copyWith(
                  color: context.palette.dangerFg,
                ),
              ),
            ),
          _ReasonPicker(
            reasons: deliveryFailureReasons,
            selected: _reason,
            onSelected: (r) => setState(() => _reason = r),
            note: _note,
            enabled: !busy,
            noteError: _tried && noteMissing ? l10n.errNoteRequired : null,
          ),
          const SizedBox(height: Space.s16),
          errorBanner(),
          AppButton(
            label: l10n.markDeliveryFailed,
            variant: AppButtonVariant.secondary,
            loading: busy,
            expand: true,
            onPressed: () {
              setState(() => _tried = true);
              if (_reason == null || noteMissing) return;
              final note = _note.text.trim();
              submit('${order.id}:${order.version}:failed:$_reason:$note', (
                key,
              ) async {
                await ref
                    .read(orderActionsProvider)
                    .transition(
                      order,
                      OrderStatus.deliveryFailed,
                      payload: {
                        'reason': _reason,
                        if (note.isNotEmpty) 'note': note,
                      },
                      idempotencyKey: key,
                    );
                return l10n.markedDeliveryFailed;
              });
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OR-08 Mark returned: a decision per line, no default.
// ---------------------------------------------------------------------------

Future<void> showReturnSheet(BuildContext context, Order order) =>
    _sheet(context, context.l10n.markReturned, _ReturnSheet(order: order));

class _ReturnSheet extends ConsumerStatefulWidget {
  const _ReturnSheet({required this.order});
  final Order order;

  @override
  ConsumerState<_ReturnSheet> createState() => _ReturnSheetState();
}

class _ReturnSheetState extends _ActionSheetState<_ReturnSheet> {
  /// itemId → true (restock) / false (write off).
  final _restock = <String, bool>{};

  @override
  Order get order => widget.order;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final decided = order.lines.every((l) => _restock.containsKey(l.id));
    final back = order.lines
        .where((l) => _restock[l.id] ?? false)
        .fold(0, (n, l) => n + l.quantity);
    final off = order.lines
        .where((l) => _restock[l.id] == false)
        .fold(0, (n, l) => n + l.quantity);
    return PopScope(
      canPop: !busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.returnBody,
            style: type.body.copyWith(color: p.textSecondary),
          ),
          for (final l in order.lines) ...[
            const SizedBox(height: Space.s12),
            Text(
              '${count(l.quantity, digits)} × ${itemName(l.name, l.variantLabel)}',
              style: type.bodyStrong.copyWith(color: p.textPrimary),
            ),
            const SizedBox(height: Space.s4),
            AppSegmented<bool?>(
              options: [(true, l10n.restock), (false, l10n.writeOff)],
              selected: _restock[l.id],
              onChanged: busy
                  ? (_) {}
                  : (v) => setState(() => _restock[l.id] = v!),
            ),
          ],
          const SizedBox(height: Space.s12),
          Text(
            l10n.returnSummary(count(back, digits), count(off, digits)),
            style: type.label.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: Space.s16),
          errorBanner(),
          AppButton(
            label: l10n.markReturned,
            loading: busy,
            expand: true,
            onPressed: decided
                ? () => submit(
                    '${order.id}:${order.version}:return:$_restock',
                    (key) async {
                      await ref
                          .read(orderActionsProvider)
                          .recordReturn(
                            order,
                            lines: {
                              for (final l in order.lines)
                                l.id: _restock[l.id]!
                                    ? (restock: l.quantity, writeOff: 0)
                                    : (restock: 0, writeOff: l.quantity),
                            },
                            idempotencyKey: key,
                          );
                      return l10n.markedReturned;
                    },
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OR-08 Record cash.
// ---------------------------------------------------------------------------

/// Parses an amount typed with Western or Eastern digits and separators.
int? parseAmount(String text) =>
    int.tryParse(Digits.normalize(text).replaceAll(RegExp(r'[\s,٬.]'), ''));

Future<void> showCashSheet(BuildContext context, Order order) =>
    _sheet(context, context.l10n.recordCash, _CashSheet(order: order));

class _CashSheet extends ConsumerStatefulWidget {
  const _CashSheet({required this.order});
  final Order order;

  @override
  ConsumerState<_CashSheet> createState() => _CashSheetState();
}

class _CashSheetState extends _ActionSheetState<_CashSheet> {
  late final _amount = TextEditingController(
    text: '${widget.order.codOutstanding}',
  );
  bool _tried = false;

  @override
  Order get order => widget.order;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final digits = ref.watch(settingsProvider).digits;
    final v = parseAmount(_amount.text);
    final invalid = v == null || v <= 0 || v > order.codOutstanding;
    return PopScope(
      canPop: !busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTextField(
            label: l10n.fieldAmountCollected,
            helper: l10n.cashOutstandingIs(
              money(context, order.codOutstanding, order.currency, digits),
            ),
            controller: _amount,
            ltr: true,
            keyboardType: TextInputType.number,
            enabled: !busy,
            error: _tried && invalid
                ? (v != null && v > order.codOutstanding
                      ? l10n.errCashTooHigh
                      : l10n.errAmountInvalid)
                : null,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Space.s16),
          errorBanner(),
          AppButton(
            label: l10n.recordCash,
            loading: busy,
            expand: true,
            onPressed: () {
              setState(() => _tried = true);
              if (invalid) return;
              submit('${order.id}:${order.version}:cash:$v', (key) async {
                await ref
                    .read(orderActionsProvider)
                    .recordCash(order, amount: v, idempotencyKey: key);
                return l10n.cashRecorded;
              });
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OR-10 Confirmation message: the seller copies it and sends it themselves.
// Aisellia never sends it and never calls it "Sent" (BR-46, BR-47).
// ---------------------------------------------------------------------------

/// The confirmation text in the store's customer-reply language.
String confirmationText(
  AppLocalizations l,
  Order order, {
  required DigitStyle digits,
  required Locale locale,
}) {
  String m(int v) =>
      Money.format(v, order.currency, locale: locale, digits: digits);
  final items = order.lines
      .map(
        (x) =>
            '• ${Digits.display('${x.quantity}', digits)} × ${itemName(x.name, x.variantLabel)} — ${m(x.lineTotal)}',
      )
      .join('\n');
  return [
    l.confirmationGreeting(Bidi.auto(order.customerName ?? '')),
    l.confirmationLine(orderNumber(order.number)),
    items,
    if (order.deliveryFee != null) '${l.deliveryFee}: ${m(order.deliveryFee!)}',
    if (order.discount > 0) '${l.discount}: − ${m(order.discount)}',
    '${l.total}: ${m(order.total)}',
    if (order.paymentMethod == PaymentMethod.cod)
      l.confirmationCod(m(order.codDue)),
    l.confirmationThanks,
  ].join('\n');
}

Future<void> showConfirmationSheet(BuildContext context, Order order) => _sheet(
  context,
  context.l10n.confirmationTitle,
  _ConfirmationSheet(order: order),
);

class _ConfirmationSheet extends ConsumerStatefulWidget {
  const _ConfirmationSheet({required this.order});
  final Order order;

  @override
  ConsumerState<_ConfirmationSheet> createState() => _ConfirmationSheetState();
}

class _ConfirmationSheetState extends _ActionSheetState<_ConfirmationSheet> {
  late final TextEditingController _text;
  bool _copied = false;

  @override
  Order get order => widget.order;

  @override
  void initState() {
    super.initState();
    final reply =
        ref.read(workspaceProvider).value?.store?.replyLocale ?? 'ckb';
    final locale = Locale(reply);
    _text = TextEditingController(
      text: confirmationText(
        lookupAppLocalizations(locale),
        order,
        digits: ref.read(settingsProvider).digits,
        locale: locale,
      ),
    );
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final marked = order.confirmationMarkedSentAt != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTextField(
          label: l10n.confirmationMessage,
          controller: _text,
          maxLines: 10,
        ),
        const SizedBox(height: Space.s8),
        Text(
          l10n.confirmationNotSentNote,
          style: context.type.caption.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: Space.s16),
        errorBanner(),
        AppButton(
          label: _copied ? l10n.copiedNotSent : l10n.copyMessage,
          icon: _copied ? AppIcons.check : AppIcons.copy,
          variant: _copied
              ? AppButtonVariant.secondary
              : AppButtonVariant.primary,
          expand: true,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _text.text));
            if (mounted) setState(() => _copied = true);
          },
        ),
        if (_copied && !marked) ...[
          const SizedBox(height: Space.s8),
          AppButton(
            label: l10n.iSentThis,
            variant: AppButtonVariant.tertiary,
            loading: busy,
            expand: true,
            onPressed: () => submit('${order.id}:marked', (key) async {
              await ref.read(orderActionsProvider).markConfirmationSent(order);
              return l10n.markedSentByYou;
            }),
          ),
        ],
        if (marked) ...[
          const SizedBox(height: Space.s8),
          Text(
            l10n.markedSentByYou,
            textAlign: TextAlign.center,
            style: context.type.caption.copyWith(color: p.textSecondary),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Internal note (editable in every status, BR-33).
// ---------------------------------------------------------------------------

Future<void> showNoteSheet(BuildContext context, Order order) =>
    _sheet(context, context.l10n.internalNote, _NoteSheet(order: order));

class _NoteSheet extends ConsumerStatefulWidget {
  const _NoteSheet({required this.order});
  final Order order;

  @override
  ConsumerState<_NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends _ActionSheetState<_NoteSheet> {
  late final _note = TextEditingController(text: order.internalNote ?? '');

  @override
  Order get order => widget.order;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopScope(
      canPop: !busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTextField(
            label: l10n.internalNote,
            helper: l10n.internalNoteHelper,
            controller: _note,
            maxLines: 4,
            enabled: !busy,
          ),
          const SizedBox(height: Space.s16),
          errorBanner(),
          AppButton(
            label: l10n.save,
            loading: busy,
            expand: true,
            onPressed: () =>
                submit('${order.id}:note:${_note.text}', (_) async {
                  await ref
                      .read(orderActionsProvider)
                      .updateNote(order, _note.text);
                  return l10n.changesSaved;
                }),
          ),
        ],
      ),
    );
  }
}
