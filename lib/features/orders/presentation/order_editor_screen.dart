import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/formatting/bidi.dart';
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
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../store/application/workspace_controller.dart';
import '../../store/domain/store.dart';
import '../application/order_providers.dart';
import '../domain/order.dart';
import '../domain/order_draft.dart';
import 'order_sheets.dart';
import 'order_text.dart';
import 'order_widgets.dart';
import 'product_picker_sheet.dart';

/// OR-06 Order editor: a new manual order, a draft, or an approved order
/// before dispatch. The server prices lines, takes the zone fee, computes
/// totals and decides draft or pending approval; saving never approves.
class OrderEditorScreen extends ConsumerWidget {
  const OrderEditorScreen({super.key, this.orderId});

  /// Null for a new order.
  final String? orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final zones = ref.watch(zonesProvider);
    final id = orderId;
    final order = id == null ? null : ref.watch(orderProvider(id));
    Widget scaffold(Widget body) => Scaffold(
      appBar: AppBar(title: Text(id == null ? l10n.newOrder : l10n.editOrder)),
      body: body,
    );

    if (order case AsyncError(:final error)) {
      return scaffold(
        ErrorState(
          cause: orderLoadErrorText(l10n, error),
          onRetry: () => ref.invalidate(orderProvider(id!)),
        ),
      );
    }
    if (zones case AsyncError(:final error)) {
      return scaffold(
        ErrorState(
          cause: orderLoadErrorText(l10n, error),
          onRetry: () => ref.invalidate(zonesProvider),
        ),
      );
    }
    final loaded = order?.value;
    if (!zones.hasValue || (id != null && loaded == null)) {
      return scaffold(const Center(child: CircularProgressIndicator()));
    }
    if (loaded != null &&
        !loaded.status.isDraftLike &&
        !loaded.status.beforeDispatch) {
      // Edit after dispatch is impossible (BR-33): say so instead.
      return scaffold(
        EmptyState(
          icon: AppIcons.lockKey,
          title: l10n.editNotPossibleTitle,
          body: l10n.editNotPossibleBody(statusLabel(l10n, loaded.status)),
        ),
      );
    }
    return _Editor(
      key: ValueKey(loaded?.id),
      order: loaded,
      zones: zones.value!,
    );
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({super.key, required this.order, required this.zones});

  final Order? order;
  final List<DeliveryZone> zones;

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  final _intent = IntentKey();
  late OrderDraft _initial;
  late OrderDraft _draft;
  bool _busy = false;
  bool _saved = false;
  String? _error;
  Map<String, String> _fields = const {};

  late final _name = TextEditingController();
  late final _phone = TextEditingController();
  late final _phone2 = TextEditingController();
  late final _city = TextEditingController();
  late final _fee = TextEditingController();
  late final _area = TextEditingController();
  late final _landmark = TextEditingController();
  late final _details = TextEditingController();
  late final _paymentNote = TextEditingController();
  late final _discount = TextEditingController();
  late final _customerNote = TextEditingController();
  late final _internalNote = TextEditingController();

  /// "Other place" chosen instead of a zone.
  bool _otherPlace = false;

  /// The seller types the fee instead of the zone's.
  bool _feeOverride = false;

  Order? get _order => widget.order;
  bool get _isNew => _order == null;
  bool get _approved => _order?.status.beforeDispatch ?? false;

