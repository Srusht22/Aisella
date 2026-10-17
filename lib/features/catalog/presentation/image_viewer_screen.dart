import 'package:flutter/material.dart';

import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/tokens/tokens.g.dart';
import 'catalog_widgets.dart';

/// What the seller chose in the editor's image viewer (PR-07).
enum ImageAction { setAsMain, replace, remove }

/// PR-07 full-screen viewer with pinch to zoom. From the editor it offers
/// Set as main, Replace and Remove (with confirmation); from the product
/// page it is view-only.
class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({
    super.key,
    required this.paths,
    this.initialIndex = 0,
    this.editable = false,
  });

  final List<String> paths;
  final int initialIndex;
  final bool editable;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _remove() async {
    final l10n = context.l10n;
    final navigator = Navigator.of(context);
    final ok = await showConfirmDialog(
      context: context,
      title: l10n.removePhotoTitle,
      body: l10n.removePhotoBody,
      confirmLabel: l10n.removePhoto,
      cancelLabel: l10n.cancel,
      destructive: true,
    );
    if (ok) navigator.pop((_index, ImageAction.remove));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(l10n.photoCount(_index + 1, widget.paths.length)),
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.paths.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => InteractiveViewer(
          maxScale: 4,
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: ProductImage(
                path: widget.paths[i],
                size: null,
                radius: 0,
                showFailureCaption: true,
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: widget.editable
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(Space.s8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (_index > 0)
                      _Action(
                        icon: AppIcons.sealCheck,
                        label: l10n.setAsMain,
                        onTap: () =>
                            Navigator.of(context)
                                .pop((_index, ImageAction.setAsMain)),
                      ),
                    _Action(
                      icon: AppIcons.camera,
                      label: l10n.replacePhoto,
                      onTap: () =>
                          Navigator.of(context)
                              .pop((_index, ImageAction.replace)),
                    ),
                    _Action(
                      icon: AppIcons.trash,
                      label: l10n.removePhoto,
                      onTap: _remove,
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    style: TextButton.styleFrom(foregroundColor: Colors.white),
    onPressed: onTap,
    icon: Icon(icon, size: Sizes.iconMd),
    label: Text(label),
  );
}
