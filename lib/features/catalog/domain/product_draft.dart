import 'package:flutter/foundation.dart';

import '../../../core/formatting/digits.dart';
import '../../store/domain/store_validation.dart' show FieldIssue;
import 'catalog.dart';

/// Product editor input (Phase 2 PR-03/PR-04) and the client-side checks that
/// mirror `api.upsert_product`. The server's answer is authoritative; its
/// field codes use the same keys (`name`, `base_price`, `variants.2.sku`).

const maxProductNameLength = 120;
const maxDescriptionLength = 2000;
const maxCategoryLength = 60;
const maxOptionTypes = 2;
const maxOptionNameLength = 30;
const maxOptionValueLength = 30;
const maxVariants = 100;
const maxImages = 5;
const maxSkuLength = 64;
const maxPrice = 1000000000;
const maxStock = 1000000;
const maxThreshold = 9999;
const maxStockNoteLength = 200;

/// Parses a whole number typed with Western, Eastern Arabic or Persian digits
/// and optional grouping separators (Phase 1 Journey B: digits are
/// normalised). Returns the value or the issue.
(int?, FieldIssue?) parseWholeNumber(
  String input, {
  required int min,
  required int max,
  bool required = true,
}) {
  final raw = Digits.normalize(input).replaceAll(RegExp(r'[\s,٬]'), '');
  if (raw.isEmpty) return (null, required ? FieldIssue.required : null);
  if (!RegExp(r'^\d+$').hasMatch(raw)) return (null, FieldIssue.invalid);
  final value = int.tryParse(raw);
  if (value == null || value < min || value > max) {
    return (null, FieldIssue.invalid);
  }
  return (value, null);
}

@immutable
class OptionType {
  const OptionType({required this.name, this.values = const []});

  final String name;
  final List<String> values;

  OptionType copyWith({String? name, List<String>? values}) =>
      OptionType(name: name ?? this.name, values: values ?? this.values);
}

/// One sellable combination in the editor.
@immutable
class VariantDraft {
  const VariantDraft({
    required this.optionValues,
    this.id,
    this.sku = '',
    this.priceOverride,
    this.initialStock = 0,
    this.stockOnHand = 0,
    this.available = true,
    this.lowStockThreshold,
    this.archived = false,
    this.hasHistory = false,
  });

  factory VariantDraft.fromVariant(Variant v) => VariantDraft(
    id: v.id,
    optionValues: v.optionValues,
    sku: v.sku ?? '',
    priceOverride: v.priceOverride,
    stockOnHand: v.stockOnHand,
    available: v.available,
    lowStockThreshold: v.lowStockThreshold,
    archived: v.archived,
    hasHistory: v.hasHistory || v.stockOnHand != 0,
  );

  /// Null for a variant that does not exist on the server yet.
  final String? id;
  final List<String> optionValues;
  final String sku;
  final int? priceOverride;

  /// Only for new variants of tracked products; existing stock changes only
  /// through stock adjustments.
  final int initialStock;

  /// Server stock of an existing variant (read-only in the editor).
  final int stockOnHand;
  final bool available;
  final int? lowStockThreshold;
  final bool archived;

  /// Has stock or movements: removing it is refused; it can be archived.
  final bool hasHistory;

  bool get isNew => id == null;
  String get label => optionValues.join(' · ');
  String get comboKey =>
      optionValues.map((v) => v.trim().toLowerCase()).join('\u001f');

  VariantDraft copyWith({
    String? sku,
    int? Function()? priceOverride,
    int? initialStock,
    bool? available,
    int? Function()? lowStockThreshold,
    bool? archived,
    List<String>? optionValues,
  }) => VariantDraft(
    id: id,
    optionValues: optionValues ?? this.optionValues,
    sku: sku ?? this.sku,
    priceOverride: priceOverride != null ? priceOverride() : this.priceOverride,
    initialStock: initialStock ?? this.initialStock,
    stockOnHand: stockOnHand,
    available: available ?? this.available,
    lowStockThreshold: lowStockThreshold != null
        ? lowStockThreshold()
        : this.lowStockThreshold,
    archived: archived ?? this.archived,
    hasHistory: hasHistory,
  );

