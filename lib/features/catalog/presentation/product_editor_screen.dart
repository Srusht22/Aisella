import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/money.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/primitives.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../store/domain/store_validation.dart' show FieldIssue;
import '../application/catalog_providers.dart';
import '../domain/catalog.dart';
import '../domain/product_draft.dart';
import 'catalog_text.dart';
import 'catalog_widgets.dart';
import 'image_viewer_screen.dart';

/// PR-03 Product editor. [productId] null creates a product; the new id is
/// chosen here so photos can upload before the first save.
class ProductEditorScreen extends ConsumerWidget {
  const ProductEditorScreen({super.key, this.productId});

  final String? productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = productId;
    if (id == null) return const _Editor(product: null);
    final product = ref.watch(productProvider(id));
    return switch (product) {
      AsyncData(:final value) => _Editor(
        key: ValueKey(value.version),
        product: value,
      ),
      AsyncError(:final error) => Scaffold(
        appBar: AppBar(),
        body: ErrorState(
          cause: loadErrorText(context.l10n, error),
          onRetry: () => ref.invalidate(productProvider(id)),
        ),
      ),
      _ => Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      ),
    };
  }
}

enum _PhotoState { uploading, uploaded, failed }

class _Photo {
  _Photo.uploaded(this.path) : state = _PhotoState.uploaded, source = null;
  _Photo.uploading(Uint8List this.source)
    : state = _PhotoState.uploading,
      path = null;

  String? path;
  Uint8List? source;
  _PhotoState state;
}

class _VariantFields {
  _VariantFields(VariantDraft v, {required bool isNew})
    : price = TextEditingController(
        text: v.priceOverride == null ? '' : '${v.priceOverride}',
      ),
      sku = TextEditingController(text: v.sku),
      stock = TextEditingController(
        text: isNew && v.initialStock > 0 ? '${v.initialStock}' : '',
      );

  final TextEditingController price;
  final TextEditingController sku;
  final TextEditingController stock;

  void dispose() {
    price.dispose();
    sku.dispose();
    stock.dispose();
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({super.key, required this.product});

  /// Null when creating.
  final Product? product;

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  late final String _productId = widget.product?.id ?? newIdempotencyKey();
  late final CatalogActions _actions = ref.read(catalogActionsProvider);
  late ProductDraft _draft = widget.product == null
      ? const ProductDraft()
      : ProductDraft.fromProduct(widget.product!);
  late final String _initial = _draft.canonical;

  late final _name = TextEditingController(text: _draft.name);
  late final _description = TextEditingController(text: _draft.description);
  late final _category = TextEditingController(text: _draft.category);
  late final _price = TextEditingController(
    text: _draft.basePrice == null ? '' : '${_draft.basePrice}',
  );
  late final _quantity = TextEditingController();
  late final _threshold = TextEditingController(text: _commonThreshold());
  final _optionNames = <TextEditingController>[];
  final _newValues = <TextEditingController>[];
  final _variantFields = <String, _VariantFields>{};
  final _priceForAll = TextEditingController();
  final _stockForAll = TextEditingController();

  late final List<_Photo> _photos = [
    for (final p in _draft.images) _Photo.uploaded(p),
  ];

  /// Paths uploaded during this editing session; removed again unless saved.
  final _sessionUploads = <String>{};
  final _removedCombos = <String>{};
  final _intent = IntentKey();
  Map<String, FieldIssue> _issues = const {};
  String? _error;
  bool _busy = false;
  bool _saved = false;

  bool get _isNew => widget.product == null;

  @override
  void initState() {
    super.initState();
    for (final t in _draft.optionTypes) {
      _optionNames.add(TextEditingController(text: t.name));
      _newValues.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _description,
      _category,
      _price,
      _quantity,
      _threshold,
      _priceForAll,
      _stockForAll,
      ..._optionNames,
      ..._newValues,
    ]) {
      c.dispose();
    }
    for (final f in _variantFields.values) {
      f.dispose();
    }
    // Photos uploaded here but not saved with the product are removed.
    final saved = _saved ? _draft.images.toSet() : const <String>{};
    final abandoned = _sessionUploads.difference(saved).toList();
    if (abandoned.isNotEmpty) unawaited(_actions.discardUploads(abandoned));
    super.dispose();
  }

