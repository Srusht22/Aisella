import 'package:flutter/foundation.dart';

import '../../../core/formatting/money.dart';

/// SAMPLE DATA for the OR-02 design preview only. Real drafts arrive with
/// order management (Phase 7) and AI drafting (Phase 8). Names, phone and
/// prices are fictional (Phase 2 §14).
@immutable
class SampleDraft {
  const SampleDraft({
    required this.number,
    required this.source,
    required this.customerName,
    required this.phoneE164,
    required this.city,
    required this.area,
    required this.productName,
    required this.size,
    required this.quantity,
    required this.inferredFrom,
    required this.unitPrice,
    required this.stock,
    required this.deliveryFee,
    required this.currency,
  });

  final int number;
  final String source;
  final String customerName;
  final String phoneE164;
  final String city;
  final String area;
  final String productName;
  final String size;
  final int quantity;
  final String inferredFrom;
  final int unitPrice;
  final int stock;
  final int deliveryFee;
  final Currency currency;

  int get subtotal => quantity * unitPrice;
  int get total => subtotal + deliveryFee;
}

const sampleDraft = SampleDraft(
  number: 1042,
  source: 'Instagram',
  customerName: 'Nzar Ahmad',
  phoneE164: '+9647501234567',
  city: 'Erbil',
  area: 'Ankawa',
  productName: 'Beige Abaya',
  size: 'M',
  quantity: 2,
  inferredFrom: 'for me and my sister',
  unitPrice: 35000,
  stock: 4,
  deliveryFee: 5000,
  currency: Currency.iqd,
);
