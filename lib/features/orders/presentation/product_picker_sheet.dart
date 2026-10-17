import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../catalog/application/catalog_providers.dart';
import '../../catalog/domain/catalog.dart';
import '../application/order_providers.dart';
import '../domain/order_draft.dart';
import 'order_text.dart';
import 'order_widgets.dart';

/// OR-07 Product and variant picker (full-height sheet). Only active
/// products are listed; unavailable variants are shown disabled with the
/// reason. Returns the line to add, or null.
Future<DraftLine?> showProductPicker(BuildContext context) =>
    showModalBottomSheet<DraftLine>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          const FractionallySizedBox(heightFactor: 0.94, child: _Picker()),
    );

class _Picker extends ConsumerStatefulWidget {
  const _Picker();

  @override
  ConsumerState<_Picker> createState() => _PickerState();
}

class _PickerState extends ConsumerState<_Picker> {
  String _text = '';
  Timer? _debounce;
  String? _productId;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    return Material(
      color: p.bgSurface,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                Space.s4,
                Space.s8,
                Space.s16,
                Space.s8,
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: _productId == null ? l10n.close : l10n.back,
                    icon: Icon(
                      _productId == null ? AppIcons.x : AppIcons.arrowLeft,
                    ),
                    onPressed: () => _productId == null
                        ? Navigator.of(context).pop()
                        : setState(() => _productId = null),
                  ),
                  Expanded(
                    child: Text(
                      l10n.addItem,
                      style: context.type.heading.copyWith(
                        color: p.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _productId == null
                  ? _productList(context)
                  : _VariantStep(productId: _productId!),
            ),
          ],
        ),
      ),
    );
  }

  Widget _productList(BuildContext context) {
    final l10n = context.l10n;
    final results = ref.watch(pickerProductsProvider(_text));
    final summary = ref.watch(catalogSummaryProvider).value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.s16),
          child: AppSearchField(
            hint: l10n.searchProductsHint,
            autofocus: true,
            clearTooltip: MaterialLocalizations.of(context).clearButtonTooltip,
            onChanged: (t) {
              _debounce?.cancel();
              _debounce = Timer(searchDebounce, () {
                if (mounted) setState(() => _text = t.trim());
              });
            },
          ),
        ),
        const SizedBox(height: Space.s8),
        Expanded(
          child: switch (results) {
            _ when summary != null && summary.all == 0 => EmptyState(
              icon: AppIcons.package,
              title: l10n.productsEmptyTitle,
              action: AppButton(
                label: l10n.addProduct,
                icon: AppIcons.plus,
                onPressed: () => context.push(Routes.productNew),
              ),
            ),
            AsyncData(:final value) when value.isEmpty => EmptyState(
              icon: AppIcons.magnifyingGlass,
              title: _text.isEmpty
                  ? l10n.noActiveProducts
                  : l10n.noResultsFor(Bidi.auto(_text)),
            ),
            AsyncData(:final value) => ListView(
              padding: const EdgeInsets.symmetric(horizontal: Space.s16),
              children: [
                RowGroup(
                  children: [
                    for (final product in value)
                      _ProductOption(
                        product: product,
                        onTap: () => setState(() => _productId = product.id),
                      ),
                  ],
                ),
              ],
            ),
            AsyncError(:final error) => ErrorState(
              cause: orderLoadErrorText(l10n, error),
              onRetry: () => ref.invalidate(pickerProductsProvider(_text)),
            ),
            _ => const Center(child: CircularProgressIndicator()),
          },
        ),
      ],
    );
  }
}

class _ProductOption extends ConsumerWidget {
  const _ProductOption({required this.product, required this.onTap});

  final ProductSummary product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final price = money(context, product.priceMin, storeCurrency(ref), digits);
    final (state, stock) = switch (product.stockStatus) {
      StockStatus.out => (StockState.out, l10n.stockOut),
      StockStatus.unavailable => (StockState.out, l10n.stockUnavailable),
      StockStatus.available => (StockState.inStock, l10n.stockAvailable),
      StockStatus.low => (
        StockState.low,
        l10n.stockLow(count(product.stockTotal, digits)),
      ),
      StockStatus.inStock => (
        StockState.inStock,
        l10n.stockInStock(count(product.stockTotal, digits)),
      ),
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(Space.s12),
        child: Row(
          children: [
            LineImage(path: product.imagePath),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Bidi.auto(product.name),
                    style: type.bodyStrong.copyWith(color: p.textPrimary),
                  ),
                  Text(
                    product.variantCount > 1
                        ? '$price · ${l10n.variantCount(product.variantCount)}'
                        : price,
                    style: type.caption.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.s8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: StockIndicator(state: state, label: stock),
            ),
          ],
        ),
      ),
    );
  }
}