  String _commonThreshold() {
    final values = {for (final v in _draft.activeVariants) v.lowStockThreshold};
    return values.length == 1 && values.single != null
        ? '${values.single}'
        : '';
  }

  _VariantFields _fieldsFor(VariantDraft v) => _variantFields.putIfAbsent(
    v.comboKey,
    () => _VariantFields(v, isNew: v.isNew),
  );

  // -------------------------------------------------------------------------
  // Draft assembly
  // -------------------------------------------------------------------------

  List<OptionType> _types() => [
    for (var i = 0; i < _draft.optionTypes.length; i++)
      _draft.optionTypes[i].copyWith(name: _optionNames[i].text.trim()),
  ];

  /// The draft as typed, plus the parse issues of numeric fields.
  (ProductDraft, Map<String, FieldIssue>) _collect() {
    final issues = <String, FieldIssue>{};
    final (price, priceIssue) = parseWholeNumber(
      _price.text,
      min: 1,
      max: maxPrice,
    );
    if (priceIssue != null) issues['base_price'] = priceIssue;
    final (threshold, thresholdIssue) = parseWholeNumber(
      _threshold.text,
      min: 0,
      max: maxThreshold,
      required: false,
    );
    if (thresholdIssue != null) issues['low_stock_threshold'] = thresholdIssue;

    final variants = <VariantDraft>[];
    for (var i = 0; i < _draft.variants.length; i++) {
      var v = _draft.variants[i];
      if (!v.archived) v = v.copyWith(lowStockThreshold: () => threshold);
      if (_draft.hasOptions) {
        final f = _fieldsFor(v);
        final (vp, vpIssue) = parseWholeNumber(
          f.price.text,
          min: 1,
          max: maxPrice,
          required: false,
        );
        if (vpIssue != null) issues['variants.$i.price_override'] = vpIssue;
        final (vs, vsIssue) = parseWholeNumber(
          f.stock.text,
          min: 0,
          max: maxStock,
          required: false,
        );
        if (vsIssue != null) issues['variants.$i.initial_stock'] = vsIssue;
        v = v.copyWith(
          priceOverride: () => vp == price ? null : vp,
          sku: f.sku.text.trim(),
          initialStock: vs ?? 0,
        );
      } else if (!v.archived && v.optionValues.isEmpty && v.isNew) {
        final (q, qIssue) = parseWholeNumber(
          _quantity.text,
          min: 0,
          max: maxStock,
          required: false,
        );
        if (qIssue != null) issues['variants.$i.initial_stock'] = qIssue;
        v = v.copyWith(initialStock: q ?? 0);
      }
      variants.add(v);
    }
    final draft = _draft.copyWith(
      name: _name.text,
      description: _description.text,
      category: _category.text,
      basePrice: () => price,
      optionTypes: _types(),
      variants: variants,
      images: [
        for (final p in _photos)
          if (p.state == _PhotoState.uploaded) p.path!,
      ],
    );
    return (draft, issues);
  }

  bool get _dirty {
    if (_saved) return false;
    final (draft, _) = _collect();
    return draft.canonical != _initial ||
        _photos.any((p) => p.state != _PhotoState.uploaded);
  }

  void _regenerate() {
    final (current, _) = _collect();
    setState(() {
      _draft = current.copyWith(
        variants: combineVariants(
          current.optionTypes,
          current.variants,
          removed: _removedCombos,
        ),
      );
    });
  }

  // -------------------------------------------------------------------------
  // Options
  // -------------------------------------------------------------------------

  void _setHasOptions(bool on) {
    final (current, _) = _collect();
    if (on) {
      _optionNames.add(TextEditingController());
      _newValues.add(TextEditingController());
      _draft = current.copyWith(optionTypes: [const OptionType(name: '')]);
    } else {
      for (final c in [..._optionNames, ..._newValues]) {
        c.dispose();
      }
      _optionNames.clear();
      _newValues.clear();
      _removedCombos.clear();
      _draft = current.copyWith(optionTypes: const []);
    }
    _regenerate();
  }

  void _addOptionType() {
    if (_draft.optionTypes.length >= maxOptionTypes) return;
    final (current, _) = _collect();
    _optionNames.add(TextEditingController());
    _newValues.add(TextEditingController());
    _draft = current.copyWith(
      optionTypes: [
        ...current.optionTypes,
        const OptionType(name: ''),
      ],
    );
    _regenerate();
  }

