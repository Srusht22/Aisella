import 'package:flutter/material.dart';

import '../../core/formatting/bidi.dart';
import '../icons/app_icons.dart';
import '../theme/theme_ext.dart';
import '../tokens/tokens.g.dart';

/// Search field (Phase 2 CMP-SearchField): sunken fill, magnifier at start,
/// clear at end. Typed text takes its direction from its own content.
class AppSearchField extends StatefulWidget {
  const AppSearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
    this.clearTooltip = 'Clear',
  });

  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  final String clearTooltip;

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) => TextField(
        controller: _controller,
        onChanged: widget.onChanged,
        textDirection: Bidi.detect(value.text),
        style: type.body.copyWith(color: p.textPrimary),
        cursorColor: p.brandPrimary,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: p.bgSunken,
          hintText: widget.hint,
          hintStyle: type.body.copyWith(color: p.textSecondary),
          prefixIcon: Icon(
            AppIcons.magnifyingGlass,
            size: Sizes.iconMd,
            color: p.textSecondary,
          ),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  tooltip: widget.clearTooltip,
                  icon: Icon(
                    AppIcons.x,
                    size: Sizes.iconMd,
                    color: p.textSecondary,
                  ),
                  onPressed: () {
                    _controller.clear();
                    widget.onChanged('');
                  },
                ),
          constraints: const BoxConstraints(
            minHeight: LayoutTokens.minTouchTarget,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Space.s12,
            vertical: Space.s12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            borderSide: BorderSide(color: p.borderFocus, width: Strokes.focus),
          ),
        ),
      ),
    );
  }
}

/// Text field with the label above (never a placeholder-only label),
/// helper/error below (Phase 2 CMP-TextField). When [autoDirection] is set the
/// text direction follows the typed content; [ltr] forces LTR (email, phone).
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    required this.label,
    this.controller,
    this.helper,
    this.error,
    this.ltr = false,
    this.maxLines = 1,
    this.keyboardType,
    this.onChanged,
  });

  final String label;
  final TextEditingController? controller;
  final String? helper;
  final String? error;
  final bool ltr;
  final int maxLines;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    final hasError = widget.error != null;
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.md),
      borderSide: BorderSide(color: color, width: width),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.label, style: type.label.copyWith(color: p.textSecondary)),
        const SizedBox(height: Space.s4),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => TextField(
            controller: _controller,
            onChanged: widget.onChanged,
            maxLines: widget.maxLines,
            keyboardType: widget.keyboardType,
            textDirection: widget.ltr
                ? TextDirection.ltr
                : Bidi.detect(value.text),
            style: type.body.copyWith(color: p.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: p.bgSurface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Space.s12,
                vertical: Space.s12,
              ),
              enabledBorder: border(
                hasError ? p.dangerFg : p.borderControl,
                hasError ? Strokes.focus : Strokes.control,
              ),
              focusedBorder: border(
                hasError ? p.dangerFg : p.borderFocus,
                Strokes.focus,
              ),
            ),
          ),
        ),
        if (hasError || widget.helper != null) ...[
          const SizedBox(height: Space.s4),
          Semantics(
            liveRegion: hasError,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasError) ...[
                  Icon(
                    AppIcons.warningCircle,
                    size: Sizes.iconSm,
                    color: p.dangerFg,
                  ),
                  const SizedBox(width: Space.s4),
                ],
                Expanded(
                  child: Text(
                    widget.error ?? widget.helper!,
                    style: type.caption.copyWith(
                      color: hasError ? p.dangerFg : p.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Segmented control for 2–4 exclusive options (Phase 2 CMP-SegmentedControl).
class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.bgSunken,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.s2),
        child: Row(
          children: [
            for (final (value, label) in options)
              Expanded(
                child: Semantics(
                  selected: value == selected,
                  button: true,
                  inMutuallyExclusiveGroup: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(value),
                    child: AnimatedContainer(
                      duration: MotionTokens.sm,
                      curve: MotionTokens.standard,
                      constraints: const BoxConstraints(minHeight: 44),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.s8,
                        vertical: Space.s8,
                      ),
                      decoration: BoxDecoration(
                        color: value == selected ? p.bgSurface : null,
                        borderRadius: BorderRadius.circular(Radii.md - 2),
                        border: value == selected
                            ? Border.all(
                                color: p.borderHairline,
                                width: Strokes.hairline,
                              )
                            : null,
                      ),
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: type.label.copyWith(
                          color: value == selected
                              ? p.textPrimary
                              : p.textSecondary,
                          fontWeight: value == selected
                              ? FontWeight.w600
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Horizontally scrolling single-select filter chips (Phase 2 CMP-FilterChipRow).
class FilterChipRow<T> extends StatelessWidget {
  const FilterChipRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (value, label) in options)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: Space.s8),
              child: Semantics(
                selected: value == selected,
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(value),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: LayoutTokens.minTouchTarget,
                    ),
                    child: Center(
                      child: AnimatedContainer(
                        duration: MotionTokens.sm,
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.s12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: value == selected
                              ? p.bgBrandWeak
                              : p.bgSurface,
                          borderRadius: BorderRadius.circular(Radii.sm),
                          border: Border.all(
                            color: value == selected
                                ? p.bgBrandWeak
                                : p.borderHairline,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AnimatedSize(
                              duration: MotionTokens.sm,
                              child: value == selected
                                  ? Padding(
                                      padding: const EdgeInsetsDirectional.only(
                                        end: Space.s4,
                                      ),
                                      child: Icon(
                                        AppIcons.check,
                                        size: Sizes.iconSm,
                                        color: p.textBrand,
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            Text(
                              label,
                              style: type.label.copyWith(
                                color: value == selected
                                    ? p.textBrand
                                    : p.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Radio-style selection row (Phase 2 CMP-SelectionRow).
class SelectionRow extends StatelessWidget {
  const SelectionRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.description,
    this.labelDirection,
  });

  final String label;
  final String? description;
  final bool selected;
  final VoidCallback onTap;

  /// Forces the label's own direction (e.g. each language name rendered in
  /// its own script direction on the language picker).
  final TextDirection? labelDirection;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.s12,
              vertical: Space.s8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        textDirection: labelDirection,
                        style: type.bodyLarge.copyWith(color: p.textPrimary),
                      ),
                      if (description != null)
                        Text(
                          description!,
                          style: type.caption.copyWith(color: p.textSecondary),
                        ),
                    ],
                  ),
                ),
                AnimatedContainer(
                  duration: MotionTokens.sm,
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? p.brandPrimary : p.borderControl,
                      width: selected ? 7 : Strokes.control * 2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