  Map<String, Object?> toJson({required bool trackStock}) => {
    'id': ?id,
    'option_values': optionValues.map((v) => v.trim()).toList(),
    'sku': sku.trim().isEmpty ? null : sku.trim(),
    'price_override': priceOverride,
    if (isNew && trackStock && initialStock > 0) 'initial_stock': initialStock,
    'available': available,
    'low_stock_threshold': lowStockThreshold,
    'status': archived ? 'archived' : 'active',
  };
}

@immutable
class ProductDraft {
  const ProductDraft({
    this.name = '',
    this.description = '',
    this.category = '',
    this.basePrice,
    this.trackStock = true,
    this.active = true,
    this.optionTypes = const [],
    this.variants = const [VariantDraft(optionValues: [])],
    this.images = const [],
  });

  factory ProductDraft.fromProduct(Product p) => ProductDraft(
    name: p.name,
    description: p.description ?? '',
    category: p.category ?? '',
    basePrice: p.basePrice,
    trackStock: p.trackStock,
    active: p.status != ProductStatus.inactive,
    optionTypes: [
      for (var i = 0; i < p.optionTypes.length; i++)
        OptionType(
          name: p.optionTypes[i],
          values: _distinct([
            for (final v in p.variants)
              if (!v.archived && v.optionValues.length > i) v.optionValues[i],
          ]),
        ),
    ],
    variants: [for (final v in p.variants) VariantDraft.fromVariant(v)],
    images: [for (final i in p.images) i.path],
  );

  final String name;
  final String description;
  final String category;
  final int? basePrice;
  final bool trackStock;
  final bool active;
  final List<OptionType> optionTypes;
  final List<VariantDraft> variants;

  /// Uploaded image paths in display order (the first is the main image).
  final List<String> images;

  bool get hasOptions => optionTypes.isNotEmpty;
  List<VariantDraft> get activeVariants => [
    for (final v in variants)
      if (!v.archived) v,
  ];

  ProductDraft copyWith({
    String? name,
    String? description,
    String? category,
    int? Function()? basePrice,
    bool? trackStock,
    bool? active,
    List<OptionType>? optionTypes,
    List<VariantDraft>? variants,
    List<String>? images,
  }) => ProductDraft(
    name: name ?? this.name,
    description: description ?? this.description,
    category: category ?? this.category,
    basePrice: basePrice != null ? basePrice() : this.basePrice,
    trackStock: trackStock ?? this.trackStock,
    active: active ?? this.active,
    optionTypes: optionTypes ?? this.optionTypes,
    variants: variants ?? this.variants,
    images: images ?? this.images,
  );

  /// The `p_product` payload of `api.upsert_product`.
  Map<String, Object?> toJson() => {
    'name': name.trim(),
    'description': description.trim().isEmpty ? null : description.trim(),
    'category': category.trim().isEmpty ? null : category.trim(),
    'base_price': basePrice,
    'track_stock': trackStock,
    'status': active ? 'active' : 'inactive',
    'option_types': [for (final t in optionTypes) t.name.trim()],
    'variants': [for (final v in variants) v.toJson(trackStock: trackStock)],
    'images': images,
  };

  /// Value equality through the payload, for the unsaved-changes guard and
  /// the idempotency intent.
  String get canonical => toJson().toString();
}

List<String> _distinct(Iterable<String> values) {
  final seen = <String>{};
  return [
    for (final v in values)
      if (seen.add(v.trim().toLowerCase())) v,
  ];
}

