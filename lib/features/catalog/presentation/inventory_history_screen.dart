import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../application/catalog_providers.dart';
import '../domain/catalog.dart';
import 'catalog_text.dart';

/// PR-06 Inventory history: every movement, newest first, grouped by day,
/// filterable by option. Read-only; the newest entry's result equals the
/// current stock (US-017).
class InventoryHistoryScreen extends ConsumerStatefulWidget {
  const InventoryHistoryScreen({super.key, required this.productId});

  final String productId;

  @override
  ConsumerState<InventoryHistoryScreen> createState() =>
      _InventoryHistoryScreenState();
}

class _InventoryHistoryScreenState
    extends ConsumerState<InventoryHistoryScreen> {
  String? _variantId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final product = ref.watch(productProvider(widget.productId)).value;
    final key = (productId: widget.productId, variantId: _variantId);
    final movements = ref.watch(movementsProvider(key));

    final Widget body = switch (movements) {
      AsyncData(:final value) when value.items.isEmpty => EmptyState(
        icon: AppIcons.clockCounterClockwise,
        title: l10n.historyEmpty,
      ),
      AsyncData(:final value) => _MovementList(
        state: value,
        showVariant: product?.hasOptions ?? false,
        onMore: () => ref.read(movementsProvider(key).notifier).loadMore(),
      ),
      AsyncError(:final error) => ErrorState(
        cause: loadErrorText(l10n, error),
        onRetry: () => ref.invalidate(movementsProvider(key)),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };

    final variants = product?.hasOptions ?? false
        ? product!.variants
        : const <Variant>[];
    return Scaffold(
      backgroundColor: p.bgCanvas,
      appBar: AppBar(title: Text(l10n.inventoryHistory)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.s32),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (product != null) ...[
                  Text(
                    product.name,
                    textDirection: Bidi.detect(product.name),
                    style: context.type.bodyStrong.copyWith(
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: Space.s12),
                ],
                if (variants.isNotEmpty) ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (id, label) in [
                          (null, l10n.allOptions),
                          for (final v in variants) (v.id, v.label),
                        ])
                          Padding(
                            padding: const EdgeInsetsDirectional.only(
                              end: Space.s8,
                            ),
                            child: ChoiceChip(
                              label: Text(label),
                              selected: _variantId == id,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  setState(() => _variantId = id),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s12),
                ],
                body,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MovementList extends ConsumerWidget {
  const _MovementList({
    required this.state,
    required this.showVariant,
    required this.onMore,
  });

  final MovementsState state;
  final bool showVariant;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context);
    final digits = ref.watch(settingsProvider).digits;
    final groups = <DateTime, List<InventoryMovement>>{};
    for (final m in state.items) {
      final day = DateTime(
        m.createdAt.year,
        m.createdAt.month,
        m.createdAt.day,
      );
      (groups[day] ??= []).add(m);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final MapEntry(key: day, value: items) in groups.entries) ...[
          SectionHeader(
            Dates.dayMonthYear(day, locale: locale, digits: digits),
          ),
          RowGroup(
            children: [
              for (final m in items)
                _MovementRow(movement: m, showVariant: showVariant),
            ],
          ),
          const SizedBox(height: Space.s16),
        ],
        if (state.hasMore)
          AppButton(
            label: l10n.loadMore,
            variant: AppButtonVariant.tertiary,
            loading: state.loadingMore,
            onPressed: onMore,
          ),
      ],
    );
  }
}

class _MovementRow extends ConsumerWidget {
  const _MovementRow({required this.movement, required this.showVariant});

  final InventoryMovement movement;
  final bool showVariant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final m = movement;
    // Colour-neutral delta with a sign and an icon (PR-06).
    final delta = Bidi.ltr(
      '${m.delta > 0 ? '+' : '−'}${Digits.display('${m.delta.abs()}', digits)}',
    );
    final reason = reasonLabel(l10n, m.reason);
    final details = [
      Dates.time(m.createdAt, digits: digits),
      actorLabel(l10n, m.actor),
      if (showVariant && m.variantLabel.isNotEmpty) m.variantLabel,
    ].join(' · ');
    final resulting = l10n.resultingStock(count(m.resultingQty, digits));
    return Semantics(
      label:
          '$reason, $delta, $resulting, $details${m.note == null ? '' : ', ${m.note}'}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.s12,
          vertical: Space.s8,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Space.s2),
              child: Icon(
                m.delta > 0 ? AppIcons.plus : AppIcons.minus,
                size: Sizes.iconSm,
                color: p.textSecondary,
              ),
            ),
            const SizedBox(width: Space.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(reason, style: type.body.copyWith(color: p.textPrimary)),
                  Text(
                    details,
                    style: type.caption.copyWith(color: p.textSecondary),
                  ),
                  if (m.note != null)
                    Text(
                      m.note!,
                      textDirection: Bidi.detect(m.note!),
                      style: type.caption.copyWith(color: p.textSecondary),
                    ),
                ],
              ),
            ),
            const SizedBox(width: Space.s8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  delta,
                  style: type.numericBody.copyWith(color: p.textPrimary),
                ),
                Text(
                  resulting,
                  style: type.caption.copyWith(color: p.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
