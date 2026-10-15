import 'package:flutter/material.dart';

import '../../design_system/components/overlays.dart';
import '../../design_system/layout/responsive.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';

/// Layout for single-task forms (auth, store setup, settings editors):
/// a centred column at form width (Phase 2: max 560 dp) that scrolls, and a
/// sticky action bar that stays above the keyboard.
class FormPage extends StatelessWidget {
  const FormPage({
    super.key,
    required this.children,
    this.title,
    this.actions,
    this.showBack = true,
    this.bottom,
    this.appBarBottom,
  });

  final String? title;
  final List<Widget> children;
  final List<Widget>? actions;

  /// Whether the app bar shows a Back button when the route can pop.
  final bool showBack;

  /// Sticky bottom actions, usually a [StickyActionBar].
  final Widget? bottom;

  /// Below the app bar, for example a setup progress bar.
  final PreferredSizeWidget? appBarBottom;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      backgroundColor: p.bgCanvas,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        automaticallyImplyLeading: showBack,
        title: title == null ? null : Text(title!),
        actions: actions,
        bottom: appBarBottom,
      ),
      body: ListView(
        padding: EdgeInsets.only(top: Space.s8, bottom: Space.s32 + insets),
        children: [
          ContentWidth(
            maxWidth: LayoutTokens.maxWidthForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
      bottomNavigationBar: bottom == null
          ? null
          : Padding(
              padding: EdgeInsets.only(bottom: insets),
              child: bottom,
            ),
    );
  }
}

/// A primary action bar with an optional secondary button.
StickyActionBar formActions({required Widget primary, Widget? secondary}) =>
    StickyActionBar(primary: primary, secondary: secondary);