  @override
  void initState() {
    super.initState();
    final store = ref.read(workspaceProvider).value?.store;
    _initial = _order == null
        ? OrderDraft(
            paymentMethod: (store?.codEnabled ?? true)
                ? PaymentMethod.cod
                : PaymentMethod.other,
          )
        : OrderDraft.fromOrder(_order!);
    _draft = _initial;
    _name.text = _draft.customerName;
    _phone.text = _draft.customerPhone;
    _phone2.text = _draft.customerPhone2;
    _city.text = _draft.cityText;
    _fee.text = _draft.deliveryFee?.toString() ?? '';
    _area.text = _draft.area;
    _landmark.text = _draft.landmark;
    _details.text = _draft.addressDetails;
    _paymentNote.text = _draft.paymentNote;
    _discount.text = _draft.discount == 0 ? '' : '${_draft.discount}';
    _customerNote.text = _draft.customerNote;
    _internalNote.text = _draft.internalNote;
    _otherPlace = _draft.zoneId == null && _draft.cityText.isNotEmpty;
    _feeOverride = _draft.zoneId != null && _draft.deliveryFee != null;
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _phone,
      _phone2,
      _city,
      _fee,
      _area,
      _landmark,
      _details,
      _paymentNote,
      _discount,
      _customerNote,
      _internalNote,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The draft from the form fields (lines and choices are kept in _draft).
  OrderDraft _collect() => _draft.copyWith(
    customerName: _name.text,
    customerPhone: _phone.text,
    customerPhone2: _phone2.text,
    zoneId: () => _otherPlace ? null : _draft.zoneId,
    cityText: _otherPlace ? _city.text : '',
    deliveryFee: () =>
        _otherPlace || _feeOverride ? parseAmount(_fee.text) : null,
    area: _area.text,
    landmark: _landmark.text,
    addressDetails: _details.text,
    paymentNote: _paymentNote.text,
    discount: parseAmount(_discount.text) ?? 0,
    customerNote: _customerNote.text,
    internalNote: _internalNote.text,
  );

  void _changed() => setState(() => _draft = _collect());

  bool get _dirty => !_saved && _collect() != _initial;

  DeliveryZone? get _zone =>
      widget.zones.where((z) => z.id == _draft.zoneId).firstOrNull;

  Future<void> _addItem() async {
    final line = await showProductPicker(context);
    if (line == null || !mounted) return;
    setState(() => _draft = _collect().addLine(line));
  }

  String? _fieldText(String key) {
    final l10n = context.l10n;
    final code = _fields[key];
    if (code == null) return null;
    return switch ((key, code)) {
      ('customer_phone' || 'customer_phone2', _) => l10n.errPhoneInvalid(
        '0750 123 4567',
      ),
      ('discount', 'exceeds_subtotal') => l10n.errDiscountTooHigh,
      ('zone_id', _) => l10n.errZoneUnavailable,
      (_, 'too_long') => l10n.errTooLong,
      (_, 'unavailable') => l10n.lineNotSold,
      _ => l10n.errValueInvalid,
    };
  }

  Future<void> _save({bool thenApprove = false}) async {
    if (_busy) return;
    final l10n = context.l10n;
    final digits = ref.read(settingsProvider).digits;
    final draft = _collect();
    final local = draft.fieldErrors;
    setState(() {
      _draft = draft;
      _fields = local;
      _error = local.isEmpty ? null : l10n.errFormIssues(local.length);
    });
    if (local.isNotEmpty) return;
    setState(() => _busy = true);
    final actions = ref.read(orderActionsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      final key = _intent.forPayload(draft.canonical);
      final Order saved;
      var stockNote = '';
      if (_isNew) {
        saved = await actions.create(draft, idempotencyKey: key);
      } else if (_approved) {
        final (o, diff) = await actions.editApproved(
          _order!,
          draft,
          idempotencyKey: key,
        );
        saved = o;
        if (diff.isNotEmpty) {
          stockNote = ' · ${l10n.stockAdjustedCount(diff.length)}';
        }
      } else {
        saved = await actions.updateDraft(_order!, draft, idempotencyKey: key);
      }
      _saved = true;
      _intent.reset();
      if (!mounted) return;
      showSnackOn(
        messenger,
        _isNew
            ? (saved.status == OrderStatus.draft
                  ? l10n.savedAsDraft
                  : l10n.orderSavedNeedsApproval)
            : '${l10n.changesSaved}$stockNote',
      );
      if (_isNew) {
        // Approval still goes through the confirmation sheet (BR-31).
        if (thenApprove && saved.canApprove) {
          await showApproveSheet(context, saved);
        }
        unawaited(router.pushReplacement(Routes.order(saved.id)));
      } else {
        router.pop();
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (e.code == ApiErrorCode.validationFailed && e.fields.isNotEmpty) {
          _fields = e.fields;
          _error = orderErrorText(l10n, e, digits: digits);
          if (_error == l10n.errSaveFailed) {
            _error = l10n.errFormIssues(e.fields.length);
          }
        } else if (e.code == ApiErrorCode.insufficientStock) {
          final lines = e.detailList('lines');
          _error = l10n.errEditShort(
            lines
                .map((x) {
                  final i = x['index'] as int?;
                  final name = i != null && i < draft.lines.length
                      ? itemName(draft.lines[i].name, draft.lines[i].label)
                      : '';
                  return '$name ${l10n.errOnlyInStock(count(x['available'] as int? ?? 0, digits))}';
                })
                .join(', '),
          );
        } else {
          _error = orderErrorText(l10n, e, digits: digits);
        }
      });
      if (e.code == ApiErrorCode.conflictVersion && !_isNew) {
        ref.invalidate(orderProvider(_order!.id));
        showSnackOn(messenger, l10n.errConflictReloaded);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final store = ref.watch(workspaceProvider).value?.store;
    final currency = storeCurrency(ref);
    String m(int v) => money(context, v, currency, digits);
    final zone = _zone;
    final missing = _draft.missing;
    final total = _draft.totalFor(zone?.fee);

    final fields = <Widget>[
      if (_error != null) ...[
        AppBanner(
          tone: Tone.danger,
          icon: AppIcons.warningCircle,
          title: _error!,
        ),
        const SizedBox(height: Space.s16),
      ],
      if (_approved) ...[
        AppBanner(
          tone: Tone.info,
          icon: AppIcons.info,
          title: l10n.editApprovedNote,
        ),
        const SizedBox(height: Space.s16),
      ],
      SectionHeader(l10n.sectionCustomer),
      AppTextField(
        label: l10n.fieldName,
        controller: _name,
        enabled: !_busy,
        error: _fieldText('customer_name'),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: Space.s12),
      AppTextField(
        label: l10n.fieldPhone,
        helper: l10n.phoneHelper('0750 123 4567'),
        controller: _phone,
        ltr: true,
        keyboardType: TextInputType.phone,
        enabled: !_busy,
        error: _fieldText('customer_phone'),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: Space.s12),
      AppTextField(
        label: l10n.fieldPhone2Optional,
        controller: _phone2,
        ltr: true,
        keyboardType: TextInputType.phone,
        enabled: !_busy,
        error: _fieldText('customer_phone2'),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: Space.s24),
      SectionHeader(l10n.sectionDelivery),
      Wrap(
        spacing: Space.s8,
        runSpacing: Space.s8,
        children: [
          for (final z in widget.zones)
            ChoiceChip(
              label: Text('${Bidi.auto(z.name)} · ${m(z.fee)}'),
              selected: !_otherPlace && _draft.zoneId == z.id,
              showCheckmark: false,
              onSelected: _busy
                  ? null
                  : (_) => setState(() {
                      _otherPlace = false;
                      _draft = _collect().copyWith(zoneId: () => z.id);
                    }),
            ),
          ChoiceChip(
            label: Text(l10n.otherPlace),
            selected: _otherPlace,
            showCheckmark: false,
            onSelected: _busy
                ? null
                : (_) => setState(() {
                    _otherPlace = true;
                    _draft = _collect();
                  }),
          ),
        ],
      ),
      if (_fieldText('zone_id') case final e?) ...[
        const SizedBox(height: Space.s4),
        Text(e, style: type.caption.copyWith(color: p.dangerFg)),
      ],
      if (_otherPlace) ...[
        const SizedBox(height: Space.s12),
        AppTextField(
          label: l10n.fieldCityPlace,
          controller: _city,
          enabled: !_busy,
          error: _fieldText('city_text'),
          onChanged: (_) => _changed(),
        ),
      ],
      if (!_otherPlace && zone != null)
        SwitchRow(
          label: l10n.changeFeeForOrder,
          value: _feeOverride,
          onChanged: _busy
              ? null
              : (v) => setState(() {
                  _feeOverride = v;
                  if (v && _fee.text.isEmpty) _fee.text = '${zone.fee}';
                  _draft = _collect();
                }),
        ),
      if (_otherPlace || _feeOverride) ...[
        const SizedBox(height: Space.s12),
        AppTextField(
          label: l10n.fieldFee,
          controller: _fee,
          ltr: true,
          keyboardType: TextInputType.number,
          enabled: !_busy,
          error: _fieldText('delivery_fee'),
          onChanged: (_) => _changed(),
        ),
      ],
      const SizedBox(height: Space.s12),
      AppTextField(
        label: l10n.fieldArea,
        controller: _area,
        enabled: !_busy,
        error: _fieldText('area'),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: Space.s12),
      AppTextField(
        label: l10n.fieldLandmarkOptional,
        controller: _landmark,
        enabled: !_busy,
        error: _fieldText('landmark'),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: Space.s12),
      AppTextField(
        label: l10n.fieldAddressDetailsOptional,
        controller: _details,
        maxLines: 2,
        enabled: !_busy,
        error: _fieldText('address_details'),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: Space.s24),
      SectionHeader(
        l10n.sectionItems,
        action: AppButton(
          label: l10n.addItem,
          icon: AppIcons.plus,
          variant: AppButtonVariant.tertiary,
          onPressed: _busy || _draft.lines.length >= maxOrderLines
              ? null
              : _addItem,
        ),
      ),
      if (_draft.lines.isEmpty)
        RowGroup(
          children: [
            Padding(
              padding: const EdgeInsets.all(Space.s12),
              child: Text(
                l10n.noItemsYet,
                style: type.body.copyWith(color: p.textTertiary),
              ),
            ),
          ],
        )
      else
        RowGroup(
          children: [
            for (final (i, line) in _draft.lines.indexed)
              _EditableLine(
                key: ValueKey(line.variantId),
                line: line,
                held: _approved,
                enabled: !_busy,
                error:
                    _fieldText('lines.$i.quantity') ??
                    _fieldText('lines.$i.variant_id'),
                onQuantity: (q) => setState(
                  () => _draft = _collect().setQuantity(line.variantId, q),
                ),
                onRemove: () => setState(
                  () => _draft = _collect().removeLine(line.variantId),
                ),
              ),
          ],
        ),
      const SizedBox(height: Space.s24),
      SectionHeader(l10n.sectionPayment),
      if (store != null && store.codEnabled && store.otherPaymentEnabled)
        AppSegmented<PaymentMethod?>(
          options: [
            (PaymentMethod.cod, l10n.paymentCod),
            (PaymentMethod.other, l10n.paymentOther),
          ],
          selected: _draft.paymentMethod,
          onChanged: _busy
              ? (_) {}
              : (v) => setState(
                  () => _draft = _collect().copyWith(paymentMethod: () => v),
                ),
        )
      else
        Text(
          _draft.paymentMethod == PaymentMethod.other
              ? l10n.paymentOther
              : l10n.paymentCod,
          style: type.body.copyWith(color: p.textPrimary),
        ),
      if (_draft.paymentMethod == PaymentMethod.other) ...[
        const SizedBox(height: Space.s12),
        AppTextField(
          label: l10n.fieldPaymentNote,
          controller: _paymentNote,
          enabled: !_busy,
          error: _fieldText('payment_note'),
          onChanged: (_) => _changed(),
        ),
      ],
      const SizedBox(height: Space.s12),
      AppTextField(
        label: l10n.fieldDiscountOptional,
        controller: _discount,
        ltr: true,
        keyboardType: TextInputType.number,
        enabled: !_busy,
        error: _fieldText('discount'),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: Space.s24),
      SectionHeader(l10n.sectionNotes),
      AppTextField(
        label: l10n.fieldCustomerNoteOptional,
        controller: _customerNote,
        maxLines: 2,
        enabled: !_busy,
        error: _fieldText('customer_note'),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: Space.s12),
      AppTextField(
        label: l10n.fieldInternalNoteOptional,
        helper: l10n.internalNoteHelper,
        controller: _internalNote,
        maxLines: 2,
        enabled: !_busy,
        error: _fieldText('internal_note'),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: Space.s24),
      SectionHeader(l10n.sectionTotal),
      RowGroup(
        children: [
          PriceRow(label: l10n.subtotal, amount: m(_draft.subtotal)),
          if (_draft.discount > 0)
            PriceRow(label: l10n.discount, amount: '− ${m(_draft.discount)}'),
          PriceRow(
            label: l10n.deliveryFee,
            amount: _draft.feeFor(zone?.fee) == null
                ? l10n.notSet
                : m(_draft.feeFor(zone?.fee)!),
          ),
          PriceRow(
            label: l10n.totalEstimate,
            amount: m(total),
            emphasize: true,
          ),
        ],
      ),
      const SizedBox(height: Space.s8),
      Text(
        l10n.totalsByServer,
        style: type.caption.copyWith(color: p.textSecondary),
      ),
    ];

    final reason = missing.isEmpty
        ? null
        : l10n.stillMissing(
            missing.map((f) => missingText(l10n, f)).join(', '),
          );
    final StickyActionBar bar;
    if (_isNew) {
      bar = StickyActionBar(
        reason: reason == null ? null : ReasonLine(reason),
        secondary: AppButton(
          label: l10n.saveAsDraft,
          variant: AppButtonVariant.secondary,
          onPressed: _busy ? null : _save,
        ),
        primary: AppButton(
          label: l10n.saveAndApprove,
          loading: _busy,
          onPressed: missing.isEmpty ? () => _save(thenApprove: true) : null,
        ),
      );
    } else {
      bar = StickyActionBar(
        reason: _approved && reason != null ? ReasonLine(reason) : null,
        primary: AppButton(
          label: l10n.saveChanges,
          loading: _busy,
          onPressed: _approved && missing.isNotEmpty ? null : _save,
        ),
      );
    }

    return UnsavedChangesGuard(
      dirty: _dirty,
      child: Scaffold(
        backgroundColor: p.bgCanvas,
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text(
            _isNew
                ? l10n.newOrder
                : l10n.editOrderTitle(orderNumber(_order!.number)),
          ),
        ),
        body: ListView(
          padding: EdgeInsets.only(
            top: Space.s8,
            bottom: Space.s32 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          children: [
            ContentWidth(
              maxWidth: LayoutTokens.maxWidthForm,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: fields,
              ),
            ),
          ],
        ),
        bottomNavigationBar: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: bar,
        ),
      ),
    );
  }
}

