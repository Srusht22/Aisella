import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../components/app_button.dart';
import '../components/feedback.dart';
import '../components/inputs.dart';
import '../components/overlays.dart';
import '../components/pencil.dart';
import '../components/rows.dart';
import '../components/status.dart';
import '../icons/app_icons.dart';
import '../layout/responsive.dart';
import '../motion/primitives.dart';
import '../theme/theme_ext.dart';
import '../tokens/tokens.g.dart';

/// Debug-only component gallery (Phase 2 §09 §8): every component in its
/// states, in the active direction and theme. Not reachable in prod builds.
/// Labels here are developer-facing and intentionally not localised.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  int _count = 4;
  bool _settled = false;
  bool _loading = false;
  bool _expanded = true;
  int _segment = 0;
  String _chip = 'all';

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: Space.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [SectionHeader(title), ...children],
      ),
    );
    const gap = SizedBox(height: Space.s8);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.galleryTitle)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.s48),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                section('Buttons', [
                  AppButton(label: 'Primary', onPressed: () {}),
                  gap,
                  const AppButton(label: 'Primary disabled', onPressed: null),
                  gap,
                  AppButton(
                    label: 'Save',
                    loadingLabel: 'Saving…',
                    loading: _loading,
                    onPressed: () => setState(() => _loading = !_loading),
                  ),
                  gap,
                  AppButton(
                    label: 'Secondary',
                    variant: AppButtonVariant.secondary,
                    onPressed: () {},
                  ),
                  gap,
                  AppButton(
                    label: 'Tertiary',
                    variant: AppButtonVariant.tertiary,
                    onPressed: () {},
                  ),
                  gap,
                  AppButton(
                    label: 'Reject',
                    variant: AppButtonVariant.dangerOutline,
                    onPressed: () {},
                  ),
                  gap,
                  AppButton(
                    label: 'Delete account',
                    variant: AppButtonVariant.danger,
                    onPressed: () {},
                  ),
                ]),
                section('Status badges', [
                  const Wrap(
                    spacing: Space.s8,
                    runSpacing: Space.s8,
                    children: [
                      StatusBadge(
                        label: 'Draft',
                        icon: AppIcons.pencilSimple,
                        tone: Tone.pencil,
                      ),
                      StatusBadge(
                        label: 'Approved',
                        icon: AppIcons.sealCheck,
                        tone: Tone.info,
                      ),
                      StatusBadge(
                        label: 'Delivered',
                        icon: AppIcons.checkCircle,
                        tone: Tone.success,
                      ),
                      StatusBadge(
                        label: 'Delivery failed',
                        icon: AppIcons.warningCircle,
                        tone: Tone.warning,
                      ),
                      StatusBadge(label: 'Cancelled', icon: AppIcons.xCircle),
                      StatusBadge(label: 'Test', icon: AppIcons.flask),
                    ],
                  ),
                  gap,
                  const Wrap(
                    spacing: Space.s16,
                    children: [
                      StockIndicator(
                        state: StockState.inStock,
                        label: '12 in stock',
                      ),
                      StockIndicator(
                        state: StockState.low,
                        label: 'Low · 2 left',
                      ),
                      StockIndicator(
                        state: StockState.out,
                        label: 'Out of stock',
                      ),
                    ],
                  ),
                ]),
                section('Provenance', [
                  const ProvenanceCaption(
                    kind: Provenance.fromCustomer,
                    label: 'From customer',
                  ),
                  const ProvenanceCaption(
                    kind: Provenance.catalog,
                    label: 'Catalog price',
                  ),
                  const ProvenanceCaption(
                    kind: Provenance.inferred,
                    label: 'Inferred — confirm',
                  ),
                  const ProvenanceCaption(
                    kind: Provenance.editedByYou,
                    label: 'Edited by you',
                  ),
                  gap,
                  const PencilUnderline(child: Text('Nzar Ahmad (sample)')),
                ]),
                section('Banners', [
                  const SampleDataBanner(),
                  gap,
                  const AppBanner(
                    tone: Tone.warning,
                    icon: AppIcons.warning,
                    title: '1 thing to check',
                    body: 'Quantity was inferred.',
                  ),
                  gap,
                  const AppBanner(
                    tone: Tone.danger,
                    icon: AppIcons.warningCircle,
                    title: 'Not approved',
                    body: '1 item doesn\'t have enough stock.',
                  ),
                  gap,
                  const AppBanner(
                    tone: Tone.neutral,
                    icon: AppIcons.cloudSlash,
                    title: 'You\'re offline.',
                  ),
                ]),
                section('Inputs', [
                  AppSearchField(
                    hint: 'Search products by name or SKU',
                    onChanged: (_) {},
                  ),
                  gap,
                  const AppTextField(
                    label: 'Price',
                    helper: 'Whole dinars only.',
                  ),
                  gap,
                  const AppTextField(
                    label: 'Phone',
                    ltr: true,
                    error: 'Enter a valid Iraqi mobile number.',
                  ),
                  gap,
                  AppSegmented<int>(
                    options: const [
                      (0, 'Today'),
                      (1, '7 days'),
                      (2, 'This month'),
                    ],
                    selected: _segment,
                    onChanged: (v) => setState(() => _segment = v),
                  ),
                  gap,
                  FilterChipRow<String>(
                    options: const [
                      ('all', 'All'),
                      ('low', 'Low stock'),
                      ('out', 'Out of stock'),
                    ],
                    selected: _chip,
                    onSelected: (v) => setState(() => _chip = v),
                  ),
                ]),
                section('Motion', [
                  Row(
                    children: [
                      Text(
                        'Stock: ',
                        style: type.body.copyWith(color: p.textSecondary),
                      ),
                      NumberRoll(
                        value: _count,
                        text: '$_count',
                        style: type.numericTotal.copyWith(color: p.textPrimary),
                      ),
                      const Spacer(),
                      AppIconButton(
                        icon: AppIcons.minus,
                        tooltip: 'Decrease',
                        onPressed: () => setState(() => _count--),
                      ),
                      AppIconButton(
                        icon: AppIcons.plus,
                        tooltip: 'Increase',
                        onPressed: () => setState(() => _count++),
                      ),
                    ],
                  ),
                  gap,
                  PencilBox(
                    settled: _settled,
                    child: Text(
                      _settled
                          ? 'Ink (motion preview — not a real approval)'
                          : 'Pencil (AI proposal)',
                      style: type.body.copyWith(color: p.textPrimary),
                    ),
                  ),
                  gap,
                  AppButton(
                    label: 'Toggle ink settle preview',
                    variant: AppButtonVariant.secondary,
                    onPressed: () => setState(() => _settled = !_settled),
                  ),
                  gap,
                  AppButton(
                    label: _expanded ? 'Collapse' : 'Expand',
                    variant: AppButtonVariant.tertiary,
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                  ExpandSection(
                    expanded: _expanded,
                    child: const Padding(
                      padding: EdgeInsets.only(top: Space.s8),
                      child: Text('Expandable section content.'),
                    ),
                  ),
                ]),
                section('Overlays', [
                  AppButton(
                    label: 'Open sheet',
                    variant: AppButtonVariant.secondary,
                    onPressed: () => showAppSheet<void>(
                      context: context,
                      title: 'Sheet title',
                      builder: (_) => const Text(
                        'Bottom sheet content. Drag down to dismiss.',
                      ),
                    ),
                  ),
                  gap,
                  AppButton(
                    label: 'Open discard dialog',
                    variant: AppButtonVariant.secondary,
                    onPressed: () => confirmDiscard(context),
                  ),
                  gap,
                  AppButton(
                    label: 'Show snackbar',
                    variant: AppButtonVariant.secondary,
                    onPressed: () =>
                        showAppSnackBar(context, 'Snackbar message'),
                  ),
                ]),
                section('States', [
                  const SizedBox(
                    height: 220,
                    child: Skeleton(
                      child: Column(
                        children: [
                          SkeletonBlock(height: 56),
                          SizedBox(height: 2),
                          SkeletonBlock(height: 56),
                        ],
                      ),
                    ),
                  ),
                  RowGroup(
                    children: [
                      ErrorState(
                        cause: 'Something went wrong on our side.',
                        reference: '7F3K-21',
                        onRetry: () {},
                      ),
                    ],
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
