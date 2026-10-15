import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/route_guard.dart';
import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/formatting/money.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/motion/primitives.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/api_error_text.dart';
import '../../common/form_page.dart';
import '../../common/form_widgets.dart';
import '../../common/store_forms.dart';
import '../../store/application/workspace_controller.dart';
import '../../store/domain/store.dart';
import '../../store/domain/store_validation.dart';

const _steps = 3;

/// Shared frame: "Step n of 3" with a progress bar (Phase 2 AU-07..09).
class _SetupFrame extends StatelessWidget {
  const _SetupFrame({
    required this.step,
    required this.title,
    required this.children,
    required this.bottom,
    this.body,
    this.canGoBack = false,
  });

  final int step;
  final String title;
  final String? body;
  final List<Widget> children;
  final Widget bottom;
  final bool canGoBack;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    return FormPage(
      showBack: canGoBack,
      title: l10n.setupStep(step, _steps),
      appBarBottom: PreferredSize(
        preferredSize: const Size.fromHeight(4),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: step / _steps),
          duration: const Duration(milliseconds: 240),
          builder: (context, value, _) => LinearProgressIndicator(
            value: value,
            minHeight: 4,
            color: p.brandPrimary,
            backgroundColor: p.bgSunken,
            semanticsLabel: l10n.setupStep(step, _steps),
          ),
        ),
      ),
      bottom: bottom,
      children: [
        FormHeading(title: title, body: body),
        ...children,
      ],
    );
  }
}

/// AU-07 Store basics: creates the store (Phase 1 US-005).
class SetupStoreScreen extends ConsumerStatefulWidget {
  const SetupStoreScreen({super.key});

  @override
  ConsumerState<SetupStoreScreen> createState() => _SetupStoreScreenState();
}

class _SetupStoreScreenState extends ConsumerState<SetupStoreScreen> {
  late final _values = StoreBasicsValues(
    defaultReplyLocale: Localizations.localeOf(context).languageCode == 'en'
        ? 'en'
        : 'ckb',
  );
  final _intent = IntentKey();
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    _values.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy) return;
    final draft = _values.validate();
    setState(() => _error = null);
    if (draft == null) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(workspaceProvider.notifier)
          .createStore(
            draft,
            idempotencyKey: _intent.forPayload(draft.canonical),
          );
      // Success: the router moves to the next step when the store exists.
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ApiErrorCode.validationFailed && e.fields.isNotEmpty) {
        _values.applyServerIssues(e.fields);
      } else {
        setState(() => _error = e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _SetupFrame(
      step: 1,
      title: l10n.setupStoreTitle,
      bottom: formActions(
        primary: AppButton(
          label: l10n.continueAction,
          loadingLabel: l10n.creatingStore,
          loading: _busy,
          expand: true,
          onPressed: _create,
        ),
      ),
      children: [
        if (_error != null)
          FormErrorBanner(message: apiErrorText(l10n, _error!)),
        StoreBasicsForm(values: _values, enabled: !_busy),
      ],
    );
  }
}

/// One suggested or custom zone being set up in AU-08.
class _ZoneDraft {
  _ZoneDraft({required this.label, this.custom = false, this.enabled = false});

  final String label;
  final bool custom;
  bool enabled;
  final name = TextEditingController();
  final fee = TextEditingController();
  final time = TextEditingController();
  final intent = IntentKey();
  FieldIssue? nameIssue;
  FieldIssue? feeIssue;

  /// Set once the server saved it, so a retry never sends it again.
  DeliveryZone? saved;

  String get zoneName => custom ? name.text.trim() : label;

  void dispose() {
    name.dispose();
    fee.dispose();
    time.dispose();
  }
}

/// AU-08 Delivery zones (Phase 1 US-006). Skippable; the checklist flags it.
class SetupZonesScreen extends ConsumerStatefulWidget {
  const SetupZonesScreen({super.key});

  @override
  ConsumerState<SetupZonesScreen> createState() => _SetupZonesScreenState();
}

class _SetupZonesScreenState extends ConsumerState<SetupZonesScreen> {
  List<_ZoneDraft>? _drafts;
  bool _busy = false;
  ApiException? _error;

  List<_ZoneDraft> _initDrafts(AppLocalizations l10n) => _drafts ??= [
    for (final key in suggestedCities) _ZoneDraft(label: cityLabel(l10n, key)),
  ];

  @override
  void dispose() {
    for (final d in _drafts ?? const <_ZoneDraft>[]) {
      d.dispose();
    }
    super.dispose();
  }

