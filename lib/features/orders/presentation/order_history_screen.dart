import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/phone.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../application/order_providers.dart';
import '../domain/order.dart';
import 'order_text.dart';

/// OR-11 Order history: status changes, edits (before → after), notes,
/// cash and confirmation marks, oldest first. Read-only; never empty
/// (creation is always an event).
class OrderHistoryScreen extends ConsumerWidget {
  const OrderHistoryScreen({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final history = ref.watch(orderHistoryProvider(orderId));
    final number = ref.watch(orderProvider(orderId)).value?.number;
    return Scaffold(
      backgroundColor: p.bgCanvas,
      appBar: AppBar(
        title: Text(
          number == null
              ? l10n.fullHistory
              : l10n.historyTitle(orderNumber(number)),
        ),
      ),
      body: switch (history) {
        AsyncData(:final value) => ListView(
          padding: const EdgeInsets.symmetric(vertical: Space.s16),
          children: [
            ContentWidth(
              maxWidth: LayoutTokens.maxWidthForm,
              child: RowGroup(
                children: [for (final e in value) _Entry(entry: e)],
              ),
            ),
          ],
        ),
        AsyncError(:final error) => ErrorState(
          cause: orderLoadErrorText(l10n, error),
          onRetry: () => ref.invalidate(orderHistoryProvider(orderId)),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _Entry extends ConsumerWidget {
  const _Entry({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final locale = Localizations.localeOf(context);
    final e = entry;
    final who = switch (e.actor) {
      Actor.you => l10n.actorYou,
      Actor.member => l10n.actorMember,
      Actor.system => l10n.actorSystem,
      Actor.ai => l10n.actorAi,
    };
    final (IconData icon, String title) = switch (e.kind) {
      HistoryKind.status => (
        statusLook(e.to!).$1,
        e.from == null
            ? l10n.eventCreated(statusLabel(l10n, e.to!))
            : l10n.eventFromTo(
                statusLabel(l10n, e.from!),
                statusLabel(l10n, e.to!),
              ),
      ),
      HistoryKind.edit => (AppIcons.pencilSimple, l10n.eventEdited),
      HistoryKind.note => (AppIcons.chatText, l10n.eventNote),
      HistoryKind.cash => (AppIcons.money, l10n.eventCash),
      HistoryKind.confirmation => (AppIcons.copy, l10n.markedSentByYou),
    };
    final details = <String>[
      if (e.reason != null) reasonText(l10n, e.reason),
      if (e.note != null) Bidi.auto(e.note!),
      if (e.kind == HistoryKind.edit || e.kind == HistoryKind.note)
        for (final f in e.changedFields)
          '${fieldName(l10n, f)}: ${_value(l10n, f, e.before[f])} → ${_value(l10n, f, e.after[f])}',
    ];
    return Padding(
      padding: const EdgeInsets.all(Space.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: Sizes.iconMd, color: p.textSecondary),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: type.bodyStrong.copyWith(color: p.textPrimary),
                ),
                Text(
                  '$who · ${Dates.dayMonthYear(e.createdAt, locale: locale, digits: digits)} · ${Dates.time(e.createdAt, digits: digits)}',
                  style: type.caption.copyWith(color: p.textSecondary),
                ),
                for (final d in details)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.s2),
                    child: Text(
                      d,
                      style: type.label.copyWith(color: p.textPrimary),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _value(AppLocalizations l10n, String field, Object? v) {
    if (v == null || v == '') return '—';
    if (field == 'lines' && v is List) {
      return v
          .whereType<Map<String, dynamic>>()
          .map(
            (l) =>
                '${l['quantity']} × ${itemName('${l['name']}', '${l['variant_label'] ?? ''}')}',
          )
          .join(', ');
    }
    if (field.endsWith('phone') || field.endsWith('phone2')) {
      return PhoneNumbers.display('$v');
    }
    return Bidi.auto('$v');
  }
}

/// Field names in edit history entries.
String fieldName(AppLocalizations l10n, String field) => switch (field) {
  'customer_name' => l10n.fieldName,
  'customer_phone' => l10n.fieldPhone,
  'customer_phone2' => l10n.fieldPhone2,
  'zone_name' => l10n.fieldZone,
  'city_text' => l10n.fieldCity,
  'area' => l10n.fieldArea,
  'landmark' => l10n.fieldLandmark,
  'address_details' => l10n.fieldAddressDetails,
  'delivery_fee' => l10n.deliveryFee,
  'payment_method' => l10n.fieldPaymentMethod,
  'payment_note' => l10n.fieldPaymentNote,
  'discount' => l10n.discount,
  'customer_note' => l10n.fieldCustomerNote,
  'internal_note' => l10n.internalNote,
  'lines' => l10n.sectionItems,
  _ => field,
};
