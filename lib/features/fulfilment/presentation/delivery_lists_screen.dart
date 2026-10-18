import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/formatting/money.dart';
import '../../../core/formatting/phone.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/courier_picker.dart';
import '../../common/form_widgets.dart';
import '../../common/fulfilment_labels.dart';
import '../../common/order_labels.dart';
import '../../store/application/workspace_controller.dart';
import '../application/fulfilment_providers.dart';
import '../domain/fulfilment.dart';

/// Delivery lists (Phase 10): the orders ready to leave, and lists grouped
/// per courier. A list is handed over in one step: every order on it is
/// marked out for delivery, or none is.
class DeliveryListsScreen extends ConsumerWidget {
  const DeliveryListsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final page = ref.watch(deliveryListsProvider);
    final digits = ref.watch(settingsProvider).digits;
    final Widget body = switch (page) {
      AsyncError(:final error) => ErrorState(
        cause: error is ApiException
            ? fulfilmentErrorText(l10n, error)
            : l10n.errorServer,
        onRetry: () => ref.invalidate(deliveryListsProvider),
      ),
      AsyncData(:final value) => ListView(
        children: [
          ContentWidth(
            maxWidth: LayoutTokens.maxWidthForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.s12),
                AppButton(
                  label: l10n.newDeliveryList,
                  icon: AppIcons.plus,
                  expand: true,
                  onPressed: value.ready.isEmpty
                      ? null
                      : () => showNewListSheet(context, value.ready),
                ),
                const SizedBox(height: Space.s4),
                Text(
                  value.ready.isEmpty
                      ? l10n.noReadyOrders
                      : l10n.readyOrdersCount(value.ready.length),
                  style: type.caption.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.deliveryListsTitle),
                if (value.lists.isEmpty)
                  Text(
                    l10n.noDeliveryLists,
                    style: type.body.copyWith(color: p.textTertiary),
                  )
                else
                  RowGroup(
                    children: [
                      for (final l in value.lists)
                        NavRow(
                          label: l10n.deliveryListTitle(
                            Bidi.ltr(Digits.display('${l.number}', digits)),
                          ),
                          icon: AppIcons.truck,
                          trailing: Text(
                            [
                              deliveryListStatusLabel(l10n, l.status),
                              if (l.courierName != null)
                                Bidi.auto(l.courierName!),
                              l10n.ordersCount(l.orderCount),
                            ].join(' · '),
                            style: type.caption.copyWith(
                              color: p.textSecondary,
                            ),
                          ),
                          onTap: () => context.push(Routes.deliveryList(l.id)),
                        ),
                    ],
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
      appBar: AppBar(title: Text(l10n.deliveryListsTitle)),
      body: body,
    );
  }
}

/// Chooses ready orders and (optionally) a courier for a new list.
Future<void> showNewListSheet(BuildContext context, List<ReadyOrder> ready) =>
    showAppSheet<void>(
      context: context,
      title: context.l10n.newDeliveryList,
      builder: (_) => _NewListForm(ready: ready),
    );

class _NewListForm extends ConsumerStatefulWidget {
  const _NewListForm({required this.ready});

  final List<ReadyOrder> ready;

  @override
  ConsumerState<_NewListForm> createState() => _NewListFormState();
}

class _NewListFormState extends ConsumerState<_NewListForm> {
  final _intent = IntentKey();
  final _selected = <String>{};
  String? _courierId;
  bool _saving = false;
  String? _error;

  Future<void> _create() async {
    final l10n = context.l10n;
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    final ids = [
      for (final o in widget.ready)
        if (_selected.contains(o.orderId)) o.orderId,
    ];
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final list = await ref
          .read(fulfilmentActionsProvider)
          .createList(
            courierId: _courierId,
            orderIds: ids,
            idempotencyKey: _intent.forPayload('$_courierId|${ids.join(',')}'),
          );
      if (!mounted) return;
      navigator.pop();
      unawaited(router.push(Routes.deliveryList(list.id)));
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
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          FormErrorBanner(message: _error!),
          const SizedBox(height: Space.s12),
        ],
        CourierPicker(
          selected: _courierId,
          onChanged: _saving ? null : (id) => setState(() => _courierId = id),
        ),
        const SizedBox(height: Space.s12),
        Text(l10n.chooseOrders, style: type.label),
        for (final o in widget.ready)
          CheckboxListTile(
            key: ValueKey('ready-${o.orderId}'),
            value: _selected.contains(o.orderId),
            onChanged: _saving
                ? null
                : (v) => setState(
                    () => v == true
                        ? _selected.add(o.orderId)
                        : _selected.remove(o.orderId),
                  ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: Text(
              [
                orderNumber(o.number),
                if (o.customerName != null) Bidi.auto(o.customerName!),
              ].join(' · '),
            ),
            subtitle: Text(
              [
                if (o.place != null && o.place!.isNotEmpty) Bidi.auto(o.place!),
                money(context, o.total, o.currency, digits),
                if (!o.complete) l10n.orderIncompleteShort,
              ].join(' · '),
              style: type.caption.copyWith(
                color: o.complete ? p.textSecondary : p.warningFg,
              ),
            ),
          ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.createList,
          loading: _saving,
          expand: true,
          onPressed: _saving || _selected.isEmpty ? null : _create,
        ),
      ],
    );
  }
}

