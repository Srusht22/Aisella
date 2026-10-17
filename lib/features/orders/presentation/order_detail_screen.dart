import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/phone.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/pencil.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../application/order_providers.dart';
import '../domain/order.dart';
import 'order_sheets.dart';
import 'order_text.dart';
import 'order_widgets.dart';

/// OR-02 Draft review (draft, pending approval) and OR-05 Order detail
/// (approved through terminal). Everything shown comes from the server and
/// is re-read after every change; nothing here can approve without the
/// explicit confirmation sheet (OR-03).
class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({
    super.key,
    required this.orderId,
    this.embedded = false,
  });

  final String orderId;

  /// Shown as the detail pane of the tablet list–detail layout.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final order = ref.watch(orderProvider(orderId));
    final value = order.value;

    final Widget body = switch (order) {
      AsyncData(:final value) => _DetailBody(order: value),
      AsyncError(:final error) =>
        error is ApiException && error.code == ApiErrorCode.notFound
            ? EmptyState(
                icon: AppIcons.receipt,
                title: l10n.orderUnavailableTitle,
                body: l10n.orderUnavailableBody,
              )
            : ErrorState(
                cause: orderLoadErrorText(l10n, error),
                onRetry: () => ref.invalidate(orderProvider(orderId)),
              ),
      _ => const Center(child: CircularProgressIndicator()),
    };

    return Scaffold(
      backgroundColor: p.bgCanvas,
      appBar: AppBar(
        automaticallyImplyLeading: !embedded,
        title: Text(
          value == null ? '' : l10n.orderTitle(orderNumber(value.number)),
        ),
        actions: [if (value != null) _OverflowMenu(order: value)],
      ),
      body: AnimatedSwitcher(
        duration: Motion.fade(context, MotionTokens.sm),
        child: KeyedSubtree(key: ValueKey(order.hasValue), child: body),
      ),
      bottomNavigationBar: value == null ? null : _ActionBar(order: value),
    );
  }
}

enum _Menu { edit, cancel, confirmation, note, history, returned }