  void _removeOptionType(int i) {
    final (current, _) = _collect();
    _optionNames.removeAt(i).dispose();
    _newValues.removeAt(i).dispose();
    final types = [...current.optionTypes]..removeAt(i);
    // Values of the removed type drop out of every combination.
    final variants = [
      for (final v in current.variants)
        if (v.optionValues.length > i)
          v.copyWith(optionValues: [...v.optionValues]..removeAt(i))
        else
          v,
    ];
    _removedCombos.clear();
    _draft = current.copyWith(optionTypes: types, variants: variants);
    if (types.isEmpty) {
      _setHasOptions(false);
    } else {
      _regenerate();
    }
  }

  void _addValue(int i) {
    final value = _newValues[i].text.trim();
    if (value.isEmpty) return;
    final type = _draft.optionTypes[i];
    if (type.values.any((v) => v.toLowerCase() == value.toLowerCase())) {
      setState(
        () => _issues = {..._issues, 'option_values.$i': FieldIssue.duplicate},
      );
      return;
    }
    _newValues[i].clear();
    final (current, _) = _collect();
    final types = [...current.optionTypes];
    types[i] = types[i].copyWith(values: [...types[i].values, value]);
    _issues = Map.of(_issues)..remove('option_values.$i');
    _draft = current.copyWith(optionTypes: types);
    _regenerate();
  }

  void _removeValue(int i, String value) {
    final (current, _) = _collect();
    final types = [...current.optionTypes];
    types[i] = types[i].copyWith(
      values: [
        for (final v in types[i].values)
          if (v != value) v,
      ],
    );
    _draft = current.copyWith(optionTypes: types);
    _regenerate();
  }

  void _toggleCombo(VariantDraft v, {required bool exists}) {
    if (exists) {
      _removedCombos.remove(v.comboKey);
    } else {
      _removedCombos.add(v.comboKey);
    }
    _regenerate();
  }

  void _applyForAll() {
    for (final v in _draft.activeVariants) {
      final f = _fieldsFor(v);
      if (_priceForAll.text.trim().isNotEmpty) {
        f.price.text = _priceForAll.text.trim();
      }
      if (_stockForAll.text.trim().isNotEmpty && v.isNew) {
        f.stock.text = _stockForAll.text.trim();
      }
    }
    _priceForAll.clear();
    _stockForAll.clear();
    setState(() {});
  }

  // -------------------------------------------------------------------------
  // Photos
  // -------------------------------------------------------------------------