  Future<void> _continue({required bool skip}) async {
    if (_busy) return;
    final drafts = _drafts ?? const <_ZoneDraft>[];
    final existing = ref.read(zonesProvider).value ?? const <DeliveryZone>[];
    final pending = skip
        ? const <_ZoneDraft>[]
        : drafts.where((d) => d.enabled && d.saved == null).toList();

    // Client checks first: nothing is sent while any field is invalid.
    final taken = <String>[for (final z in existing) z.name];
    var valid = true;
    for (final d in pending) {
      d.nameIssue = validateZoneName(d.zoneName, taken: taken);
      final (_, feeIssue) = parseFee(d.fee.text);
      d.feeIssue = feeIssue;
      if (d.nameIssue != null || d.feeIssue != null) valid = false;
      taken.add(d.zoneName);
    }
    setState(() => _error = null);
    if (!valid) return;

    setState(() => _busy = true);
    try {
      final actions = ref.read(zoneActionsProvider);
      for (final d in pending) {
        final (fee, _) = parseFee(d.fee.text);
        final time = d.time.text.trim();
        final payload = '${d.zoneName}\u0000$fee\u0000$time';
        try {
          d.saved = await actions.save(
            name: d.zoneName,
            fee: fee!,
            timeText: time.isEmpty ? null : time,
            idempotencyKey: d.intent.forPayload(payload),
          );
        } on ApiException catch (e) {
          if (e.code == ApiErrorCode.validationFailed) {
            d.nameIssue = e.fields['name'] == null
                ? null
                : fieldIssueFromServer(e.fields['name']!);
            d.feeIssue = e.fields['fee'] == null ? null : FieldIssue.invalid;
          }
          rethrow;
        }
      }
      await ref
          .read(workspaceProvider.notifier)
          .advanceOnboarding(OnboardingStep.payments);
      // The router shows the next step.
      if (mounted && GoRouterState.of(context).uri.path == Routes.setupZones) {
        context.go(Routes.setupPayments);
      }
    } on ApiException catch (e) {
      if (mounted && e.code != ApiErrorCode.validationFailed) {
        setState(() => _error = e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final drafts = _initDrafts(l10n);
    final currency =
        ref.watch(workspaceProvider).value?.store?.currency ?? Currency.iqd;
    final existing = ref.watch(zonesProvider).value ?? const <DeliveryZone>[];

    return _SetupFrame(
      step: 2,
      title: l10n.setupZonesTitle,
      body: l10n.setupZonesBody,
      bottom: formActions(
        primary: AppButton(
          label: l10n.continueAction,
          loadingLabel: l10n.savingZones,
          loading: _busy,
          expand: true,
          onPressed: () => _continue(skip: false),
        ),
        secondary: AppButton(
          label: l10n.skipForNow,
          variant: AppButtonVariant.tertiary,
          onPressed: _busy ? null : () => _continue(skip: true),
        ),
      ),
      children: [
        if (_error != null)
          FormErrorBanner(message: apiErrorText(l10n, _error!)),
        if (existing.isNotEmpty) ...[
          RowGroup(
            children: [
              for (final z in existing)
                NavRow(
                  label: z.name,
                  icon: AppIcons.mapPin,
                  trailing: Text(
                    Money.format(
                      z.fee,
                      currency,
                      locale: Localizations.localeOf(context),
                      digits: ref.watch(settingsProvider).digits,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Space.s16),
        ],
        RowGroup(
          children: [
            for (final d in drafts)
              _ZoneDraftTile(
                draft: d,
                currency: currency,
                enabled: !_busy,
                onChanged: () => setState(() {}),
              ),
          ],
        ),
        const SizedBox(height: Space.s12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppButton(
            label: l10n.addAnotherArea,
            icon: AppIcons.plus,
            variant: AppButtonVariant.tertiary,
            onPressed: _busy
                ? null
                : () => setState(
                    () => drafts.add(
                      _ZoneDraft(label: '', custom: true, enabled: true),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: Space.s16),
        if (existing.isEmpty && drafts.every((d) => !d.enabled))
          AppBanner(
            tone: Tone.warning,
            icon: AppIcons.info,
            title: l10n.zonesWarning,
          ),
        Text(
          l10n.zoneFeeNote,
          style: context.type.caption.copyWith(color: p.textSecondary),
        ),
      ],
    );
  }
}

class _ZoneDraftTile extends StatelessWidget {
  const _ZoneDraftTile({
    required this.draft,
    required this.currency,
    required this.enabled,
    required this.onChanged,
  });

  final _ZoneDraft draft;
  final Currency currency;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final saved = draft.saved != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!draft.custom)
          SwitchRow(
            label: draft.label,
            description: saved ? l10n.zoneSaved : null,
            value: draft.enabled,
            onChanged: enabled && !saved
                ? (v) {
                    draft.enabled = v;
                    onChanged();
                  }
                : null,
          ),
        ExpandSection(
          expanded: draft.enabled && !saved,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              Space.s12,
              Space.s4,
              Space.s12,
              Space.s16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (draft.custom) ...[
                  AppTextField(
                    label: l10n.fieldAreaName,
                    controller: draft.name,
                    enabled: enabled,
                    error: fieldIssueText(l10n, 'zoneName', draft.nameIssue),
                    onChanged: (_) => onChanged(),
                  ),
                  const SizedBox(height: Space.s12),
                ] else if (draft.nameIssue != null) ...[
                  Text(
                    fieldIssueText(l10n, 'zoneName', draft.nameIssue)!,
                    style: context.type.caption.copyWith(
                      color: context.palette.dangerFg,
                    ),
                  ),
                  const SizedBox(height: Space.s8),
                ],
                ZoneFields(
                  feeLabel: l10n.fieldFeeFor(
                    draft.custom && draft.zoneName.isEmpty
                        ? l10n.fieldAreaName
                        : draft.zoneName,
                  ),
                  fee: draft.fee,
                  time: draft.time,
                  currency: currency,
                  enabled: enabled,
                  feeError: fieldIssueText(l10n, 'fee', draft.feeIssue),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// AU-09 Payments. Policies are deferred to the assistant's phase (stated
/// honestly on screen).
class SetupPaymentsScreen extends ConsumerStatefulWidget {
  const SetupPaymentsScreen({super.key});

  @override
  ConsumerState<SetupPaymentsScreen> createState() =>
      _SetupPaymentsScreenState();
}

class _SetupPaymentsScreenState extends ConsumerState<SetupPaymentsScreen> {
  bool? _cod;
  bool? _other;
  final _intent = IntentKey();
  bool _busy = false;
  ApiException? _error;
  bool _needOne = false;

  Future<void> _finish(Store store) async {
    if (_busy) return;
    final cod = _cod ?? store.codEnabled;
    final other = _other ?? store.otherPaymentEnabled;
    setState(() {
      _error = null;
      _needOne = !cod && !other;
    });
    if (_needOne) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final ready = context.l10n.storeReady;
    try {
      final workspace = ref.read(workspaceProvider.notifier);
      final changes = <String, Object>{
        if (cod != store.codEnabled) 'cod_enabled': cod,
        if (other != store.otherPaymentEnabled) 'other_payment_enabled': other,
      };
      if (changes.isNotEmpty) {
        await workspace.updateStore(
          changes: changes,
          idempotencyKey: _intent.forPayload('$cod/$other'),
        );
      }
      await workspace.advanceOnboarding(OnboardingStep.done);
      // Only now is the store set up: confirm, and the router opens Today.
      showSnackOn(messenger, ready);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ApiErrorCode.conflictVersion) {
        await _refreshQuietly(ref);
      }
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final store = ref.watch(workspaceProvider).value?.store;
    if (store == null) return const SizedBox.shrink();
    return _SetupFrame(
      step: 3,
      title: l10n.setupPaymentsTitle,
      canGoBack: false,
      bottom: formActions(
        primary: AppButton(
          label: l10n.finishSetup,
          loadingLabel: l10n.finishingSetup,
          loading: _busy,
          expand: true,
          onPressed: () => _finish(store),
        ),
        secondary: AppButton(
          label: l10n.back,
          variant: AppButtonVariant.tertiary,
          onPressed: _busy ? null : () => context.go(Routes.setupZones),
        ),
      ),
      children: [
        if (_error != null)
          FormErrorBanner(message: apiErrorText(l10n, _error!)),
        if (_needOne) FormErrorBanner(message: l10n.errPaymentAtLeastOne),
        RowGroup(
          children: [
            PaymentSwitches(
              cod: _cod ?? store.codEnabled,
              other: _other ?? store.otherPaymentEnabled,
              onChanged: _busy
                  ? null
                  : ({required cod, required other}) => setState(() {
                      _cod = cod;
                      _other = other;
                    }),
            ),
          ],
        ),
        const SizedBox(height: Space.s16),
        Text(
          l10n.policiesLater,
          style: context.type.body.copyWith(color: p.textSecondary),
        ),
      ],
    );
  }
}

/// Picks up the latest server state after a conflict without leaving the
/// screen. A failure here leaves the current values; the conflict message is
/// shown either way.
Future<void> _refreshQuietly(WidgetRef ref) async {
  try {
    await ref.read(workspaceProvider.notifier).refresh();
  } on ApiException {
    // Keep what is on screen.
  }
}