class _OverflowMenu extends ConsumerWidget {
  const _OverflowMenu({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final s = order.status;
    final items = <(_Menu, String, IconData)>[
      if (s.isDraftLike || s.beforeDispatch)
        (_Menu.edit, l10n.editOrder, AppIcons.pencilSimple),
      if (s.canConfirm)
        (_Menu.confirmation, l10n.copyConfirmation, AppIcons.copy),
      if (s == OrderStatus.dispatched)
        (_Menu.returned, l10n.markReturned, AppIcons.arrowUUpLeft),
      (_Menu.note, l10n.internalNote, AppIcons.chatText),
      (_Menu.history, l10n.fullHistory, AppIcons.clockCounterClockwise),
      if (s.beforeDispatch) (_Menu.cancel, l10n.cancelOrder, AppIcons.xCircle),
    ];
    return PopupMenuButton<_Menu>(
      tooltip: l10n.moreActions,
      icon: const Icon(AppIcons.dotsThree),
      onSelected: (m) => switch (m) {
        _Menu.edit => context.push(Routes.orderEdit(order.id)),
        _Menu.cancel => showCancelSheet(context, order),
        _Menu.confirmation => showConfirmationSheet(context, order),
        _Menu.note => showNoteSheet(context, order),
        _Menu.history => context.push(Routes.orderHistory(order.id)),
        _Menu.returned => showReturnSheet(context, order),
      },
      itemBuilder: (_) => [
        for (final (m, label, icon) in items)
          PopupMenuItem(
            value: m,
            child: Row(
              children: [
                Icon(icon, size: Sizes.iconMd),
                const SizedBox(width: Space.s12),
                Flexible(child: Text(label)),
              ],
            ),
          ),
      ],
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final locale = Localizations.localeOf(context);
    final review = order.status.isDraftLike;
    String m(int v) => money(context, v, order.currency, digits);
    Text muted(String t) =>
        Text(t, style: type.body.copyWith(color: p.textTertiary));
    Widget value(String? v, {bool ltr = false}) => v == null || v.isEmpty
        ? muted(review ? l10n.missingValue : l10n.notProvided)
        : Text(ltr ? v : Bidi.auto(v));

    final blocked = review ? order.blockedLines : const <OrderLine>[];
    final children = <Widget>[
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Crossfade(
          valueKey: order.status,
          child: OrderStatusBadge(order.status),
        ),
      ),
      const SizedBox(height: Space.s12),
      if (review) ...[
        PencilBox(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                AppIcons.pencilSimple,
                size: Sizes.iconMd,
                color: p.textPencil,
              ),
              const SizedBox(width: Space.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.draftBannerTitle,
                      style: type.bodyStrong.copyWith(color: p.textPrimary),
                    ),
                    const SizedBox(height: Space.s2),
                    Text(
                      l10n.manualDraftBody,
                      style: type.label.copyWith(color: p.textPencil),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (order.issues.isNotEmpty) ...[
          const SizedBox(height: Space.s12),
          Semantics(
            liveRegion: true,
            child: AppBanner(
              tone: Tone.warning,
              icon: AppIcons.warning,
              title: l10n.issuesCount(order.issues.length),
              body: order.issues.map((i) => issueText(l10n, i)).join('\n'),
            ),
          ),
        ],
        if (blocked.isNotEmpty) ...[
          const SizedBox(height: Space.s12),
          AppBanner(
            tone: Tone.danger,
            icon: AppIcons.warningCircle,
            title: l10n.linesBlockApproval(blocked.length),
            body: l10n.linesBlockApprovalBody,
          ),
        ],
      ] else
        _Progress(order: order),
      const SizedBox(height: Space.s24),
      SectionHeader(l10n.sectionCustomer),
      RowGroup(
        children: [
          FieldRow(label: l10n.fieldName, value: value(order.customerName)),
          FieldRow(
            label: l10n.fieldPhone,
            value: order.customerPhone == null
                ? value(null)
                : Text(
                    PhoneNumbers.display(order.customerPhone!),
                    style: type.numericBody,
                  ),
          ),
          if (order.customerPhone2 != null)
            FieldRow(
              label: l10n.fieldPhone2,
              value: Text(
                PhoneNumbers.display(order.customerPhone2!),
                style: type.numericBody,
              ),
            ),
        ],
      ),
      const SizedBox(height: Space.s24),
      SectionHeader(l10n.sectionDelivery),
      RowGroup(
        children: [
          FieldRow(
            label: order.zoneId != null ? l10n.fieldZone : l10n.fieldCity,
            value: value(order.place),
          ),
          FieldRow(label: l10n.fieldArea, value: value(order.area)),
          FieldRow(
            label: l10n.fieldLandmark,
            value: order.landmark == null
                ? muted(l10n.notProvidedOptional)
                : Text(Bidi.auto(order.landmark!)),
          ),
          if (order.addressDetails != null)
            FieldRow(
              label: l10n.fieldAddressDetails,
              value: Text(Bidi.auto(order.addressDetails!)),
            ),
          FieldRow(
            label: l10n.fieldFee,
            value: order.deliveryFee == null
                ? value(null)
                : Text(m(order.deliveryFee!), style: type.numericBody),
            caption: order.deliveryFee == null
                ? null
                : ProvenanceCaption(
                    kind: order.feeFromSeller
                        ? Provenance.editedByYou
                        : Provenance.settings,
                    label: order.feeFromSeller
                        ? l10n.feeSetByYou
                        : l10n.provFromSettings,
                  ),
          ),
          if (order.courierNote != null)
            FieldRow(
              label: l10n.fieldCourier,
              value: Text(Bidi.auto(order.courierNote!)),
            ),
        ],
      ),
      const SizedBox(height: Space.s24),
      SectionHeader(l10n.sectionItems),
      if (order.lines.isEmpty)
        RowGroup(
          children: [
            Padding(
              padding: const EdgeInsets.all(Space.s12),
              child: muted(l10n.noItemsYet),
            ),
          ],
        )
      else
        RowGroup(
          children: [
            for (final line in order.lines)
              OrderLineTile(
                line: line,
                currency: order.currency,
                review: review,
              ),
          ],
        ),
      const SizedBox(height: Space.s24),
      SectionHeader(l10n.sectionTotal),
      OrderTotals(order: order),
      const SizedBox(height: Space.s24),
      SectionHeader(l10n.sectionPayment),
      RowGroup(
        children: [
          FieldRow(
            label: l10n.fieldPaymentMethod,
            value: switch (order.paymentMethod) {
              PaymentMethod.cod => Text(l10n.paymentCod),
              PaymentMethod.other => Text(
                order.paymentNote == null
                    ? l10n.paymentOther
                    : '${l10n.paymentOther} · ${Bidi.auto(order.paymentNote!)}',
              ),
              null => value(null),
            },
          ),
          if (!review && order.paymentMethod == PaymentMethod.cod) ...[
            PriceRow(label: l10n.cashDue, amount: m(order.codDue)),
            PriceRow(label: l10n.cashCollected, amount: m(order.codCollected)),
            if (order.codOutstanding > 0)
              PriceRow(
                label: l10n.cashOutstanding,
                amount: m(order.codOutstanding),
                emphasize: true,
              ),
          ],
        ],
      ),
      if (order.customerNote != null || order.internalNote != null) ...[
        const SizedBox(height: Space.s24),
        SectionHeader(l10n.sectionNotes),
        RowGroup(
          children: [
            if (order.customerNote != null)
              FieldRow(
                label: l10n.fieldCustomerNote,
                value: Text(Bidi.auto(order.customerNote!)),
              ),
            if (order.internalNote != null)
              FieldRow(
                label: l10n.internalNote,
                value: Text(Bidi.auto(order.internalNote!)),
              ),
          ],
        ),
      ],
      if (order.closedReason != null || order.closedNote != null) ...[
        const SizedBox(height: Space.s24),
        AppBanner(
          tone: Tone.neutral,
          icon: statusLook(order.status).$1,
          title: order.closedReason == null
              ? statusLabel(l10n, order.status)
              : '${statusLabel(l10n, order.status)} · '
                    '${reasonText(l10n, order.closedReason)}',
          body: order.closedNote == null ? null : Bidi.auto(order.closedNote!),
        ),
      ],
      const SizedBox(height: Space.s24),
      SectionHeader(
        l10n.sectionHistory,
        action: AppButton(
          label: l10n.fullHistory,
          variant: AppButtonVariant.tertiary,
          onPressed: () => context.push(Routes.orderHistory(order.id)),
        ),
      ),
      RowGroup(
        children: [
          for (final e in order.events.reversed.take(3))
            FieldRow(
              label:
                  '${Dates.dayMonthYear(e.createdAt, locale: locale, digits: digits)} · '
                  '${Dates.time(e.createdAt, digits: digits)}',
              value: Text(eventText(l10n, e)),
            ),
        ],
      ),
    ];

    return ListView(
      padding: const EdgeInsets.only(top: Space.s8, bottom: Space.s24),
      children: [
        ContentWidth(
          maxWidth: LayoutTokens.maxWidthForm,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}

/// "Approved by you", "Marked out for delivery by you", "Created".
String eventText(AppLocalizations l10n, OrderEvent e) {
  final who = switch (e.actor) {
    Actor.you => l10n.actorYou,
    Actor.member => l10n.actorMember,
    Actor.system => l10n.actorSystem,
  };
  final what = e.from == null
      ? l10n.eventCreated(statusLabel(l10n, e.to))
      : l10n.eventStatus(statusLabel(l10n, e.to));
  final reason = e.reason == null ? '' : ' · ${reasonText(l10n, e.reason)}';
  return '$what · $who$reason';
}

/// The four-step tracker (OR-05), or the branch state by name.
class _Progress extends ConsumerWidget {
  const _Progress({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final step = order.status.trackerStep;
    if (step == null) {
      final (icon, tone) = statusLook(order.status);
      return AppBanner(
        tone: tone == Tone.warning ? Tone.warning : Tone.neutral,
        icon: icon,
        title: statusLabel(l10n, order.status),
        body: order.failureReason == null
            ? null
            : reasonText(l10n, order.failureReason),
      );
    }
    final labels = [
      l10n.statusApproved,
      l10n.statusPreparing,
      l10n.statusOutForDelivery,
      l10n.statusDelivered,
    ];
    return Semantics(
      label: l10n.trackerStep(step + 1, labels[step]),
      excludeSemantics: true,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedContainer(
                    duration: Motion.fade(context, MotionTokens.md),
                    height: 4,
                    margin: const EdgeInsetsDirectional.only(end: Space.s4),
                    decoration: BoxDecoration(
                      color: i <= step ? p.brandPrimary : p.borderHairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: Space.s4),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: Space.s8),
                    child: Text(
                      labels[i],
                      maxLines: 2,
                      style: type.caption.copyWith(
                        color: i <= step ? p.textPrimary : p.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The sticky next step: Approve and Reject for a draft; the next
/// fulfilment step afterwards; nothing for terminal orders.
class _ActionBar extends ConsumerWidget {
  const _ActionBar({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    switch (order.status) {
      case OrderStatus.draft || OrderStatus.pendingApproval:
        final reason = order.issues.isNotEmpty
            ? l10n.reasonCompleteFirst
            : order.blockedLines.isNotEmpty
            ? l10n.reasonFixItems
            : null;
        return StickyActionBar(
          reason: reason == null ? null : ReasonLine(reason),
          secondary: AppButton(
            label: l10n.reject,
            variant: AppButtonVariant.dangerOutline,
            onPressed: () => showRejectSheet(context, order),
          ),
          primary: Semantics(
            hint: reason,
            child: AppButton(
              label: l10n.approveOrder,
              onPressed: order.canApprove
                  ? () => showApproveSheet(context, order)
                  : null,
            ),
          ),
        );
      case OrderStatus.approved:
        return StickyActionBar(
          secondary: AppButton(
            label: l10n.markOutForDelivery,
            variant: AppButtonVariant.secondary,
            onPressed: () => showDispatchSheet(context, order),
          ),
          primary: _ImmediateTransition(
            order: order,
            to: OrderStatus.processing,
            label: l10n.markPreparing,
            done: l10n.markedPreparing,
          ),
        );
      case OrderStatus.processing:
        return StickyActionBar(
          primary: AppButton(
            label: l10n.markOutForDelivery,
            onPressed: () => showDispatchSheet(context, order),
          ),
        );
      case OrderStatus.dispatched:
        return StickyActionBar(
          secondary: AppButton(
            label: l10n.deliveryFailedAction,
            variant: AppButtonVariant.secondary,
            onPressed: () => showFailedSheet(context, order),
          ),
          primary: AppButton(
            label: l10n.markDelivered,
            onPressed: () => showDeliveredSheet(context, order),
          ),
        );
      case OrderStatus.deliveryFailed:
        return StickyActionBar(
          secondary: AppButton(
            label: l10n.markReturned,
            variant: AppButtonVariant.secondary,
            onPressed: () => showReturnSheet(context, order),
          ),
          primary: AppButton(
            label: l10n.tryAgain,
            onPressed: () => showDispatchSheet(context, order),
          ),
        );
      case OrderStatus.delivered when order.codOutstanding > 0:
        return StickyActionBar(
          primary: AppButton(
            label: l10n.recordCash,
            onPressed: () => showCashSheet(context, order),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

/// "Mark as preparing": no sheet, the button shows progress (OR-08).
class _ImmediateTransition extends ConsumerStatefulWidget {
  const _ImmediateTransition({
    required this.order,
    required this.to,
    required this.label,
    required this.done,
  });

  final Order order;
  final OrderStatus to;
  final String label;
  final String done;

  @override
  ConsumerState<_ImmediateTransition> createState() =>
      _ImmediateTransitionState();
}

class _ImmediateTransitionState extends ConsumerState<_ImmediateTransition> {
  final _key = IntentKey();
  bool _busy = false;

  Future<void> _run() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(orderActionsProvider)
          .transition(
            widget.order,
            widget.to,
            idempotencyKey: _key.forPayload(
              '${widget.order.id}:${widget.order.version}:${widget.to.wire}',
            ),
          );
      _key.reset();
      showSnackOn(messenger, widget.done);
    } on ApiException catch (e) {
      ref.invalidate(orderProvider(widget.order.id));
      showSnackOn(
        messenger,
        orderErrorText(l10n, e, digits: ref.read(settingsProvider).digits),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppButton(
    label: widget.label,
    loading: _busy,
    onPressed: _busy ? null : _run,
  );
}