  Future<void> _addPhoto({int? replaceAt}) async {
    final l10n = context.l10n;
    final source = await showAppSheet<PhotoSource>(
      context: context,
      title: l10n.addPhoto,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RowGroup(
            children: [
              NavRow(
                label: l10n.takePhoto,
                icon: AppIcons.camera,
                onTap: () => Navigator.of(context).pop(PhotoSource.camera),
              ),
              NavRow(
                label: l10n.chooseFromGallery,
                icon: AppIcons.image,
                onTap: () => Navigator.of(context).pop(PhotoSource.gallery),
              ),
            ],
          ),
        ],
      ),
    );
    if (source == null || !mounted) return;
    final Uint8List? bytes;
    try {
      bytes = await ref.read(photoPickerProvider).pick(source);
    } on Object {
      if (mounted) showAppSnackBar(context, l10n.photoUnsupported);
      return;
    }
    if (bytes == null || !mounted) return;
    final photo = _Photo.uploading(bytes);
    setState(() {
      if (replaceAt != null) {
        _photos[replaceAt] = photo;
      } else {
        _photos.add(photo);
      }
    });
    await _upload(photo);
  }

  Future<void> _upload(_Photo photo) async {
    final l10n = context.l10n;
    setState(() => photo.state = _PhotoState.uploading);
    try {
      final path = await _actions.uploadImage(_productId, photo.source!);
      _sessionUploads.add(path);
      if (!mounted) return;
      setState(() {
        photo
          ..path = path
          ..state = _PhotoState.uploaded;
      });
    } on MediaException catch (e) {
      if (!mounted) return;
      switch (e.failure) {
        case MediaFailure.tooLarge || MediaFailure.unsupported:
          setState(() => _photos.remove(photo));
          showAppSnackBar(
            context,
            e.failure == MediaFailure.tooLarge
                ? l10n.photoTooLarge
                : l10n.photoUnsupported,
          );
        case MediaFailure.network || MediaFailure.refused:
          setState(() => photo.state = _PhotoState.failed);
      }
    } on Object {
      if (mounted) setState(() => photo.state = _PhotoState.failed);
    }
  }

  Future<void> _openPhoto(int index) async {
    final uploaded = [
      for (final p in _photos)
        if (p.state == _PhotoState.uploaded) p,
    ];
    final photo = _photos[index];
    if (photo.state != _PhotoState.uploaded) return;
    final result = await Navigator.of(context).push<(int, ImageAction)>(
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          paths: [for (final p in uploaded) p.path!],
          initialIndex: uploaded.indexOf(photo),
          editable: true,
        ),
      ),
    );
    if (result == null || !mounted) return;
    final target = uploaded[result.$1];
    final at = _photos.indexOf(target);
    switch (result.$2) {
      case ImageAction.setAsMain:
        setState(
          () => _photos
            ..removeAt(at)
            ..insert(0, target),
        );
      case ImageAction.remove:
        setState(() => _photos.removeAt(at));
      case ImageAction.replace:
        await _addPhoto(replaceAt: at);
    }
  }

  // -------------------------------------------------------------------------
  // Save
  // -------------------------------------------------------------------------

  Future<void> _save() async {
    if (_busy) return;
    final l10n = context.l10n;
    final (draft, parseIssues) = _collect();
    final issues = {...validateProductDraft(draft), ...parseIssues};
    setState(() {
      _issues = issues;
      _error = issues.isEmpty ? null : l10n.errFormIssues(issues.length);
    });
    if (issues.isNotEmpty ||
        _photos.any((p) => p.state == _PhotoState.uploading)) {
      return;
    }
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      final product = await _actions.saveProduct(
        _productId,
        expectedVersion: widget.product?.version,
        draft: draft,
        idempotencyKey: _intent.forPayload(draft.canonical),
      );
      _saved = true;
      _draft = draft;
      if (!mounted) return;
      showSnackOn(messenger, _isNew ? l10n.productAdded : l10n.changesSaved);
      if (_isNew) {
        unawaited(router.pushReplacement(Routes.product(product.id)));
      } else {
        router.pop();
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      final digits = ref.read(settingsProvider).digits;
      setState(() {
        _busy = false;
        if (e.code == ApiErrorCode.validationFailed && e.fields.isNotEmpty) {
          _issues = serverFieldIssues(e.fields);
          _error = l10n.errFormIssues(_issues.length);
        } else {
          _error = catalogErrorText(l10n, e, digits: digits);
        }
      });
      if (e.code == ApiErrorCode.conflictVersion && !_isNew) {
        // Someone saved first: show the latest version (the editor rebuilds
        // from it) and say so.
        ref.invalidate(productProvider(_productId));
        showSnackOn(messenger, l10n.errConflictReloaded);
      }
    }
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  String? _issueText(String key) {
    final issue = _issues[key];
    return issue == null ? null : productFieldText(context.l10n, key, issue);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final wide = WindowClass.of(context).index >= WindowClass.medium.index;
    final uploading = _photos.any((x) => x.state == _PhotoState.uploading);
    final failed = _photos.where((x) => x.state == _PhotoState.failed).length;

    final photos = _PhotoStrip(
      photos: _photos,
      onAdd: _photos.length < maxImages && !_busy ? () => _addPhoto() : null,
      onOpen: _openPhoto,
      onRetry: _upload,
      vertical: wide,
    );
    final fields = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          AppBanner(
            tone: Tone.danger,
            icon: AppIcons.warningCircle,
            title: _error!,
          ),
          const SizedBox(height: Space.s16),
        ],
        SectionHeader(l10n.sectionDetails),
        AppTextField(
          label: l10n.fieldProductName,
          controller: _name,
          enabled: !_busy,
          error: _issueText('name'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.s12),
        AppTextField(
          label: l10n.fieldDescription,
          helper: l10n.descriptionHelper,
          controller: _description,
          maxLines: 4,
          enabled: !_busy,
          error: _issueText('description'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.s12),
        _CategoryField(
          controller: _category,
          enabled: !_busy,
          error: _issueText('category'),
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: Space.s24),
        AppTextField(
          label: l10n.fieldPriceRequired,
          controller: _price,
          ltr: true,
          keyboardType: TextInputType.number,
          enabled: !_busy,
          error: _issueText('base_price'),
          suffix: Padding(
            padding: const EdgeInsetsDirectional.only(end: Space.s12),
            child: Center(
              widthFactor: 1,
              child: Text(storeCurrency(ref) == Currency.usd ? 'USD' : 'IQD'),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.s24),
        RowGroup(
          children: [
            SwitchRow(
              label: l10n.hasOptions,
              description: l10n.hasOptionsBody,
              value: _draft.hasOptions,
              onChanged: _busy ? null : _setHasOptions,
            ),
          ],
        ),
        ExpandSection(
          expanded: _draft.hasOptions,
          child: _draft.hasOptions
              ? _optionsSection(context)
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: Space.s24),
        SectionHeader(l10n.sectionStock),
        RowGroup(
          children: [
            SwitchRow(
              label: l10n.trackStock,
              description: l10n.trackStockBody,
              value: _draft.trackStock,
              onChanged: _busy
                  ? null
                  : (v) =>
                        setState(() => _draft = _draft.copyWith(trackStock: v)),
            ),
            if (!_draft.trackStock && !_draft.hasOptions)
              SwitchRow(
                label: l10n.availableSwitch,
                description: l10n.availableBody,
                value: _draft.activeVariants.firstOrNull?.available ?? true,
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _draft = _draft.copyWith(
                          variants: [
                            for (final x in _draft.variants)
                              x.archived ? x : x.copyWith(available: v),
                          ],
                        );
                      }),
              ),
          ],
        ),
        if (_draft.trackStock) ...[
          const SizedBox(height: Space.s12),
          if (!_draft.hasOptions &&
              (_draft.activeVariants.firstOrNull?.isNew ?? true))
            AppTextField(
              label: l10n.fieldQuantity,
              controller: _quantity,
              ltr: true,
              keyboardType: TextInputType.number,
              enabled: !_busy,
              error: _issueText('variants.0.initial_stock'),
              onChanged: (_) => setState(() {}),
            ),
          if (!_isNew) ...[
            Text(
              l10n.stockEditNote,
              style: context.type.caption.copyWith(color: p.textSecondary),
            ),
            const SizedBox(height: Space.s12),
          ],
          AppTextField(
            label: l10n.fieldLowStockAt,
            helper: l10n.lowStockAtHelper(
              count(
                widget.product?.lowStockDefault ?? 3,
                ref.watch(settingsProvider).digits,
              ),
            ),
            controller: _threshold,
            ltr: true,
            keyboardType: TextInputType.number,
            enabled: !_busy,
            error: _issueText('low_stock_threshold'),
            onChanged: (_) => setState(() {}),
          ),
        ],
        const SizedBox(height: Space.s24),
        SectionHeader(l10n.sectionVisibility),
        RowGroup(
          children: [
            SwitchRow(
              label: l10n.activeSwitch,
              description: l10n.activeBody,
              value: _draft.active,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _draft = _draft.copyWith(active: v)),
            ),
          ],
        ),
      ],
    );

    return PopScope<Object?>(
      canPop: !_dirty || _busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await confirmDiscard(context)) {
          navigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: p.bgCanvas,
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          leading: IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: const Icon(AppIcons.x),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text(_isNew ? l10n.newProductTitle : l10n.editProductTitle),
        ),
        body: ListView(
          padding: const EdgeInsets.only(top: Space.s8, bottom: Space.s32),
          children: [
            ContentWidth(
              maxWidth: wide
                  ? LayoutTokens.maxWidthReading
                  : LayoutTokens.maxWidthForm,
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 240, child: photos),
                        const SizedBox(width: Space.s24),
                        Expanded(child: fields),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        photos,
                        const SizedBox(height: Space.s24),
                        fields,
                      ],
                    ),
            ),
          ],
        ),
        bottomNavigationBar: StickyActionBar(
          reason: uploading
              ? Text(
                  l10n.photosStillUploading,
                  style: context.type.caption.copyWith(color: p.textSecondary),
                )
              : failed > 0
              ? Text(
                  l10n.photosFailedSaveAnyway(failed),
                  style: context.type.caption.copyWith(color: p.warningFg),
                )
              : null,
          primary: AppButton(
            label: l10n.save,
            expand: true,
            loading: _busy,
            onPressed: uploading ? null : _save,
          ),
        ),
      ),
    );
  }

  Widget _optionsSection(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final active = _draft.activeVariants;
    final removed = combineVariants(
      _types(),
      const [],
    ).where((v) => _removedCombos.contains(v.comboKey)).toList();
    return Padding(
      padding: const EdgeInsets.only(top: Space.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.optionTypesLimit(_draft.optionTypes.length),
            style: type.caption.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: Space.s8),
          for (var i = 0; i < _draft.optionTypes.length; i++) ...[
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: p.borderHairline),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Padding(
                padding: const EdgeInsets.all(Space.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: AppTextField(
                            label: l10n.optionName,
                            controller: _optionNames[i],
                            enabled: !_busy,
                            error: _issueText('option_types.$i'),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        IconButton(
                          tooltip: l10n.removeOptionType,
                          icon: const Icon(AppIcons.trash),
                          onPressed: _busy ? null : () => _removeOptionType(i),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.s8),
                    Text(
                      l10n.optionValues,
                      style: type.label.copyWith(color: p.textSecondary),
                    ),
                    const SizedBox(height: Space.s4),
                    Wrap(
                      spacing: Space.s8,
                      runSpacing: Space.s4,
                      children: [
                        for (final v in _draft.optionTypes[i].values)
                          InputChip(
                            label: Text(v, textDirection: Bidi.detect(v)),
                            deleteButtonTooltipMessage: l10n.removeValue(v),
                            // The bundled icon font has no Material glyphs.
                            deleteIcon: const Icon(
                              AppIcons.x,
                              size: Sizes.iconSm,
                            ),
                            onDeleted: _busy ? null : () => _removeValue(i, v),
                          ),
                      ],
                    ),
                    const SizedBox(height: Space.s8),
                    AppTextField(
                      label: l10n.addValue,
                      controller: _newValues[i],
                      enabled: !_busy,
                      textInputAction: TextInputAction.done,
                      error: _issueText('option_values.$i'),
                      onSubmitted: (_) => _addValue(i),
                      suffix: IconButton(
                        tooltip: l10n.addValue,
                        icon: const Icon(AppIcons.plus),
                        onPressed: _busy ? null : () => _addValue(i),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.s12),
          ],
          if (_draft.optionTypes.length < maxOptionTypes)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppButton(
                label: l10n.addOptionType,
                icon: AppIcons.plus,
                variant: AppButtonVariant.tertiary,
                onPressed: _busy ? null : _addOptionType,
              ),
            ),
          if (_draft.optionTypes.every((t) => t.values.isNotEmpty)) ...[
            const SizedBox(height: Space.s16),
            SectionHeader(
              l10n.combinationsTitle,
              action: _HeaderNote(
                l10n.variantsLimit(active.length),
                style: type.caption.copyWith(
                  color: active.length > maxVariants
                      ? p.dangerFgOnBg
                      : p.textSecondary,
                ),
              ),
            ),
            if (active.length > 1) ...[
              _SetForAll(
                price: AppTextField(
                  label: l10n.priceForAll,
                  controller: _priceForAll,
                  ltr: true,
                  keyboardType: TextInputType.number,
                ),
                stock: _draft.trackStock && active.any((v) => v.isNew)
                    ? AppTextField(
                        label: l10n.stockForAll,
                        controller: _stockForAll,
                        ltr: true,
                        keyboardType: TextInputType.number,
                      )
                    : null,
                apply: AppButton(
                  label: l10n.apply,
                  variant: AppButtonVariant.secondary,
                  onPressed: _applyForAll,
                ),
              ),
              const SizedBox(height: Space.s12),
            ],
            for (var i = 0; i < _draft.variants.length; i++)
              if (!_draft.variants[i].archived)
                _CombinationRow(
                  key: ValueKey(_draft.variants[i].comboKey),
                  variant: _draft.variants[i],
                  fields: _fieldsFor(_draft.variants[i]),
                  basePrice: _price.text,
                  tracked: _draft.trackStock,
                  digits: digits,
                  enabled: !_busy,
                  priceError: _issueText('variants.$i.price_override'),
                  skuError: _issueText('variants.$i.sku'),
                  stockError: _issueText('variants.$i.initial_stock'),
                  onRemove: () =>
                      _toggleCombo(_draft.variants[i], exists: false),
                  onAvailable: (on) => setState(() {
                    final list = [..._draft.variants];
                    list[i] = list[i].copyWith(available: on);
                    _draft = _draft.copyWith(variants: list);
                  }),
                ),
            for (final v in removed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.s4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        v.label,
                        style: type.body.copyWith(
                          color: p.textTertiary,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                    ),
                    AppButton(
                      label: l10n.addBack,
                      variant: AppButtonVariant.tertiary,
                      onPressed: _busy
                          ? null
                          : () => _toggleCombo(v, exists: true),
                    ),
                  ],
                ),
              ),
            for (final v in _draft.variants.where((v) => v.archived))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.s4),
                child: Text(
                  '${v.label.isEmpty ? l10n.sectionStock : v.label} — ${l10n.optionArchivedNote}',
                  style: type.caption.copyWith(color: p.textTertiary),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _CombinationRow extends StatelessWidget {
  const _CombinationRow({
    super.key,
    required this.variant,
    required this.fields,
    required this.basePrice,
    required this.tracked,
    required this.digits,
    required this.enabled,
    required this.onRemove,
    required this.onAvailable,
    this.priceError,
    this.skuError,
    this.stockError,
  });

  final VariantDraft variant;
  final _VariantFields fields;
  final String basePrice;
  final bool tracked;
  final DigitStyle digits;
  final bool enabled;
  final VoidCallback onRemove;
  final ValueChanged<bool> onAvailable;
  final String? priceError;
  final String? skuError;
  final String? stockError;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final custom =
        fields.price.text.trim().isNotEmpty &&
        fields.price.text.trim() != basePrice.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: p.bgSurface,
          border: Border.all(color: p.borderHairline),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Space.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Wraps at large text sizes instead of overflowing.
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                spacing: Space.s8,
                children: [
                  Text(
                    Bidi.auto(variant.label),
                    style: type.bodyStrong.copyWith(color: p.textPrimary),
                  ),
                  if (custom)
                    StatusBadge(
                      label: l10n.customPrice,
                      icon: AppIcons.pencilSimple,
                      tone: Tone.info,
                    ),
                  AppButton(
                    label: variant.hasHistory
                        ? l10n.archiveOption
                        : l10n.doesNotExist,
                    variant: AppButtonVariant.tertiary,
                    onPressed: enabled ? onRemove : null,
                  ),
                ],
              ),
              const SizedBox(height: Space.s8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppTextField(
                      label: l10n.fieldPrice,
                      controller: fields.price,
                      ltr: true,
                      keyboardType: TextInputType.number,
                      enabled: enabled,
                      error: priceError,
                    ),
                  ),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: AppTextField(
                      label: l10n.fieldVariantSku,
                      controller: fields.sku,
                      ltr: true,
                      enabled: enabled,
                      error: skuError,
                    ),
                  ),
                ],
              ),
              if (tracked) ...[
                const SizedBox(height: Space.s8),
                if (variant.isNew)
                  AppTextField(
                    label: l10n.fieldStock,
                    controller: fields.stock,
                    ltr: true,
                    keyboardType: TextInputType.number,
                    enabled: enabled,
                    error: stockError,
                  )
                else
                  Text(
                    l10n.stockInStock(count(variant.stockOnHand, digits)),
                    style: type.caption.copyWith(color: p.textSecondary),
                  ),
              ] else
                SwitchRow(
                  label: l10n.availableSwitch,
                  value: variant.available,
                  onChanged: enabled ? onAvailable : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryField extends ConsumerWidget {
  const _CategoryField({
    required this.controller,
    required this.enabled,
    required this.onChanged,
    this.error,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;
  final String? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final own =
        ref
            .watch(catalogSummaryProvider)
            .value
            ?.categories
            .map((c) => c.name) ??
        const [];
    final seen = <String>{};
    final suggestions = [
      for (final c in [...own, ...categorySuggestions(l10n)])
        if (seen.add(c.toLowerCase())) c,
    ];
    final current = controller.text.trim().toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTextField(
          label: l10n.fieldCategory,
          helper: l10n.categoryHelper,
          controller: controller,
          enabled: enabled,
          error: error,
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: Space.s8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final c in suggestions)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: Space.s8),
                  child: ChoiceChip(
                    label: Text(c),
                    selected: c.toLowerCase() == current,
                    showCheckmark: false,
                    onSelected: enabled
                        ? (_) {
                            controller.text = c;
                            onChanged();
                          }
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({
    required this.photos,
    required this.onAdd,
    required this.onOpen,
    required this.onRetry,
    required this.vertical,
  });

  final List<_Photo> photos;
  final VoidCallback? onAdd;
  final ValueChanged<int> onOpen;
  final ValueChanged<_Photo> onRetry;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final tiles = <Widget>[
      for (var i = 0; i < photos.length; i++)
        _PhotoTile(
          key: ObjectKey(photos[i]),
          photo: photos[i],
          main: i == 0,
          onTap: () => photos[i].state == _PhotoState.failed
              ? onRetry(photos[i])
              : onOpen(i),
        ),
      if (onAdd != null)
        Semantics(
          button: true,
          label: l10n.addPhoto,
          excludeSemantics: true,
          child: InkWell(
            onTap: onAdd,
            borderRadius: BorderRadius.circular(Radii.md),
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: p.bgSurface,
                border: Border.all(color: p.borderControl),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(AppIcons.camera, color: p.textBrand),
                  const SizedBox(height: Space.s4),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        l10n.addPhoto,
                        style: context.type.caption.copyWith(
                          color: p.textBrand,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          l10n.sectionPhotos,
          action: _HeaderNote(
            l10n.photosLimit(photos.length),
            style: context.type.caption.copyWith(color: p.textSecondary),
          ),
        ),
        if (vertical)
          Wrap(spacing: Space.s8, runSpacing: Space.s8, children: tiles)
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final t in tiles)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: Space.s8),
                    child: t,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    super.key,
    required this.photo,
    required this.main,
    required this.onTap,
  });

  final _Photo photo;
  final bool main;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final image = photo.path != null && photo.state == _PhotoState.uploaded
        ? ProductImage(path: photo.path, size: 96, radius: Radii.md)
        : ClipRRect(
            borderRadius: BorderRadius.circular(Radii.md),
            child: Image.memory(
              photo.source!,
              width: 96,
              height: 96,
              fit: BoxFit.cover,
              cacheWidth: 288,
            ),
          );
    final label = switch (photo.state) {
      _PhotoState.uploading => l10n.photoUploading,
      _PhotoState.failed => l10n.photoNotUploaded,
      _PhotoState.uploaded => main ? l10n.mainPhoto : l10n.sectionPhotos,
    };
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: photo.state == _PhotoState.uploading ? null : onTap,
        child: SizedBox(
          width: 96,
          height: 96,
          child: Stack(
            fit: StackFit.expand,
            children: [
              image,
              if (photo.state == _PhotoState.uploading)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  alignment: Alignment.center,
                  child: const SizedBox.square(
                    dimension: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              if (photo.state == _PhotoState.failed)
                FadeSlideIn(
                  child: Container(
                    decoration: BoxDecoration(
                      color: p.dangerBg.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(Radii.md),
                      border: Border.all(color: p.dangerFg),
                    ),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(Space.s4),
                    child: Text(
                      l10n.photoNotUploaded,
                      textAlign: TextAlign.center,
                      style: type.caption.copyWith(color: p.dangerFgOnBg),
                    ),
                  ),
                ),
              if (main && photo.state == _PhotoState.uploaded)
                PositionedDirectional(
                  start: Space.s4,
                  bottom: Space.s4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.s4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: p.bgSurface.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: Text(
                      l10n.mainPhoto,
                      style: type.caption.copyWith(color: p.textPrimary),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section header's trailing note (end-aligned when it wraps).
class _HeaderNote extends StatelessWidget {
  const _HeaderNote(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) =>
      Text(text, textAlign: TextAlign.end, style: style);
}

/// "Set for all" fields and Apply: one row, or stacked at large text sizes
/// (Phase 2 §7: rows stack at a text scale of 1.3 or more).
class _SetForAll extends StatelessWidget {
  const _SetForAll({required this.price, required this.apply, this.stock});

  final Widget price;
  final Widget? stock;
  final Widget apply;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.textScalerOf(context).scale(1) >= 1.3) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          price,
          if (stock != null) ...[const SizedBox(height: Space.s8), stock!],
          const SizedBox(height: Space.s8),
          Align(alignment: AlignmentDirectional.centerEnd, child: apply),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: price),
        if (stock != null) ...[
          const SizedBox(width: Space.s8),
          Expanded(child: stock!),
        ],
        const SizedBox(width: Space.s8),
        apply,
      ],
    );
  }
}
