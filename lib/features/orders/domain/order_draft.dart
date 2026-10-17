import 'package:flutter/foundation.dart';

import '../../../core/formatting/phone.dart';
import 'order.dart';

/// A line in the order editor. The display values (name, price, stock) are
/// what the seller saw when adding it; the server takes the variant and the
/// quantity only and prices the line itself.
@immutable
class DraftLine {
  const DraftLine({
    required this.variantId,
    required this.name,
    required this.label,
    required this.unitPrice,
    required this.quantity,
    this.trackStock = true,
    this.stockOnHand,
    this.held = 0,
    this.imagePath,
  });

  factory DraftLine.fromOrderLine(OrderLine l) => DraftLine(
    variantId: l.variantId!,
    name: l.name,
    label: l.variantLabel,
    unitPrice: l.unitPrice,
    quantity: l.quantity,
    trackStock: l.current?.trackStock ?? false,
    stockOnHand: l.current?.stockOnHand,
    held: l.stockDeducted,
    imagePath: l.imagePath,
  );

  final String variantId;
  final String name;
  final String label;
  final int unitPrice;
  final int quantity;
  final bool trackStock;

  /// Current stock when known (tracked products).
  final int? stockOnHand;

  /// Units this order already holds (approved orders), available to it.
  final int held;
  final String? imagePath;

  /// Units that can be put on this line without going below zero.
  int? get maxAvailable =>
      trackStock && stockOnHand != null ? stockOnHand! + held : null;

  DraftLine withQuantity(int q) => DraftLine(
    variantId: variantId,
    name: name,
    label: label,
    unitPrice: unitPrice,
    quantity: q,
    trackStock: trackStock,
    stockOnHand: stockOnHand,
    held: held,
    imagePath: imagePath,
  );
}

/// Quantity bounds (BR-37) and the soft warning threshold.
const minLineQuantity = 1;
const maxLineQuantity = 999;
const largeQuantityWarning = 20;
const maxOrderLines = 50;

/// What the seller is editing: a new manual order, a draft, or an approved
/// order before dispatch (OR-06). Sent to the server as the full state; the
/// server computes status, prices, fee snapshot and totals.
@immutable
class OrderDraft {
  const OrderDraft({
    this.customerName = '',
    this.customerPhone = '',
    this.customerPhone2 = '',
    this.zoneId,
    this.cityText = '',
    this.area = '',
    this.landmark = '',
    this.addressDetails = '',
    this.deliveryFee,
    this.paymentMethod,
    this.paymentNote = '',
    this.discount = 0,
    this.customerNote = '',
    this.internalNote = '',
    this.lines = const [],
  });

  factory OrderDraft.fromOrder(Order o) => OrderDraft(
    customerName: o.customerName ?? '',
    customerPhone: o.customerPhone ?? '',
    customerPhone2: o.customerPhone2 ?? '',
    zoneId: o.zoneId,
    cityText: o.cityText ?? '',
    area: o.area ?? '',
    landmark: o.landmark ?? '',
    addressDetails: o.addressDetails ?? '',
    deliveryFee: o.feeFromSeller ? o.deliveryFee : null,
    paymentMethod: o.paymentMethod,
    paymentNote: o.paymentNote ?? '',
    discount: o.discount,
    customerNote: o.customerNote ?? '',
    internalNote: o.internalNote ?? '',
    lines: [
      for (final l in o.lines)
        if (l.variantId != null) DraftLine.fromOrderLine(l),
    ],
  );

  final String customerName;

  /// As typed (any Iraqi mobile format); normalised when sent.
  final String customerPhone;
  final String customerPhone2;
  final String? zoneId;

  /// A place outside the zones (requires a fee from the seller).
  final String cityText;
  final String area;
  final String landmark;
  final String addressDetails;

  /// The seller's fee; null takes the zone's fee.
  final int? deliveryFee;
  final PaymentMethod? paymentMethod;
  final String paymentNote;
  final int discount;
  final String customerNote;
  final String internalNote;
  final List<DraftLine> lines;

  OrderDraft copyWith({
    String? customerName,
    String? customerPhone,
    String? customerPhone2,
    String? Function()? zoneId,
    String? cityText,
    String? area,
    String? landmark,
    String? addressDetails,
    int? Function()? deliveryFee,
    PaymentMethod? Function()? paymentMethod,
    String? paymentNote,
    int? discount,
    String? customerNote,
    String? internalNote,
    List<DraftLine>? lines,
  }) => OrderDraft(
    customerName: customerName ?? this.customerName,
    customerPhone: customerPhone ?? this.customerPhone,
    customerPhone2: customerPhone2 ?? this.customerPhone2,
    zoneId: zoneId != null ? zoneId() : this.zoneId,
    cityText: cityText ?? this.cityText,
    area: area ?? this.area,
    landmark: landmark ?? this.landmark,
    addressDetails: addressDetails ?? this.addressDetails,
    deliveryFee: deliveryFee != null ? deliveryFee() : this.deliveryFee,
    paymentMethod: paymentMethod != null ? paymentMethod() : this.paymentMethod,
    paymentNote: paymentNote ?? this.paymentNote,
    discount: discount ?? this.discount,
    customerNote: customerNote ?? this.customerNote,
    internalNote: internalNote ?? this.internalNote,
    lines: lines ?? this.lines,
  );