/// Variant chips (unavailable ones disabled, with the reason), quantity, and
/// Add to order.
class _VariantStep extends ConsumerStatefulWidget {
  const _VariantStep({required this.productId});
  final String productId;

  @override
  ConsumerState<_VariantStep> createState() => _VariantStepState();
}

class _VariantStepState extends ConsumerState<_VariantStep> {
  String? _variantId;
  int _quantity = 1;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final product = ref.watch(productProvider(widget.productId));
    return switch (product) {
      AsyncData(:final value) => _content(context, value),
      AsyncError(:final error) => ErrorState(
        cause: orderLoadErrorText(l10n, error),
        onRetry: () => ref.invalidate(productProvider(widget.productId)),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  bool _sellable(Product product, Variant v) =>
      product.trackStock ? v.stockOnHand > 0 : v.available;

  Widget _content(BuildContext context, Product product) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final currency = storeCurrency(ref);
    final variants = product.activeVariants;
    final sellable = [
      for (final v in variants)
        if (_sellable(product, v)) v,
    ];
    // A product without options has one variant: preselect it.
    _variantId ??= variants.length == 1 && sellable.isNotEmpty
        ? variants.single.id
        : null;
    final chosen = variants.where((v) => v.id == _variantId).firstOrNull;
    final max = chosen == null || !product.trackStock
        ? maxLineQuantity
        : chosen.stockOnHand.clamp(1, maxLineQuantity);

    return ListView(
      padding: const EdgeInsets.all(Space.s16),
      children: [
        Text(
          Bidi.auto(product.name),
          style: type.heading.copyWith(color: p.textPrimary),
        ),
        const SizedBox(height: Space.s16),
        if (variants.length > 1) ...[
          SectionHeader(l10n.chooseOption),
          Wrap(
            spacing: Space.s8,
            runSpacing: Space.s8,
            children: [
              for (final v in variants)
                ChoiceChip(
                  label: Text(
                    _sellable(product, v)
                        ? '${Bidi.auto(v.label)} · ${money(context, v.price, currency, digits)}'
                        : '${Bidi.auto(v.label)} · ${l10n.stockOut}',
                  ),
                  selected: v.id == _variantId,
                  showCheckmark: false,
                  onSelected: _sellable(product, v)
                      ? (_) => setState(() {
                          _variantId = v.id;
                          _quantity = 1;
                        })
                      : null,
                ),
            ],
          ),
          const SizedBox(height: Space.s16),
        ],
        if (sellable.isEmpty)
          AppBanner(
            tone: Tone.neutral,
            icon: AppIcons.prohibit,
            title: product.trackStock ? l10n.stockOut : l10n.stockUnavailable,
          ),
        if (chosen != null) ...[
          Text(
            [
              money(context, chosen.price, currency, digits),
              if (product.trackStock)
                l10n.stockInStock(count(chosen.stockOnHand, digits)),
            ].join(' · '),
            style: type.body.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: Space.s12),
          QuantityStepper(
            value: _quantity,
            max: max,
            onChanged: (q) => setState(() => _quantity = q),
          ),
          const SizedBox(height: Space.s24),
          AppButton(
            label: l10n.addToOrder,
            expand: true,
            onPressed: () => Navigator.of(context).pop(
              DraftLine(
                variantId: chosen.id,
                name: product.name,
                label: chosen.label,
                unitPrice: chosen.price,
                quantity: _quantity,
                trackStock: product.trackStock,
                stockOnHand: product.trackStock ? chosen.stockOnHand : null,
                imagePath: product.images.firstOrNull?.path,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// − n + with bounds 1…[max] (BR-37: 1–999) and a soft warning above 20.
class QuantityStepper extends ConsumerWidget {
  const QuantityStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.max = maxLineQuantity,
    this.enabled = true,
  });

  final int value;
  final int max;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final digits = ref.watch(settingsProvider).digits;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: l10n.fieldQuantityOrder,
          value: '$value',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.outlined(
                tooltip: l10n.decrease,
                icon: const Icon(AppIcons.minus),
                onPressed: enabled && value > minLineQuantity
                    ? () => onChanged(value - 1)
                    : null,
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 56),
                child: Text(
                  count(value, digits),
                  textAlign: TextAlign.center,
                  style: context.type.numericTotal.copyWith(
                    color: p.textPrimary,
                  ),
                ),
              ),
              IconButton.outlined(
                tooltip: l10n.increase,
                icon: const Icon(AppIcons.plus),
                onPressed: enabled && value < max
                    ? () => onChanged(value + 1)
                    : null,
              ),
            ],
          ),
        ),
        if (value > largeQuantityWarning)
          Padding(
            padding: const EdgeInsets.only(top: Space.s4),
            child: Text(
              l10n.largeQuantityWarning,
              style: context.type.caption.copyWith(color: p.warningFg),
            ),
          ),
      ],
    );
  }
}
