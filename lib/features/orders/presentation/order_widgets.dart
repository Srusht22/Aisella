import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/money.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../catalog/application/catalog_providers.dart';
import '../domain/order.dart';
import 'order_text.dart';

/// A product photo for an order line, or the neutral package placeholder.
class LineImage extends ConsumerWidget {
  const LineImage({super.key, required this.path, this.size = Sizes.thumbRow});

  final String? path;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    Widget box(Widget? child) => ClipRRect(
      borderRadius: BorderRadius.circular(Sizes.thumbRadius),
      child: Container(
        width: size,
        height: size,
        color: p.bgSunken,
        alignment: Alignment.center,
        child: child,
      ),
    );
    final placeholder = box(
      Icon(AppIcons.package, size: size * 0.42, color: p.textTertiary),
    );
    final path = this.path;
    if (path == null) return ExcludeSemantics(child: placeholder);
    return ExcludeSemantics(
      child: switch (ref.watch(productImageProvider(path))) {
        AsyncData(:final value) => box(
          Image(
            image: value,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          ),
        ),
        AsyncError() => placeholder,
        _ => box(null),
      },
    );
  }
}

/// Label + amount; the label wraps, the amount is never truncated
/// (Phase 2 CMP-PriceRow).
class PriceRow extends StatelessWidget {
  const PriceRow({
    super.key,
    required this.label,
    required this.amount,
    this.emphasize = false,
  });

  final String label;
  final String amount;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: LayoutTokens.rowMinHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.s12,
          vertical: Space.s8,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: (emphasize ? type.bodyStrong : type.body).copyWith(
                  color: emphasize ? p.textPrimary : p.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: Space.s12),
            Text(
              amount,
              style: (emphasize ? type.numericTotal : type.numericBody)
                  .copyWith(color: p.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// One order line (Phase 2 OrderLineRow). Before approval it shows the live
/// catalog state beside the snapshot: stock, a changed price, or that the
/// item can no longer be sold. After approval only the committed values.
class OrderLineTile extends ConsumerWidget {
  const OrderLineTile({
    super.key,
    required this.line,
    required this.currency,
    required this.review,
  });

  final OrderLine line;
  final Currency currency;

  /// Draft or pending approval: show live stock, price and availability.
  final bool review;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    String m(int v) => money(context, v, currency, digits);
    final c = line.current;

    final notes = <Widget>[];
    if (review) {
      if (line.unavailable) {
        notes.add(
          StockIndicator(state: StockState.out, label: l10n.lineNotSold),
        );
      } else if (line.shortBy > 0) {
        notes.add(
          StockIndicator(
            state: StockState.out,
            label: l10n.lineShort(count(c!.stockOnHand, digits)),
          ),
        );
      } else if (c != null && c.trackStock) {
        notes.add(
          StockIndicator(
            state: StockState.inStock,
            label: l10n.stockInStock(count(c.stockOnHand, digits)),
          ),
        );
      }
      if (line.priceChanged) {
        notes.add(
          StatusBadge(
            label: l10n.linePriceChanged(m(c!.price)),
            icon: AppIcons.warning,
            tone: Tone.warning,
          ),
        );
      }
    }
    if (line.returned case final r?) {
      notes.add(
        Text(
          l10n.lineReturned(
            count(r.restock, digits),
            count(r.writeOff, digits),
          ),
          style: type.caption.copyWith(color: p.textSecondary),
        ),
      );
    }

    final qty = l10n.qtyTimesPrice(
      count(line.quantity, digits),
      m(line.unitPrice),
    );
    return Semantics(
      label:
          '${itemName(line.name, line.variantLabel)}, $qty, ${m(line.lineTotal)}',
      child: Padding(
        padding: const EdgeInsets.all(Space.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LineImage(path: line.imagePath),
            const SizedBox(width: Space.s12),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      itemName(line.name, line.variantLabel),
                      style: type.bodyStrong.copyWith(color: p.textPrimary),
                    ),
                    const SizedBox(height: Space.s2),
                    Text(
                      qty,
                      style: type.caption.copyWith(color: p.textSecondary),
                    ),
                    if (notes.isNotEmpty) ...[
                      const SizedBox(height: Space.s4),
                      Wrap(
                        spacing: Space.s8,
                        runSpacing: Space.s4,
                        children: notes,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: Space.s8),
            ExcludeSemantics(
              child: Text(
                m(line.lineTotal),
                style: type.numericBody.copyWith(color: p.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Subtotal, discount, delivery and total (BR-24: computed by the server).
class OrderTotals extends ConsumerWidget {
  const OrderTotals({super.key, required this.order});

  final Order order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final digits = ref.watch(settingsProvider).digits;
    String m(int v) => money(context, v, order.currency, digits);
    return RowGroup(
      children: [
        PriceRow(label: l10n.subtotal, amount: m(order.subtotal)),
        if (order.discount > 0)
          PriceRow(label: l10n.discount, amount: '− ${m(order.discount)}'),
        PriceRow(
          label: l10n.deliveryFee,
          amount: order.deliveryFee == null
              ? l10n.notSet
              : m(order.deliveryFee!),
        ),
        PriceRow(
          label: order.paymentMethod == PaymentMethod.cod
              ? l10n.totalCashOnDelivery
              : l10n.total,
          amount: m(order.total),
          emphasize: true,
        ),
      ],
    );
  }
}

/// A reason line under a sticky action bar: why the primary is disabled.
class ReasonLine extends StatelessWidget {
  const ReasonLine(this.text, {super.key, this.onTap});

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final row = Row(
      children: [
        Icon(AppIcons.info, size: Sizes.iconSm, color: p.warningFg),
        const SizedBox(width: Space.s4),
        Expanded(
          child: Text(
            text,
            style: context.type.caption.copyWith(color: p.warningFg),
          ),
        ),
      ],
    );
    if (onTap == null) return row;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: LayoutTokens.minTouchTarget,
          ),
          child: row,
        ),
      ),
    );
  }
}

/// Fades between values (status changes in place, OR-05 #14).
class Crossfade extends StatelessWidget {
  const Crossfade({super.key, required this.child, required this.valueKey});

  final Widget child;
  final Object valueKey;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.fade(context, MotionTokens.sm),
    child: KeyedSubtree(key: ValueKey(valueKey), child: child),
  );
}