  /// Adds [line], or adds its quantity to the existing line of the variant.
  OrderDraft addLine(DraftLine line) {
    final i = lines.indexWhere((l) => l.variantId == line.variantId);
    if (i < 0) return copyWith(lines: [...lines, line]);
    final merged = (lines[i].quantity + line.quantity).clamp(
      minLineQuantity,
      maxLineQuantity,
    );
    return copyWith(
      lines: [
        for (var j = 0; j < lines.length; j++)
          j == i ? lines[j].withQuantity(merged) : lines[j],
      ],
    );
  }

  OrderDraft setQuantity(String variantId, int quantity) => copyWith(
    lines: [
      for (final l in lines)
        l.variantId == variantId ? l.withQuantity(quantity) : l,
    ],
  );

  OrderDraft removeLine(String variantId) => copyWith(
    lines: [
      for (final l in lines)
        if (l.variantId != variantId) l,
    ],
  );

  /// Preview only (the server computes the saved totals).
  int get subtotal => lines.fold(0, (s, l) => s + l.unitPrice * l.quantity);

  int? feeFor(int? zoneFee) => deliveryFee ?? (zoneId != null ? zoneFee : null);

  int totalFor(int? zoneFee) => subtotal - discount + (feeFor(zoneFee) ?? 0);

  String? get _phone => _normalised(customerPhone);
  String? get _phone2 => _normalised(customerPhone2);

  static String? _normalised(String raw) => raw.trim().isEmpty
      ? null
      : PhoneNumbers.normalizeIraqMobile(raw) ?? raw.trim();

  /// Field errors the app can tell before sending (the server checks again).
  /// Keys match the server's (`lines.<i>.quantity`).
  Map<String, String> get fieldErrors {
    final e = <String, String>{};
    if (customerName.trim().length > 80) e['customer_name'] = 'too_long';
    if (customerPhone.trim().isNotEmpty &&
        PhoneNumbers.normalizeIraqMobile(customerPhone) == null) {
      e['customer_phone'] = 'invalid';
    }
    if (customerPhone2.trim().isNotEmpty &&
        PhoneNumbers.normalizeIraqMobile(customerPhone2) == null) {
      e['customer_phone2'] = 'invalid';
    }
    if (cityText.trim().length > 60) e['city_text'] = 'too_long';
    if (area.trim().length > 80) e['area'] = 'too_long';
    if (landmark.trim().length > 120) e['landmark'] = 'too_long';
    if (addressDetails.trim().length > 300) e['address_details'] = 'too_long';
    if (deliveryFee != null && (deliveryFee! < 0 || deliveryFee! > 10000000)) {
      e['delivery_fee'] = 'invalid';
    }
    if (discount < 0) e['discount'] = 'invalid';
    if (discount > subtotal) e['discount'] = 'exceeds_subtotal';
    if (customerNote.trim().length > 500) e['customer_note'] = 'too_long';
    if (internalNote.trim().length > 500) e['internal_note'] = 'too_long';
    if (lines.length > maxOrderLines) e['lines'] = 'too_many';
    for (var i = 0; i < lines.length; i++) {
      final q = lines[i].quantity;
      if (q < minLineQuantity || q > maxLineQuantity) {
        e['lines.$i.quantity'] = 'out_of_range';
      }
    }
    return e;
  }

  /// What would still be missing for approval (BR-36), in the server's
  /// order. A preview: the server decides draft or pending approval.
  List<String> get missing => [
    if (customerName.trim().isEmpty) 'customer_name',
    if (_phone == null) 'customer_phone',
    if (zoneId == null && cityText.trim().isEmpty) 'zone',
    if (area.trim().isEmpty) 'area',
    if (zoneId == null && deliveryFee == null) 'delivery_fee',
    if (paymentMethod == null) 'payment_method',
    if (lines.isEmpty) 'lines',
  ];

  /// The request body (`p_order`). Only documented fields; never a status,
  /// price or total.
  Map<String, dynamic> toJson() {
    String? t(String v) => v.trim().isEmpty ? null : v.trim();
    return {
      'customer_name': t(customerName),
      'customer_phone': _phone,
      'customer_phone2': _phone2,
      'zone_id': zoneId,
      'city_text': t(cityText),
      'area': t(area),
      'landmark': t(landmark),
      'address_details': t(addressDetails),
      'delivery_fee': deliveryFee,
      'payment_method': paymentMethod?.wire,
      'payment_note': paymentMethod == PaymentMethod.other
          ? t(paymentNote)
          : null,
      'discount': discount,
      'customer_note': t(customerNote),
      'internal_note': t(internalNote),
      'lines': [
        for (final l in lines)
          {'variant_id': l.variantId, 'quantity': l.quantity},
      ],
    }..removeWhere((_, v) => v == null);
  }

  /// Canonical form: one idempotency key per unchanged request.
  String get canonical => toJson().toString();

  @override
  bool operator ==(Object other) =>
      other is OrderDraft && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;
}
