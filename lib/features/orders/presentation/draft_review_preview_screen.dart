import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/formatting/money.dart';
import '../../../core/formatting/phone.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/media.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/pencil.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/motion/primitives.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../data/sample_draft.dart';
import 'approve_sheet.dart';

/// OR-02 Draft review — DESIGN PREVIEW on sample data (Phase 2 §5).
///
/// Demonstrates the approval experience: pencil treatment, provenance,
/// issue summary, disabled Approve with a reason, two-step confirmation.
/// Nothing is persisted; Approve and Reject report honestly that they are
/// not connected (Phase 4 §11).
class DraftReviewPreviewScreen extends ConsumerStatefulWidget {
  const DraftReviewPreviewScreen({super.key});

  @override
  ConsumerState<DraftReviewPreviewScreen> createState() =>
      _DraftReviewPreviewScreenState();
}

class _DraftReviewPreviewScreenState
    extends ConsumerState<DraftReviewPreviewScreen> {
  bool _quantityConfirmed = false;
  final _itemsKey = GlobalKey();

  /// The control the reason line refers to is usually below the fold on a
  /// phone, so the reason line scrolls it into view.
  void _showItems() {
    final ctx = _itemsKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.3,
      duration: Motion.reduced(context) ? Duration.zero : MotionTokens.md,
      curve: MotionTokens.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    const d = sampleDraft;
    final digits = ref.watch(settingsProvider).digits;
    final locale = Localizations.localeOf(context);
    String money(int v) =>
        Money.format(v, d.currency, locale: locale, digits: digits);
    final number = Bidi.ltr('#${d.number}');
    final issues = _quantityConfirmed ? 0 : 1;

    return Scaffold(
      backgroundColor: p.bgCanvas,
      appBar: AppBar(
        title: Text(l10n.orderTitle(number)),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: Space.s16),
            child: Center(
              child: StatusBadge(
                label: l10n.statusNeedsApproval,
                icon: AppIcons.pencilSimple,
                tone: Tone.pencil,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.s24),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SampleDataBanner(),
                const SizedBox(height: Space.s16),
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
                              style: type.bodyStrong.copyWith(
                                color: p.textPrimary,
                              ),
                            ),
                            const SizedBox(height: Space.s2),
                            Text(
                              l10n.draftBannerBody(d.source),
                              style: type.label.copyWith(color: p.textPencil),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                ExpandSection(
                  expanded: issues > 0,
                  child: Padding(
                    padding: const EdgeInsets.only(top: Space.s12),
                    child: AppBanner(
                      tone: Tone.warning,
                      icon: AppIcons.warning,
                      title: l10n.issuesCount(issues),
                      body: l10n.issueInferredQuantity(
                        Bidi.auto(d.inferredFrom),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.sectionCustomer),
                RowGroup(
                  children: [
                    FieldRow(
                      label: l10n.fieldName,
                      value: PencilUnderline(
                        child: Text(Bidi.auto(d.customerName)),
                      ),
                      caption: ProvenanceCaption(
                        kind: Provenance.fromCustomer,
                        label: l10n.provFromCustomer,
                      ),
                    ),
                    FieldRow(
                      label: l10n.fieldPhone,
                      value: PencilUnderline(
                        child: Text(
                          PhoneNumbers.display(d.phoneE164),
                          style: type.numericBody,
                        ),
                      ),
                      caption: ProvenanceCaption(
                        kind: Provenance.fromCustomer,
                        label: l10n.provFromCustomer,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.sectionDelivery),
                RowGroup(
                  children: [
                    FieldRow(
                      label: l10n.fieldCity,
                      value: Text(
                        '${Bidi.auto(d.city)} · ${Bidi.auto(d.area)}',
                      ),
                      caption: ProvenanceCaption(
                        kind: Provenance.settings,
                        label: l10n.provFromSettings,
                      ),
                    ),
                    FieldRow(
                      label: l10n.fieldLandmark,
                      value: Text(
                        l10n.notProvidedOptional,
                        style: type.body.copyWith(color: p.textTertiary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.sectionItems),
                RowGroup(
                  key: _itemsKey,
                  children: [_line(context, d, digits, money)],
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.sectionTotal),
                RowGroup(
                  children: [
                    _PriceRow(label: l10n.subtotal, amount: money(d.subtotal)),
                    _PriceRow(
                      label: l10n.deliveryFee,
                      amount: money(d.deliveryFee),
                    ),
                    _PriceRow(
                      label: l10n.totalCashOnDelivery,
                      amount: money(d.total),
                      emphasize: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: StickyActionBar(
        reason: _quantityConfirmed
            ? null
            : Semantics(
                button: true,
                child: InkWell(
                  onTap: _showItems,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: LayoutTokens.minTouchTarget,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          AppIcons.info,
                          size: Sizes.iconSm,
                          color: p.warningFg,
                        ),
                        const SizedBox(width: Space.s4),
                        Expanded(
                          child: Text(
                            l10n.reasonConfirmQuantity,
                            style: type.caption.copyWith(color: p.warningFg),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        secondary: AppButton(
          label: l10n.reject,
          variant: AppButtonVariant.dangerOutline,
          onPressed: () => showConfirmDialog(
            context: context,
            title: l10n.previewNotConnectedTitle,
            body: l10n.previewRejectNotConnected,
            confirmLabel: l10n.close,
            cancelLabel: l10n.back,
          ),
        ),
        primary: AppButton(
          label: l10n.approveOrder,
          onPressed: _quantityConfirmed
              ? () => showApproveSheet(context, draft: d)
              : null,
        ),
      ),
    );
  }

  Widget _line(
    BuildContext context,
    SampleDraft d,
    DigitStyle digits,
    String Function(int) money,
  ) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final qty = Digits.display('${d.quantity}', digits);
    return Padding(
      padding: const EdgeInsets.all(Space.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ProductThumbnail(size: Sizes.thumbRow),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Bidi.auto(d.productName),
                  style: type.bodyStrong.copyWith(color: p.textPrimary),
                ),
                const SizedBox(height: Space.s2),
                Wrap(
                  spacing: Space.s8,
                  children: [
                    Text(
                      l10n.sizeValue(Bidi.auto(d.size)),
                      style: type.caption.copyWith(color: p.textSecondary),
                    ),
                    StockIndicator(
                      state: StockState.inStock,
                      label: l10n.stockInStock(
                        Digits.display('${d.stock}', digits),
                      ),
                      emphasizeAvailable: true,
                    ),
                  ],
                ),
                const SizedBox(height: Space.s8),
                AnimatedSwitcher(
                  duration: MotionTokens.sm,
                  child: _quantityConfirmed
                      ? Column(
                          key: const ValueKey('confirmed'),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.quantityShort(qty),
                              style: type.body.copyWith(color: p.textPrimary),
                            ),
                            ProvenanceCaption(
                              kind: Provenance.editedByYou,
                              label: l10n.provEditedByYou,
                            ),
                          ],
                        )
                      : Wrap(
                          key: const ValueKey('inferred'),
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: Space.s8,
                          runSpacing: Space.s4,
                          children: [
                            StatusBadge(
                              label:
                                  '${l10n.quantityShort(qty)} · ${l10n.provInferred}',
                              icon: AppIcons.question,
                              tone: Tone.warning,
                            ),
                            AppButton(
                              label: l10n.confirm,
                              variant: AppButtonVariant.tertiary,
                              onPressed: () =>
                                  setState(() => _quantityConfirmed = true),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.s8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                money(d.unitPrice),
                style: type.numericBody.copyWith(color: p.textPrimary),
              ),
              ProvenanceCaption(
                kind: Provenance.catalog,
                label: l10n.provCatalogPrice,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Label + amount; the label wraps, the amount is never truncated
/// (Phase 2 CMP-PriceRow; concept-board fix).
class _PriceRow extends StatelessWidget {
  const _PriceRow({
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
