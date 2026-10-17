import 'dart:async';

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
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import 'sample_draft.dart';

/// Time after presentation during which Confirm ignores taps, so a double
/// tap on Approve cannot pass through (Phase 2 §5.5).
const kApproveInputGuard = Duration(milliseconds: 400);

/// OR-03 approval confirmation (design preview). Restates what would be
/// committed. Confirm does NOT approve anything in Phase 4: it shows an honest
/// "not connected" result and leaves the draft unchanged.
Future<void> showApproveSheet(
  BuildContext context, {
  required SampleDraft draft,
}) {
  final number = Bidi.ltr('#${draft.number}');
  return showAppSheet<void>(
    context: context,
    title: context.l10n.approveSheetTitle(number),
    builder: (_) => _ApproveSheetBody(draft: draft),
  );
}

class _ApproveSheetBody extends ConsumerStatefulWidget {
  const _ApproveSheetBody({required this.draft});

  final SampleDraft draft;

  @override
  ConsumerState<_ApproveSheetBody> createState() => _ApproveSheetBodyState();
}

class _ApproveSheetBodyState extends ConsumerState<_ApproveSheetBody> {
  bool _armed = false;
  bool _attempted = false;
  Timer? _guard;

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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final d = widget.draft;
    final digits = ref.watch(settingsProvider).digits;
    final locale = Localizations.localeOf(context);
    String n(int v) => Digits.display('$v', digits);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${Bidi.auto(d.customerName)} · ${PhoneNumbers.display(d.phoneE164)}',
          style: type.body.copyWith(color: p.textPrimary),
        ),
        Text(
          '${Bidi.auto(d.city)} · ${Bidi.auto(d.area)}',
          style: type.label.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: Space.s12),
        Text(
          '${n(d.quantity)} × ${Bidi.auto(d.productName)} · ${Bidi.auto(d.size)}',
          style: type.body.copyWith(color: p.textPrimary),
        ),
        const SizedBox(height: Space.s12),
        Text(
          l10n.stockAfterApproval,
          style: type.label.copyWith(color: p.textSecondary),
        ),
        Text(
          '${Bidi.auto('${d.productName} · ${d.size}')}: ${Bidi.ltr('${n(d.stock)} → ${n(d.stock - d.quantity)}')}',
          style: type.numericBody.copyWith(color: p.textPrimary),
        ),
        const SizedBox(height: Space.s12),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.totalCashOnDelivery,
                style: type.bodyStrong.copyWith(color: p.textPrimary),
              ),
            ),
            Text(
              Money.format(d.total, d.currency, locale: locale, digits: digits),
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
        if (_attempted)
          AppBanner(
            tone: Tone.info,
            icon: AppIcons.info,
            title: l10n.previewNotConnectedTitle,
            body: l10n.previewApproveNotConnected,
          )
        else
          AppButton(
            label: l10n.confirmApproval,
            expand: true,
            onPressed: _armed ? () => setState(() => _attempted = true) : null,
          ),
        const SizedBox(height: Space.s8),
        AppButton(
          label: _attempted ? l10n.close : l10n.back,
          variant: AppButtonVariant.tertiary,
          expand: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
