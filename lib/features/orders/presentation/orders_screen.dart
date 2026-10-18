import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/clock.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/primitives.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../catalog/application/catalog_providers.dart';
import '../../common/top_level_page.dart';
import '../application/order_providers.dart';
import '../domain/order.dart';
import 'order_detail_screen.dart';
import 'order_text.dart';

/// The order selected in the tablet list–detail layout (OR-01 "Expanded:
/// list–detail").
final selectedOrderProvider = NotifierProvider<SelectedOrder, String?>(
  SelectedOrder.new,
);

class SelectedOrder extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(currentStoreIdProvider);
    return null;
  }

  void select(String? id) => state = id;
}

void openNewOrder(BuildContext context) => context.push(Routes.orderNew);

/// OR-01 Order list: search (number, customer, phone in any form, product),
/// status chips with counts, newest first grouped by day, paging.
class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windowClass = WindowClass.of(context);
    final list = _OrderList(listDetail: windowClass.usesListDetail);
    if (!windowClass.usesListDetail) return list;
    final selected = ref.watch(selectedOrderProvider);
    final p = context.palette;
    return Row(
      children: [
        SizedBox(width: 420, child: list),
        VerticalDivider(width: Strokes.hairline, color: p.borderHairline),
        Expanded(
          child: selected == null
              ? ColoredBox(
                  color: p.bgCanvas,
                  child: Center(
                    child: EmptyState(
                      icon: AppIcons.receipt,
                      title: context.l10n.selectOrderHint,
                    ),
                  ),
                )
              : OrderDetailScreen(
                  key: ValueKey(selected),
                  orderId: selected,
                  embedded: true,
                ),
        ),
      ],
    );
  }
}

class _OrderList extends ConsumerWidget {
  const _OrderList({required this.listDetail});

  final bool listDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final list = ref.watch(orderListProvider);
    final counts = ref.watch(orderCountsProvider).value;
    final query = ref.watch(orderQueryProvider);
    final queryCtl = ref.read(orderQueryProvider.notifier);
    final digits = ref.watch(settingsProvider).digits;
    final storeEmpty = counts != null && counts[OrderFilter.all] == 0;

    final Widget body = switch (list) {
      _ when storeEmpty => EmptyState(
        icon: AppIcons.receipt,
        title: l10n.ordersEmptyTitle,
        body: l10n.ordersEmptyBody,
        action: AppButton(
          label: l10n.newOrder,
          icon: AppIcons.plus,
          onPressed: () => openNewOrder(context),
        ),
      ),
      AsyncData(:final value) when value.items.isEmpty => EmptyState(
        icon: AppIcons.magnifyingGlass,
        title: query.text.isNotEmpty
            ? l10n.noResultsFor(Bidi.auto(query.text))
            : l10n.noOrdersFilter,
        action: AppButton(
          label: l10n.clearFilters,
          variant: AppButtonVariant.secondary,
          onPressed: queryCtl.clear,
        ),
      ),
      AsyncData(:final value) => _Results(state: value, listDetail: listDetail),
      AsyncError(:final error) => ErrorState(
        cause: orderLoadErrorText(l10n, error),
        onRetry: () => ref.invalidate(orderListProvider),
      ),
      _ => const _OrdersSkeleton(),
    };

    String chipLabel(OrderFilter f) {
      final n = f == OrderFilter.all ? null : counts?[f];
      final label = filterLabel(l10n, f);
      return n == null || n == 0
          ? label
          : '$label · ${Bidi.ltr(Digits.display('$n', digits))}';
    }