/// Combines option values into variants (PR-04): every combination of the
/// option types' values, keeping existing variants (matched by values,
/// case-insensitively) and leaving out combinations the seller removed.
/// Variants that no longer match a combination are kept archived when they
/// have history, and dropped when they are new or empty.
List<VariantDraft> combineVariants(
  List<OptionType> types,
  List<VariantDraft> current, {
  Set<String> removed = const {},
}) {
  if (types.isEmpty || types.any((t) => t.values.isEmpty)) {
    // No options: one default variant (reuse the existing default if any).
    final keep = <VariantDraft>[];
    final existingDefault = current
        .where((v) => v.optionValues.isEmpty)
        .firstOrNull;
    keep.add(
      existingDefault?.copyWith(archived: false) ??
          const VariantDraft(optionValues: []),
    );
    for (final v in current) {
      if (v.optionValues.isNotEmpty && v.hasHistory) {
        keep.add(v.copyWith(archived: true));
      }
    }
    return keep;
  }
  var combos = <List<String>>[[]];
  for (final t in types) {
    combos = [
      for (final c in combos)
        for (final v in t.values) [...c, v],
    ];
  }
  final byKey = {for (final v in current) v.comboKey: v};
  final result = <VariantDraft>[];
  final used = <String>{};
  for (final c in combos) {
    final draft = VariantDraft(optionValues: c);
    final key = draft.comboKey;
    if (removed.contains(key)) continue;
    used.add(key);
    final existing = byKey[key];
    result.add(
      existing == null
          ? draft
          : existing.copyWith(optionValues: c, archived: existing.archived),
    );
  }
  for (final v in current) {
    if (!used.contains(v.comboKey) && v.hasHistory) {
      result.add(v.copyWith(archived: true));
    }
  }
  return result;
}

/// Client-side validation; keys match the server's field keys.
Map<String, FieldIssue> validateProductDraft(ProductDraft d) {
  final issues = <String, FieldIssue>{};
  final name = d.name.trim();
  if (name.isEmpty) {
    issues['name'] = FieldIssue.required;
  } else if (name.runes.length > maxProductNameLength) {
    issues['name'] = FieldIssue.tooLong;
  }
  if (d.description.trim().runes.length > maxDescriptionLength) {
    issues['description'] = FieldIssue.tooLong;
  }
  if (d.category.trim().runes.length > maxCategoryLength) {
    issues['category'] = FieldIssue.tooLong;
  }
  final price = d.basePrice;
  if (price == null) {
    issues['base_price'] = FieldIssue.required;
  } else if (price < 1 || price > maxPrice) {
    issues['base_price'] = FieldIssue.invalid;
  }
  if (d.optionTypes.length > maxOptionTypes) {
    issues['option_types'] = FieldIssue.invalid;
  }
  final typeNames = <String>{};
  for (var i = 0; i < d.optionTypes.length; i++) {
    final t = d.optionTypes[i];
    final n = t.name.trim();
    if (n.isEmpty) {
      issues['option_types.$i'] = FieldIssue.required;
    } else if (n.runes.length > maxOptionNameLength) {
      issues['option_types.$i'] = FieldIssue.tooLong;
    } else if (!typeNames.add(n.toLowerCase())) {
      issues['option_types.$i'] = FieldIssue.duplicate;
    }
    if (t.values.isEmpty) issues['option_values.$i'] = FieldIssue.required;
  }
  if (d.variants.length > maxVariants) issues['variants'] = FieldIssue.invalid;
  if (d.activeVariants.isEmpty) issues['variants'] = FieldIssue.required;
  final skus = <String>{};
  for (var i = 0; i < d.variants.length; i++) {
    final v = d.variants[i];
    final sku = v.sku.trim().toLowerCase();
    if (sku.isNotEmpty) {
      if (sku.length > maxSkuLength) {
        issues['variants.$i.sku'] = FieldIssue.tooLong;
      } else if (!skus.add(sku)) {
        issues['variants.$i.sku'] = FieldIssue.duplicate;
      }
    }
  }
  if (d.images.length > maxImages) issues['images'] = FieldIssue.invalid;
  return issues;
}

/// The stock a seller will see after an adjustment (PR-05 "12 → 15"), or
/// null when the input is not a valid quantity for the mode.
int? adjustmentResult(AdjustMode mode, int current, int? quantity) {
  if (quantity == null) return null;
  final result = switch (mode) {
    AdjustMode.add => current + quantity,
    AdjustMode.remove => current - quantity,
    AdjustMode.set => quantity,
  };
  return result;
}