class _EditableLine extends ConsumerWidget {
  const _EditableLine({
    super.key,
    required this.line,
    required this.held,
    required this.enabled,
    required this.onQuantity,
    required this.onRemove,
    this.error,
  });

  final DraftLine line;

  /// Approved order: the units the order holds count as available.
  final bool held;
  final bool enabled;
  final ValueChanged<int> onQuantity;
  final VoidCallback onRemove;
  final String? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final currency = storeCurrency(ref);
    final available = line.maxAvailable;
    final over = available != null && line.quantity > available;
    final change = held ? line.quantity - line.held : 0;
    return Padding(
      padding: const EdgeInsets.all(Space.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LineImage(path: line.imagePath),
              const SizedBox(width: Space.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      itemName(line.name, line.label),
                      style: type.bodyStrong.copyWith(color: p.textPrimary),
                    ),
                    Text(
                      money(context, line.unitPrice, currency, digits),
                      style: type.caption.copyWith(color: p.textSecondary),
                    ),
                    if (line.trackStock && line.stockOnHand != null)
                      StockIndicator(
                        state: over ? StockState.out : StockState.inStock,
                        label: over
                            ? l10n.errOnlyInStock(count(available, digits))
                            : l10n.stockInStock(
                                count(line.stockOnHand!, digits),
                              ),
                      ),
                    if (held && change != 0 && line.trackStock)
                      Text(
                        l10n.stockChangeOnSave(
                          Bidi.ltr(change > 0 ? '−$change' : '+${-change}'),
                        ),
                        style: type.caption.copyWith(color: p.textSecondary),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: l10n.removeItem,
                icon: const Icon(AppIcons.trash),
                onPressed: enabled ? onRemove : null,
              ),
            ],
          ),
          const SizedBox(height: Space.s8),
          QuantityStepper(
            value: line.quantity,
            enabled: enabled,
            onChanged: onQuantity,
          ),
          if (error != null)
            Text(error!, style: type.caption.copyWith(color: p.dangerFg)),
        ],
      ),
    );
  }
}