    final rail = WindowClass.of(context).usesRail;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 600) {
          ref.read(orderListProvider.notifier).loadMore();
        }
        return false;
      },
      child: TopLevelPage(
        title: l10n.ordersTitle,
        subtitle: list.value == null || storeEmpty
            ? null
            : l10n.ordersCount(list.value!.total),
        onRefresh: () async {
          ref.invalidate(orderCountsProvider);
          ref.invalidate(orderListProvider);
          try {
            await ref.read(orderListProvider.future);
          } on Object {
            // The list shows the error state with Retry.
          }
        },
        floatingActionButton: storeEmpty || rail
            ? null
            : FloatingActionButton.extended(
                onPressed: () => openNewOrder(context),
                backgroundColor: context.palette.brandPrimary,
                foregroundColor: context.palette.textOnBrand,
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                icon: const Icon(AppIcons.plus, size: Sizes.iconMd),
                label: Text(
                  l10n.newOrder,
                  style: context.type.button.copyWith(
                    color: context.palette.textOnBrand,
                  ),
                ),
              ),
        slivers: [
          if (!storeEmpty)
            SliverToBoxAdapter(
              child: ContentWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (rail) ...[
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: AppButton(
                          label: l10n.newOrder,
                          icon: AppIcons.plus,
                          onPressed: () => openNewOrder(context),
                        ),
                      ),
                      const SizedBox(height: Space.s12),
                    ],
                    // Phase 10: group ready orders for a courier.
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: AppButton(
                        label: l10n.deliveryListsTitle,
                        icon: AppIcons.truck,
                        variant: AppButtonVariant.tertiary,
                        onPressed: () => context.push(Routes.deliveryLists),
                      ),
                    ),
                    AppSearchField(
                      hint: l10n.searchOrdersHint,
                      clearTooltip: MaterialLocalizations.of(context)
                          .clearButtonTooltip,
                      onChanged: queryCtl.setText,
                    ),
                    const SizedBox(height: Space.s8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final f in OrderFilter.values)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(
                                end: Space.s8,
                              ),
                              child: ChoiceChip(
                                label: Text(chipLabel(f)),
                                selected: query.filter == f,
                                showCheckmark: false,
                                onSelected: (_) => queryCtl.setFilter(f),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.s8),
                  ],
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: ContentWidth(
              child: AnimatedSwitcher(duration: MotionTokens.sm, child: body),
            ),
          ),
        ],
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.state, required this.listDetail});

  final OrderListState state;
  final bool listDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final digits = ref.watch(settingsProvider).digits;
    final locale = Localizations.localeOf(context);
    final now = ref.watch(clockProvider)();
    final selected = listDetail ? ref.watch(selectedOrderProvider) : null;

    String dayTitle(DateTime d) {
      final today = DateTime(now.year, now.month, now.day);
      final day = DateTime(d.year, d.month, d.day);
      final diff = today.difference(day).inDays;
      if (diff == 0) return l10n.dayToday;
      if (diff == 1) return l10n.dayYesterday;
      return Dates.dayMonthYear(d, locale: locale, digits: digits);
    }

    // Grouped by day, newest first (the server orders the list).
    final groups = <(String, List<OrderSummary>)>[];
    for (final o in state.items) {
      final title = dayTitle(o.createdAt);
      if (groups.isEmpty || groups.last.$1 != title) {
        groups.add((title, [o]));
      } else {
        groups.last.$2.add(o);
      }
    }

    var index = 0;
    return Column(
      key: ValueKey(state.query),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (title, orders) in groups) ...[
          SectionHeader(title),
          RowGroup(
            children: [
              for (final o in orders)
                _OrderRow(
                  key: ValueKey(o.id),
                  order: o,
                  selected: o.id == selected,
                  animate: index++ < 12,
                  onTap: () => listDetail
                      ? ref.read(selectedOrderProvider.notifier).select(o.id)
                      : context.push(Routes.order(o.id)),
                ),
            ],
          ),
          const SizedBox(height: Space.s16),
        ],
        if (state.loadingMore)
          const Padding(
            padding: EdgeInsets.all(Space.s16),
            child: Center(
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (state.moreFailed)
          Padding(
            padding: const EdgeInsets.all(Space.s8),
            child: Column(
              children: [
                Text(
                  l10n.loadMoreFailed,
                  style: context.type.caption.copyWith(
                    color: context.palette.textSecondary,
                  ),
                ),
                AppButton(
                  label: l10n.retry,
                  variant: AppButtonVariant.tertiary,
                  onPressed: () =>
                      ref.read(orderListProvider.notifier).loadMore(),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _OrderRow extends ConsumerWidget {
  const _OrderRow({
    super.key,
    required this.order,
    required this.onTap,
    this.selected = false,
    this.animate = false,
  });

  final OrderSummary order;
  final VoidCallback onTap;
  final bool selected;
  final bool animate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final total = money(context, order.total, order.currency, digits);
    final name = order.customerName ?? l10n.noCustomerName;
    final items = order.firstItemName == null
        ? l10n.noItemsYet
        : [
            '${count(order.firstItemQuantity ?? 1, digits)} × '
                '${itemName(order.firstItemName!, order.firstItemLabel ?? '')}',
            if (order.itemCount > 1)
              Bidi.ltr('+${Digits.display('${order.itemCount - 1}', digits)}'),
          ].join(' ');
    final time = Dates.time(order.createdAt, digits: digits);

    final row = Semantics(
      button: true,
      selected: selected,
      label: [
        l10n.orderTitle(orderNumber(order.number)),
        statusLabel(l10n, order.status),
        name,
        items,
        total,
        if (order.codOutstanding > 0) l10n.cashOutstanding,
        time,
      ].join(', '),
      excludeSemantics: true,
      child: Material(
        color: selected ? p.bgBrandWeak : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.s12,
                vertical: Space.s8,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: Space.s8,
                          runSpacing: Space.s4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              orderNumber(order.number),
                              style: type.bodyStrong.copyWith(
                                color: p.textPrimary,
                              ),
                            ),
                            OrderStatusBadge(order.status),
                          ],
                        ),
                        const SizedBox(height: Space.s4),
                        Text(
                          Bidi.auto(name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: type.body.copyWith(
                            color: order.customerName == null
                                ? p.textTertiary
                                : p.textPrimary,
                          ),
                        ),
                        Text(
                          items,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: type.caption.copyWith(color: p.textSecondary),
                        ),
                        if (order.issueCount > 0)
                          Text(
                            l10n.issuesCount(order.issueCount),
                            style: type.caption.copyWith(color: p.warningFg),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.s8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        total,
                        style: type.numericBody.copyWith(color: p.textPrimary),
                      ),
                      const SizedBox(height: Space.s4),
                      Text(
                        time,
                        style: type.caption.copyWith(color: p.textTertiary),
                      ),
                      if (order.codOutstanding > 0) ...[
                        const SizedBox(height: Space.s4),
                        Icon(
                          AppIcons.money,
                          size: Sizes.iconSm,
                          color: p.warningFg,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return animate ? FadeSlideIn(child: row) : row;
  }
}

class _OrdersSkeleton extends StatelessWidget {
  const _OrdersSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: Column(
        children: [
          for (var i = 0; i < 6; i++)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.s12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBlock(width: 140, height: 14),
                        SizedBox(height: Space.s8),
                        SkeletonBlock(height: 10),
                      ],
                    ),
                  ),
                  SizedBox(width: Space.s12),
                  SkeletonBlock(width: 72, height: 12),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