/// One delivery list: its stops for the courier, copy as text, hand over.
class DeliveryListScreen extends ConsumerStatefulWidget {
  const DeliveryListScreen({super.key, required this.listId});

  final String listId;

  @override
  ConsumerState<DeliveryListScreen> createState() => _DeliveryListScreenState();
}

class _DeliveryListScreenState extends ConsumerState<DeliveryListScreen> {
  final _intent = IntentKey();
  bool _busy = false;

  Future<void> _run(
    DeliveryList list,
    String action, {
    String? courierId,
    List<String>? orderIds,
    String? done,
  }) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(fulfilmentActionsProvider)
          .updateList(
            list,
            action: action,
            courierId: courierId,
            orderIds: orderIds,
            idempotencyKey: _intent.forPayload(
              '${list.id}|${list.version}|$action|$courierId|${orderIds?.join(',')}',
            ),
          );
      if (done != null) showSnackOn(messenger, done);
    } on ApiException catch (e) {
      showSnackOn(messenger, fulfilmentErrorText(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handOver(DeliveryList list) async {
    final l10n = context.l10n;
    final digits = ref.read(settingsProvider).digits;
    final ok = await showConfirmDialog(
      context: context,
      title: l10n.handOverTitle(
        Bidi.ltr(Digits.display('${list.number}', digits)),
      ),
      body: l10n.handOverBody(
        list.stops.length,
        Bidi.auto(list.courierName ?? ''),
      ),
      confirmLabel: l10n.handOver,
      cancelLabel: l10n.cancel,
    );
    if (ok && mounted) {
      await _run(list, 'hand_over', done: l10n.handedOverSnack);
    }
  }

  Future<void> _cancel(DeliveryList list) async {
    final l10n = context.l10n;
    final ok = await showConfirmDialog(
      context: context,
      title: l10n.cancelListTitle,
      body: l10n.cancelListBody,
      confirmLabel: l10n.cancelList,
      cancelLabel: l10n.keepOrder,
      destructive: true,
    );
    if (ok && mounted) await _run(list, 'cancel');
  }

  Future<void> _changeCourier(DeliveryList list) async {
    final id = await showAppSheet<String>(
      context: context,
      title: context.l10n.changeCourier,
      builder: (ctx) => CourierPicker(
        selected: list.courierId,
        allowNone: false,
        onChanged: (id) => Navigator.of(ctx).pop(id),
      ),
    );
    if (id != null && mounted) {
      await _run(
        list,
        'set_orders',
        courierId: id,
        orderIds: [for (final s in list.stops) s.orderId],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final listAsync = ref.watch(deliveryListProvider(widget.listId));
    final list = listAsync.value;
    final currency =
        ref.watch(workspaceProvider).value?.store?.currency ?? Currency.iqd;
    String m(int v) => money(context, v, currency, digits);

    final Widget body = switch (listAsync) {
      AsyncError(:final error) => ErrorState(
        cause: error is ApiException
            ? fulfilmentErrorText(l10n, error)
            : l10n.errorServer,
        onRetry: () => ref.invalidate(deliveryListProvider(widget.listId)),
      ),
      AsyncData(:final value) => ListView(
        children: [
          ContentWidth(
            maxWidth: LayoutTokens.maxWidthForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.s12),
                Wrap(
                  spacing: Space.s8,
                  runSpacing: Space.s4,
                  children: [
                    StatusBadge(
                      label: deliveryListStatusLabel(l10n, value.status),
                      icon: AppIcons.truck,
                      tone: value.isOpen ? Tone.info : Tone.neutral,
                    ),
                    StatusBadge(
                      label: value.courierName == null
                          ? l10n.noCourierYet
                          : Bidi.auto(value.courierName!),
                      icon: AppIcons.userCircle,
                    ),
                  ],
                ),
                const SizedBox(height: Space.s8),
                Text(
                  '${l10n.ordersCount(value.stops.length)} · '
                  '${l10n.listCashTotal(m(value.codTotal))}',
                  style: type.body.copyWith(color: p.textPrimary),
                ),
                const SizedBox(height: Space.s16),
                for (final s in value.stops) ...[
                  _StopCard(
                    stop: s,
                    canRemove: value.isOpen && !_busy,
                    onRemove: () => _run(
                      value,
                      'set_orders',
                      courierId: value.courierId,
                      orderIds: [
                        for (final o in value.stops)
                          if (o.orderId != s.orderId) o.orderId,
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s8),
                ],
                const SizedBox(height: Space.s8),
                Wrap(
                  spacing: Space.s8,
                  runSpacing: Space.s8,
                  children: [
                    AppButton(
                      label: l10n.copyListText,
                      icon: AppIcons.copy,
                      variant: AppButtonVariant.secondary,
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await Clipboard.setData(
                          ClipboardData(
                            text: deliveryListText(l10n, value, m, digits),
                          ),
                        );
                        showSnackOn(messenger, l10n.listCopied);
                      },
                    ),
                    if (value.isOpen)
                      AppButton(
                        label: l10n.changeCourier,
                        icon: AppIcons.userCircle,
                        variant: AppButtonVariant.tertiary,
                        onPressed: _busy ? null : () => _changeCourier(value),
                      ),
                    if (value.isOpen)
                      AppButton(
                        label: l10n.cancelList,
                        variant: AppButtonVariant.tertiary,
                        onPressed: _busy ? null : () => _cancel(value),
                      ),
                  ],
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
      appBar: AppBar(
        title: Text(
          list == null
              ? ''
              : l10n.deliveryListTitle(
                  Bidi.ltr(Digits.display('${list.number}', digits)),
                ),
        ),
      ),
      body: body,
      bottomNavigationBar: list == null || !list.isOpen
          ? null
          : StickyActionBar(
              reason: list.courierId == null
                  ? Text(l10n.errChooseCourier, style: type.caption)
                  : null,
              primary: AppButton(
                label: l10n.handOver,
                icon: AppIcons.truck,
                loading: _busy,
                onPressed: _busy || list.courierId == null || list.stops.isEmpty
                    ? null
                    : () => _handOver(list),
              ),
            ),
    );
  }
}

class _StopCard extends ConsumerWidget {
  const _StopCard({
    required this.stop,
    required this.canRemove,
    required this.onRemove,
  });

  final DeliveryStop stop;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final s = stop;
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
            Text(
              [
                orderNumber(s.number),
                if (s.customerName != null) Bidi.auto(s.customerName!),
              ].join(' · '),
              style: type.bodyStrong.copyWith(color: p.textPrimary),
            ),
            if (s.phone != null)
              Text(
                [
                  PhoneNumbers.display(s.phone!),
                  if (s.phone2 != null) PhoneNumbers.display(s.phone2!),
                ].join(' · '),
                style: type.body,
              ),
            Text(
              _address(s).map(Bidi.auto).join(' · '),
              style: type.body.copyWith(color: p.textSecondary),
            ),
            Text(
              s.items.map((i) => _item(i, digits)).join(', '),
              style: type.caption.copyWith(color: p.textSecondary),
            ),
            const SizedBox(height: Space.s4),
            Text(
              l10n.cashToCollect(
                money(context, s.cashToCollect, s.currency, digits),
              ),
              style: type.label.copyWith(color: p.textPrimary),
            ),
            if (!s.complete)
              Text(
                l10n.orderIncompleteShort,
                style: type.caption.copyWith(color: p.warningFg),
              ),
            if (canRemove)
              AppButton(
                label: l10n.removeFromList,
                icon: AppIcons.x,
                variant: AppButtonVariant.tertiary,
                onPressed: onRemove,
              ),
          ],
        ),
      ),
    );
  }
}

List<String> _address(DeliveryStop s) => [
  if (s.place.isNotEmpty) s.place,
  ?s.area,
  ?s.landmark,
  ?s.address,
];

String _item(StopItem i, DigitStyle digits) =>
    '${Digits.display('${i.quantity}', digits)} × ${Bidi.auto([i.name, ?i.variant].join(' '))}';

/// The list as plain text, to paste into a message to the courier.
String deliveryListText(
  AppLocalizations l10n,
  DeliveryList list,
  String Function(int) money,
  DigitStyle digits,
) {
  final b = StringBuffer()
    ..writeln(
      l10n.deliveryListTitle(Digits.display('${list.number}', digits)) +
          (list.courierName == null ? '' : ' · ${list.courierName}'),
    )
    ..writeln(Dates.time(list.createdAt, digits: digits));
  for (final s in list.stops) {
    b
      ..writeln()
      ..writeln(['#${s.number}', ?s.customerName].join(' · '))
      ..writeln(
        [
          if (s.phone != null) PhoneNumbers.display(s.phone!),
          if (s.phone2 != null) PhoneNumbers.display(s.phone2!),
        ].join(' · '),
      )
      ..writeln(_address(s).join(' · '))
      ..writeln(s.items.map((i) => _item(i, digits)).join(', '))
      ..writeln(l10n.cashToCollect(money(s.cashToCollect)));
    if (s.customerNote != null) b.writeln(s.customerNote);
  }
  b
    ..writeln()
    ..writeln(l10n.listCashTotal(money(list.codTotal)));
  // Direction marks help a chat app show mixed text; the courier reads plain text.
  return b.toString().replaceAll(RegExp('[\u2066-\u2069]'), '').trim();
}
