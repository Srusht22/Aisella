import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatting/bidi.dart';
import '../../core/l10n/l10n.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../fulfilment/application/fulfilment_providers.dart';

/// Picks one of the store's active couriers (or none yet).
class CourierPicker extends ConsumerWidget {
  const CourierPicker({
    super.key,
    required this.selected,
    required this.onChanged,
    this.allowNone = true,
  });

  final String? selected;
  final ValueChanged<String?>? onChanged;
  final bool allowNone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final couriers = ref.watch(couriersProvider(false)).value ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.fieldCourier, style: context.type.label),
        const SizedBox(height: Space.s4),
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s4,
          children: [
            if (allowNone)
              ChoiceChip(
                label: Text(l10n.noCourierYet),
                selected: selected == null,
                showCheckmark: false,
                onSelected: onChanged == null ? null : (_) => onChanged!(null),
              ),
            for (final c in couriers)
              ChoiceChip(
                key: ValueKey('courier-${c.id}'),
                label: Text(Bidi.auto(c.name)),
                selected: selected == c.id,
                showCheckmark: false,
                onSelected: onChanged == null ? null : (_) => onChanged!(c.id),
              ),
          ],
        ),
        if (couriers.isEmpty)
          Text(
            l10n.noCouriersHint,
            style: context.type.caption.copyWith(
              color: context.palette.textSecondary,
            ),
          ),
      ],
    );
  }
}
