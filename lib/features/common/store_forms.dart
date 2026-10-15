import 'package:flutter/material.dart';

import '../../core/formatting/bidi.dart';
import '../../core/formatting/money.dart';
import '../../core/formatting/phone.dart';
import '../../core/l10n/l10n.dart';
import '../../design_system/components/inputs.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../store/domain/store.dart';
import '../store/domain/store_validation.dart';

const otherCityKey = 'other';

/// Sample local number shown in hints, isolated LTR so its digit groups keep
/// their order inside Sorani text.
final phoneExample = Bidi.ltr('0750 123 4567');

/// Localized name of a stored business city (a suggested key or free text).
String cityLabel(AppLocalizations l10n, String value) => switch (value) {
  'sulaymaniyah' => l10n.citySulaymaniyah,
  'erbil' => l10n.cityErbil,
  'duhok' => l10n.cityDuhok,
  'halabja' => l10n.cityHalabja,
  _ => value,
};

String? fieldIssueText(AppLocalizations l10n, String field, FieldIssue? issue) {
  if (issue == null) return null;
  return switch ((field, issue)) {
    ('name', FieldIssue.tooLong) => l10n.errStoreNameTooLong,
    ('name', _) => l10n.errStoreNameRequired,
    ('phone', FieldIssue.required) => l10n.errPhoneRequired,
    ('phone', _) => l10n.errPhoneInvalid(phoneExample),
    ('city', _) => l10n.errCityRequired,
    ('zoneName', FieldIssue.duplicate) => l10n.errZoneNameDuplicate,
    ('zoneName', _) => l10n.errZoneNameRequired,
    ('fee', FieldIssue.required) => l10n.errFeeRequired,
    ('fee', _) => l10n.errFeeInvalid,
    _ => l10n.errGeneric,
  };
}

/// Editable store basics (AU-07, ST-02). Holds the input across failed
/// attempts so nothing the seller typed is lost (CC-1).
class StoreBasicsValues extends ChangeNotifier {
  StoreBasicsValues({Store? from, required String defaultReplyLocale})
    : name = TextEditingController(text: from?.name ?? ''),
      phone = TextEditingController(text: from?.contactPhone ?? ''),
      otherCity = TextEditingController(
        text: from != null && !suggestedCities.contains(from.businessCity)
            ? from.businessCity
            : '',
      ),
      currency = from?.currency ?? Currency.iqd,
      replyLocale = from?.replyLocale ?? defaultReplyLocale,
      cityKey = from == null
          ? null
          : suggestedCities.contains(from.businessCity)
          ? from.businessCity
          : otherCityKey;

  final TextEditingController name;
  final TextEditingController phone;
  final TextEditingController otherCity;
  Currency currency;
  String replyLocale;

  /// A [suggestedCities] key, [otherCityKey], or null (not chosen).
  String? cityKey;

  /// Field issues to show: client checks after the first submit, or the
  /// server's field codes.
  Map<String, FieldIssue> issues = {};

  void set(void Function() change) {
    change();
    notifyListeners();
  }

  String get city =>
      cityKey == otherCityKey ? otherCity.text.trim() : cityKey ?? '';

  /// Validates and returns the normalised draft, or null with [issues] set.
  StoreDraft? validate() {
    final (e164, phoneIssue) = parseContactPhone(phone.text);
    issues = {
      'name': ?validateStoreName(name.text),
      'phone': ?phoneIssue,
      'city': ?validateCity(city),
    };
    notifyListeners();
    if (issues.isNotEmpty) return null;
    return StoreDraft(
      name: name.text.trim(),
      contactPhone: e164!,
      currency: currency,
      replyLocale: replyLocale,
      businessCity: city,
    );
  }

  /// Applies `{api_field: rule}` from a VALIDATION_FAILED response.
  void applyServerIssues(Map<String, String> fields) {
    issues = {
      for (final MapEntry(:key, :value) in fields.entries)
        switch (key) {
          'contact_phone' => 'phone',
          'business_city' => 'city',
          _ => key,
        }: fieldIssueFromServer(
          value,
        ),
    };
    notifyListeners();
  }

  /// Whether the input differs from the saved [store] (unsaved changes).
  /// Side-effect free, so it can be called during build.
  bool differsFrom(Store store) =>
      name.text.trim() != store.name ||
      (PhoneNumbers.normalizeIraqMobile(phone.text) ?? phone.text) !=
          store.contactPhone ||
      currency != store.currency ||
      replyLocale != store.replyLocale ||
      city != store.businessCity;

  /// Only the fields that differ from [store], in API names.
  Map<String, Object> changesFrom(Store store, StoreDraft draft) => {
    if (draft.name != store.name) 'name': draft.name,
    if (draft.contactPhone != store.contactPhone)
      'contact_phone': draft.contactPhone,
    if (draft.currency != store.currency)
      'currency': currencyCode(draft.currency),
    if (draft.replyLocale != store.replyLocale)
      'reply_locale': draft.replyLocale,
    if (draft.businessCity != store.businessCity)
      'business_city': draft.businessCity,
  };

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    otherCity.dispose();
    super.dispose();
  }
}

class StoreBasicsForm extends StatelessWidget {
  const StoreBasicsForm({
    super.key,
    required this.values,
    this.enabled = true,
    this.currencyLocked = false,
  });

