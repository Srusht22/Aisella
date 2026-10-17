import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/motion/primitives.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../application/catalog_providers.dart';
import '../domain/catalog.dart';
import '../domain/product_draft.dart';
import 'catalog_text.dart';

/// Opens PR-05 for [variant]. On success the sheet closes and a snackbar
/// states the confirmed result ("Stock updated · 12 → 15").
Future<void> showAdjustStockSheet(
  BuildContext context, {
  required Product product,
  required Variant variant,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final result = await showAppSheet<StockAdjustment>(
    context: context,
    title: l10n.adjustStockTitle,
    builder: (_) => AdjustStockForm(product: product, variant: variant),
  );
  if (result != null && context.mounted) {
    final container = ProviderScope.containerOf(context, listen: false);
    final digits = container.read(settingsProvider).digits;
    showSnackOn(
      messenger,
      l10n.stockUpdated(
        count(result.previousStock, digits),
        count(result.stockOnHand, digits),
      ),
    );
  }
}

class AdjustStockForm extends ConsumerStatefulWidget {
  const AdjustStockForm({
    super.key,
    required this.product,
    required this.variant,
  });

  final Product product;
  final Variant variant;

  @override
  ConsumerState<AdjustStockForm> createState() => _AdjustStockFormState();
}

class _AdjustStockFormState extends ConsumerState<AdjustStockForm> {
  final _quantity = TextEditingController();
  final _note = TextEditingController();
  final _intent = IntentKey();
  AdjustMode _mode = AdjustMode.add;
  StockReason? _reason;
  late int _current = widget.variant.stockOnHand;
  bool _busy = false;
  bool _submitted = false;
  String? _error;

  @override
  void dispose() {
    _quantity.dispose();
    _note.dispose();
    super.dispose();
  }

  int? get _qty => parseWholeNumber(
    _quantity.text,
    min: _mode == AdjustMode.set ? 0 : 1,
    max: maxStock,
  ).$1;

  int? get _result => adjustmentResult(_mode, _current, _qty);

  String? _quantityIssue(AppLocalizations l10n) {
    final digits = ref.read(settingsProvider).digits;
    if (_quantity.text.trim().isEmpty) {
      return _submitted ? l10n.errQuantityInvalid : null;
    }
    final result = _result;
    if (_qty == null || result == null) return l10n.errQuantityInvalid;
    if (result < 0) return l10n.errOnlyInStock(count(_current, digits));
    if (result > maxStock) return l10n.errQuantityInvalid;
    if (result == _current) return l10n.errNoChange;
    return null;
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    setState(() {
      _submitted = true;
      _error = null;
    });
    final issue = _quantityIssue(l10n);
    final note = _note.text.trim();
    if (issue != null ||
        _reason == null ||
        (_reason == StockReason.other && note.isEmpty) ||
        _busy) {
      return;
    }
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final qty = _qty!;
    try {
      final result = await ref
          .read(catalogActionsProvider)
          .adjustStock(
            productId: widget.product.id,
            variantId: widget.variant.id,
            mode: _mode,
            quantity: qty,
            reason: _reason!,
            note: note.isEmpty ? null : note,
            expectedStock: _current,
            idempotencyKey: _intent.forPayload(
              '${_mode.name}/$qty/${_reason!.wire}/$note/$_current',
            ),
          );
      navigator.pop(result);
    } on ApiException catch (e) {
      if (!mounted) return;
      final digits = ref.read(settingsProvider).digits;
      setState(() {
        _busy = false;
        // Someone else changed the stock: show the real number and let the
        // seller decide again (the preview recalculates).
        if (e.currentStock != null &&
            (e.code == ApiErrorCode.stockChanged ||
                e.code == ApiErrorCode.insufficientStock)) {
          _current = e.currentStock!;
        }
        _error = catalogErrorText(l10n, e, digits: digits);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final result = _result;
    final issue = _quantityIssue(l10n);
    final name = widget.product.hasOptions
        ? '${widget.product.name} · ${widget.variant.label}'
        : widget.product.name;
    final noteMissing =
        _submitted && _reason == StockReason.other && _note.text.trim().isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          textDirection: Bidi.detect(name),
          style: type.bodyStrong.copyWith(color: p.textPrimary),
        ),
        const SizedBox(height: Space.s16),
        if (_error != null) ...[
          AppBanner(
            tone: Tone.danger,
            icon: AppIcons.warningCircle,
            title: _error!,
          ),
          const SizedBox(height: Space.s12),
        ],
        AppSegmented<AdjustMode>(
          options: [
            (AdjustMode.add, l10n.modeAdd),
            (AdjustMode.remove, l10n.modeRemove),
            (AdjustMode.set, l10n.modeSet),
          ],
          selected: _mode,
          onChanged: _busy ? (_) {} : (m) => setState(() => _mode = m),
        ),
        const SizedBox(height: Space.s16),
        AppTextField(
          label: _mode == AdjustMode.set
              ? l10n.fieldNewCount
              : l10n.fieldAdjustQuantity,
          controller: _quantity,
          ltr: true,
          keyboardType: TextInputType.number,
          enabled: !_busy,
          error: issue,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.s16),
        Text(
          l10n.reasonTitle,
          style: type.label.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: Space.s8),
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s8,
          children: [
            for (final r in StockReason.manual)
              ChoiceChip(
                label: Text(reasonLabel(l10n, r)),
                selected: _reason == r,
                showCheckmark: false,
                onSelected: _busy ? null : (_) => setState(() => _reason = r),
              ),
          ],
        ),
        if (_submitted && _reason == null) ...[
          const SizedBox(height: Space.s4),
          Text(
            l10n.errReasonRequired,
            style: type.caption.copyWith(color: p.dangerFgOnBg),
          ),
        ],
        const SizedBox(height: Space.s12),
        AppTextField(
          label: l10n.fieldNote,
          controller: _note,
          enabled: !_busy,
          error: noteMissing ? l10n.errNoteRequired : null,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.s16),
        // Result preview "12 → 15" (numeric.metric, number roll).
        Semantics(
          liveRegion: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: p.bgSunken,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Padding(
              padding: const EdgeInsets.all(Space.s12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.stockAfter,
                      style: type.label.copyWith(color: p.textSecondary),
                    ),
                  ),
                  Text(
                    count(_current, digits),
                    style: type.numericMetric.copyWith(color: p.textSecondary),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.s8),
                    child: Icon(
                      AppIcons.arrowRight,
                      size: Sizes.iconMd,
                      color: p.textTertiary,
                    ),
                  ),
                  NumberRoll(
                    value: result ?? _current,
                    text: result == null || result < 0
                        ? '–'
                        : count(result, digits),
                    style: type.numericMetric.copyWith(color: p.textPrimary),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.saveAdjustment,
          expand: true,
          loading: _busy,
          onPressed: _save,
        ),
      ],
    );
  }
}
