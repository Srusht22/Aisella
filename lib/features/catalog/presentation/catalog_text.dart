import '../../../core/backend/api.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/settings/app_settings.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../common/api_error_text.dart';
import '../../store/domain/store_validation.dart'
    show FieldIssue, fieldIssueFromServer;
import '../domain/catalog.dart';
import '../domain/product_draft.dart';

/// Localised catalog wording shared by the catalog screens.

String reasonLabel(AppLocalizations l10n, StockReason r) => switch (r) {
  StockReason.received => l10n.reasonReceived,
  StockReason.soldInShop => l10n.reasonSoldInShop,
  StockReason.damaged => l10n.reasonDamaged,
  StockReason.countCorrection => l10n.reasonCountCorrection,
  StockReason.other => l10n.reasonOther,
  StockReason.initialStock => l10n.reasonInitial,
  StockReason.orderApproved => l10n.reasonOrderApproved,
  StockReason.orderEdited => l10n.reasonOrderEdited,
  StockReason.orderCancelled => l10n.reasonOrderCancelled,
  StockReason.orderReturned => l10n.reasonOrderReturned,
};

String actorLabel(AppLocalizations l10n, MovementActor a) => switch (a) {
  MovementActor.you => l10n.actorYou,
  MovementActor.member => l10n.actorMember,
  MovementActor.system => l10n.actorSystem,
};

/// Suggested categories (illustrative; sellers may type their own).
List<String> categorySuggestions(AppLocalizations l10n) => [
  l10n.catClothing,
  l10n.catShoesBags,
  l10n.catCosmetics,
  l10n.catPerfumes,
  l10n.catElectronics,
  l10n.catHome,
  l10n.catGifts,
  l10n.catOther,
];

String count(int value, DigitStyle digits) =>
    Bidi.ltr(Digits.display('$value', digits));

/// Message for an editor field issue; [key] is the server's field key.
String productFieldText(AppLocalizations l10n, String key, FieldIssue issue) {
  final field = key.split('.').last;
  if (issue == FieldIssue.tooLong) {
    final max = switch (field) {
      'name' => maxProductNameLength,
      'description' => maxDescriptionLength,
      'category' => maxCategoryLength,
      'sku' => maxSkuLength,
      _ => maxOptionNameLength,
    };
    return l10n.errTooLongMax('$max');
  }
  if (key == 'name') return l10n.errProductNameRequired;
  if (key == 'base_price' || field == 'price_override') {
    return issue == FieldIssue.required
        ? l10n.errPriceRequired
        : l10n.errPriceInvalid;
  }
  if (field == 'sku') return l10n.errSkuDuplicate;
  if (key.startsWith('option_types')) {
    return issue == FieldIssue.duplicate
        ? l10n.errOptionDuplicate
        : l10n.errOptionNameRequired;
  }
  if (key.startsWith('option_values')) return l10n.errOptionValuesRequired;
  if (key == 'variants') return l10n.errNeedOneVariant;
  if (field == 'initial_stock' || field == 'low_stock_threshold') {
    return l10n.errQuantityInvalid;
  }
  return l10n.errSaveFailed;
}

/// Server field codes mapped onto the editor's issue keys.
Map<String, FieldIssue> serverFieldIssues(Map<String, String> fields) => {
  for (final e in fields.entries)
    e.key: e.value == 'sku_duplicate'
        ? FieldIssue.duplicate
        : fieldIssueFromServer(e.value),
};

/// API errors, including the catalog's stock codes.
String catalogErrorText(
  AppLocalizations l10n,
  ApiException e, {
  required DigitStyle digits,
}) => switch (e.code) {
  ApiErrorCode.variantInUse => l10n.errVariantInUse,
  ApiErrorCode.stockNotTracked => l10n.errStockNotTracked,
  ApiErrorCode.insufficientStock => l10n.errOnlyInStock(
    count(e.currentStock ?? 0, digits),
  ),
  ApiErrorCode.stockChanged => l10n.stockChangedWhileEditing(
    count(e.currentStock ?? 0, digits),
  ),
  ApiErrorCode.notFound => l10n.productUnavailableTitle,
  _ => apiErrorText(l10n, e),
};

/// Cause line of a failed load (P-ERR-LOAD).
String loadErrorText(AppLocalizations l10n, Object error) => switch (error) {
  ApiException(code: ApiErrorCode.network || ApiErrorCode.timeout) =>
    l10n.errNetwork,
  ApiException(code: ApiErrorCode.notFound) => l10n.productUnavailableBody,
  _ => l10n.errorServer,
};