  final StoreBasicsValues values;
  final bool enabled;
  final bool currencyLocked;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: values,
      builder: (context, _) {
        final issues = values.issues;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextField(
              label: l10n.fieldStoreName,
              controller: values.name,
              helper: l10n.storeNameHelper,
              enabled: enabled,
              textInputAction: TextInputAction.next,
              error: fieldIssueText(l10n, 'name', issues['name']),
            ),
            const SizedBox(height: Space.s16),
            AppTextField(
              label: l10n.fieldContactPhone,
              controller: values.phone,
              helper: l10n.phoneHelper(phoneExample),
              ltr: true,
              enabled: enabled,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              error: fieldIssueText(l10n, 'phone', issues['phone']),
            ),
            const SizedBox(height: Space.s24),
            _Labelled(
              label: l10n.fieldCurrency,
              helper: currencyLocked
                  ? l10n.currencyLockedNote
                  : l10n.currencyHelper,
              child: currencyLocked
                  ? Text(
                      values.currency == Currency.usd
                          ? l10n.currencyUsd
                          : l10n.currencyIqd,
                      style: context.type.bodyStrong,
                    )
                  : AbsorbPointer(
                      absorbing: !enabled,
                      child: AppSegmented<Currency>(
                        options: [
                          (Currency.iqd, l10n.currencyIqd),
                          (Currency.usd, l10n.currencyUsd),
                        ],
                        selected: values.currency,
                        onChanged: (c) => values.set(() => values.currency = c),
                      ),
                    ),
            ),
            const SizedBox(height: Space.s24),
            _Labelled(
              label: l10n.fieldReplyLanguage,
              helper: l10n.replyLanguageHelper,
              child: AbsorbPointer(
                absorbing: !enabled,
                child: AppSegmented<String>(
                  options: [
                    ('ckb', l10n.languageSorani),
                    ('en', l10n.languageEnglish),
                  ],
                  selected: values.replyLocale,
                  onChanged: (v) => values.set(() => values.replyLocale = v),
                ),
              ),
            ),
            const SizedBox(height: Space.s24),
            _Labelled(
              label: l10n.fieldBusinessCity,
              error: fieldIssueText(l10n, 'city', issues['city']),
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                child: Column(
                  children: [
                    for (final key in [...suggestedCities, otherCityKey])
                      SelectionRow(
                        label: key == otherCityKey
                            ? l10n.cityOther
                            : cityLabel(l10n, key),
                        selected: values.cityKey == key,
                        onTap: enabled
                            ? () => values.set(() => values.cityKey = key)
                            : () {},
                      ),
                  ],
                ),
              ),
            ),
            if (values.cityKey == otherCityKey) ...[
              const SizedBox(height: Space.s12),
              AppTextField(
                label: l10n.fieldOtherCity,
                controller: values.otherCity,
                enabled: enabled,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled({
    required this.label,
    required this.child,
    this.helper,
    this.error,
  });

  final String label;
  final Widget child;
  final String? helper;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: type.label.copyWith(color: p.textSecondary)),
        const SizedBox(height: Space.s8),
        child,
        if (error != null || helper != null) ...[
          const SizedBox(height: Space.s4),
          Semantics(
            liveRegion: error != null,
            child: Text(
              error ?? helper!,
              style: type.caption.copyWith(
                color: error != null ? p.dangerFg : p.textSecondary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Payment methods (AU-09, ST-04). At least one stays on (server-enforced).
class PaymentSwitches extends StatelessWidget {
  const PaymentSwitches({
    super.key,
    required this.cod,
    required this.other,
    required this.onChanged,
  });

  final bool cod;
  final bool other;

  /// Null disables both switches (while saving).
  final void Function({required bool cod, required bool other})? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final change = onChanged;
    return Column(
      children: [
        SwitchRow(
          label: l10n.paymentCod,
          description: l10n.paymentCodBody,
          value: cod,
          onChanged: change == null
              ? null
              : (v) => change(cod: v, other: other),
        ),
        SwitchRow(
          label: l10n.paymentOther,
          description: l10n.paymentOtherBody,
          value: other,
          onChanged: change == null ? null : (v) => change(cod: cod, other: v),
        ),
      ],
    );
  }
}

/// Fee and optional delivery-time fields for one zone (AU-08, ST-03).
class ZoneFields extends StatelessWidget {
  const ZoneFields({
    super.key,
    required this.feeLabel,
    required this.fee,
    required this.time,
    required this.currency,
    this.feeError,
    this.enabled = true,
  });

  final String feeLabel;
  final TextEditingController fee;
  final TextEditingController time;
  final Currency currency;
  final String? feeError;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final unit = currency == Currency.usd ? 'USD' : l10n.currencyIqd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTextField(
          label: feeLabel,
          controller: fee,
          ltr: true,
          enabled: enabled,
          keyboardType: TextInputType.number,
          error: feeError,
          suffix: Padding(
            padding: const EdgeInsetsDirectional.only(end: Space.s12),
            child: Center(
              widthFactor: 1,
              child: Text(unit, style: context.type.label),
            ),
          ),
        ),
        const SizedBox(height: Space.s12),
        AppTextField(
          label: l10n.fieldDeliveryTime,
          controller: time,
          helper: l10n.deliveryTimeHelper,
          enabled: enabled,
        ),
      ],
    );
  }
}
