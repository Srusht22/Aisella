import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/l10n/l10n.dart';
import '../../design_system/components/media.dart';
import '../../design_system/layout/responsive.dart';
import '../../design_system/motion/motion.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../store/application/workspace_controller.dart';

/// Scaffold for the four tab roots: a large title that scrolls away and
/// reappears in a compact pinned bar, with the store button at the end
/// (Phase 2 IA §1, CMP AppBar.large).
///
/// Material's large app bar fixes its expanded title at 16 dp from the edge,
/// which cannot line up with the centred content column on tablets, so the
/// large title is a content row inside [ContentWidth] and the compact title
/// uses the same start inset.
class TopLevelPage extends ConsumerStatefulWidget {
  const TopLevelPage({
    super.key,
    required this.title,
    required this.slivers,
    this.subtitle,
    this.floatingActionButton,
    this.contentMaxWidth = LayoutTokens.maxWidthReading,
  });

  final String title;
  final String? subtitle;
  final List<Widget> slivers;
  final Widget? floatingActionButton;

  /// Must match the [ContentWidth] the slivers use, so the title aligns.
  final double contentMaxWidth;

  @override
  ConsumerState<TopLevelPage> createState() => _TopLevelPageState();
}

/// Material's extended FAB height (56) plus its 16 dp margin.
const _fabClearance = 56.0 + Space.s16;

class _TopLevelPageState extends ConsumerState<TopLevelPage> {
  /// Scroll offset after which the large title has left the screen.
  static const _collapseAt = 40.0;
  bool _collapsed = false;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final collapsed = n.metrics.pixels > _collapseAt;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    final l10n = context.l10n;
    final storeName = ref.watch(
      workspaceProvider.select((w) => w.value?.store?.name),
    );
    final gutter = WindowClass.of(context).gutter;
    final fade = Motion.fade(context, MotionTokens.sm);

    return Scaffold(
      backgroundColor: p.bgCanvas,
      floatingActionButton: widget.floatingActionButton,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final inset = ContentWidth.startInset(
            constraints.maxWidth,
            gutter: gutter,
            maxWidth: widget.contentMaxWidth,
          );
          return NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  backgroundColor: p.bgCanvas,
                  surfaceTintColor: Colors.transparent,
                  automaticallyImplyLeading: false,
                  titleSpacing: inset,
                  // The large title below is the heading for assistive
                  // technology; this compact copy is decorative.
                  title: ExcludeSemantics(
                    child: AnimatedOpacity(
                      opacity: _collapsed ? 1 : 0,
                      duration: fade,
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  actions: [
                    StoreButton(
                      initials: storeName == null || storeName.isEmpty
                          ? null
                          : storeName.characters.first,
                      tooltip: l10n.storeMenuTooltip,
                      onPressed: () => context.push(Routes.store),
                    ),
                    SizedBox(width: (inset - Space.s8).clamp(Space.s8, inset)),
                  ],
                ),
                SliverToBoxAdapter(
                  child: ContentWidth(
                    maxWidth: widget.contentMaxWidth,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        top: Space.s4,
                        bottom: Space.s16,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              widget.title,
                              style: type.titleLarge.copyWith(
                                color: p.textPrimary,
                              ),
                            ),
                          ),
                          if (widget.subtitle case final subtitle?) ...[
                            const SizedBox(height: Space.s4),
                            Text(
                              subtitle,
                              style: type.label.copyWith(
                                color: p.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                ...widget.slivers,
                // Clearance so a floating action button never hides the
                // last row.
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: widget.floatingActionButton == null
                        ? Space.s32
                        : Space.s32 + _fabClearance,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
