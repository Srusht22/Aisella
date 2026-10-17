import 'package:flutter/foundation.dart';

import '../../../core/formatting/money.dart';

/// Orders as the server returns them (the contract of `api.get_order`,
/// `api.list_orders` and the order mutations; docs/implementation/phase-7).
/// Server state: never edited in place. Status, totals, fees and approval
/// come only from the server; the app never computes them for saving.

/// Order statuses (Phase 1 §6.4, D-05).
enum OrderStatus {
  draft('draft'),
  pendingApproval('pending_approval'),
  rejected('rejected'),
  approved('approved'),
  processing('processing'),
  dispatched('dispatched'),
  delivered('delivered'),
  deliveryFailed('delivery_failed'),
  returned('returned'),
  cancelled('cancelled');

  const OrderStatus(this.wire);
  final String wire;

  static OrderStatus parse(Object? v) =>
      values.firstWhere((s) => s.wire == v, orElse: () => draft);

  /// Not yet a commitment: editable, approvable or rejectable (OR-02).
  bool get isDraftLike => this == draft || this == pendingApproval;

  /// Approved and not yet dispatched: items can be edited, the order can be
  /// cancelled (BR-33, OR-09).
  bool get beforeDispatch => this == approved || this == processing;

  /// No further status change is possible.
  bool get isTerminal =>
      this == rejected || this == returned || this == cancelled;

  /// Approved and later, except closed ones: a confirmation may be copied
  /// (OR-10, BR-04).
  bool get canConfirm =>
      this == approved ||
      this == processing ||
      this == dispatched ||
      this == delivered ||
      this == deliveryFailed;

  /// Position on the four-step tracker (OR-05), or null for branch states.
  int? get trackerStep => switch (this) {
    approved => 0,
    processing => 1,
    dispatched => 2,
    delivered => 3,
    _ => null,
  };
}

/// Status chips of the order list (OR-01). Test orders are not shown in P0
/// (no sandbox conversations exist yet).
enum OrderFilter {
  all('all'),
  needsApproval('needs_approval'),
  drafts('drafts'),
  active('active'),
  delivered('delivered'),
  problems('problems'),
  closed('closed');

  const OrderFilter(this.wire);
  final String wire;
}

@immutable
class OrderQuery {
  const OrderQuery({this.text = '', this.filter = OrderFilter.all});

  final String text;
  final OrderFilter filter;

  OrderQuery copyWith({String? text, OrderFilter? filter}) =>
      OrderQuery(text: text ?? this.text, filter: filter ?? this.filter);

  bool get isFiltered => text.isNotEmpty || filter != OrderFilter.all;

  @override
  bool operator ==(Object other) =>
      other is OrderQuery && other.text == text && other.filter == filter;

  @override
  int get hashCode => Object.hash(text, filter);
}

/// Who did something, relative to the viewer.
enum Actor {
  you,
  member,
  system,

  /// The AI assistant (Phase 8): it can create and update drafts, never
  /// approve or change anything after approval.
  ai;

  static Actor parse(Object? v) => switch (v) {
    'you' => Actor.you,
    'member' => Actor.member,
    'ai' => Actor.ai,
    _ => Actor.system,
  };
}

/// How an order line is tied to the catalog (Phase 1 §8.4). Only manual and
/// unambiguous AI lines are [resolved]; the others wait for the seller.
enum LineResolution {
  resolved,

  /// Several products could match: the seller chooses (up to 3 candidates).
  chooseProduct,

  /// The product is clear but not the variant (size, colour…).
  variantNeeded,

  /// Nothing in the catalog matches what the customer asked for.
  notInCatalog;

  static LineResolution parse(Object? v) => switch (v) {
    'choose_product' => LineResolution.chooseProduct,
    'variant_needed' => LineResolution.variantNeeded,
    'not_in_catalog' => LineResolution.notInCatalog,
    _ => LineResolution.resolved,
  };
}

/// A catalog variant the AI proposed for an unresolved line.
@immutable
class LineCandidate {
  const LineCandidate({
    required this.variantId,
    required this.name,
    required this.variantLabel,
    required this.price,
    required this.available,
  });

  factory LineCandidate.fromJson(Map<String, dynamic> j) => LineCandidate(
    variantId: j['variant_id'] as String,
    name: j['name'] as String? ?? '',
    variantLabel: j['variant_label'] as String? ?? '',
    price: (j['price'] as num?)?.toInt() ?? 0,
    available: j['available'] == true,
  );

  final String variantId;
  final String name;
  final String variantLabel;
  final int price;
  final bool available;
}

/// A required field that is missing (BR-36). [itemId] for line issues.
@immutable
class OrderIssue {
  const OrderIssue(this.field, this.kind, {this.itemId});

  factory OrderIssue.fromJson(Map<String, dynamic> j) => OrderIssue(
    j['field'] as String? ?? '',
    j['kind'] as String? ?? 'missing',
    itemId: j['item_id'] as String?,
  );

  /// customer_name, customer_phone, zone, area, delivery_fee,
  /// payment_method or lines.
  final String field;

  /// missing, unresolved or quantity_inferred.
  final String kind;
  final String? itemId;

  @override
  bool operator ==(Object other) =>
      other is OrderIssue &&
      other.field == field &&
      other.kind == kind &&
      other.itemId == itemId;

  @override
  int get hashCode => Object.hash(field, kind, itemId);
}

/// The catalog as it is now for a line's variant (live, not a snapshot).
@immutable
class LiveVariant {
  const LiveVariant({
    required this.price,
    required this.stockOnHand,
    required this.trackStock,
    required this.available,
    required this.productActive,
    required this.variantActive,
    this.productArchived = false,
  });

  factory LiveVariant.fromJson(Map<String, dynamic> j) => LiveVariant(
    price: (j['price'] as num).toInt(),
    stockOnHand: (j['stock_on_hand'] as num?)?.toInt() ?? 0,
    trackStock: j['track_stock'] as bool? ?? true,
    available: j['available'] as bool? ?? true,
    productActive: j['product_status'] == 'active',
    productArchived: j['product_status'] == 'archived',
    variantActive: j['variant_status'] == 'active',
  );

  final int price;
  final int stockOnHand;
  final bool trackStock;
  final bool available;
  final bool productActive;
  final bool productArchived;
  final bool variantActive;

  /// Cannot be sold now (archived, inactive, or untracked and unavailable).
  bool get sellable =>
      productActive && variantActive && (trackStock || available);
}

/// What a return decided for a line.
typedef ReturnDecision = ({int restock, int writeOff});

@immutable
class OrderLine {
  const OrderLine({
    required this.id,
    required this.name,
    required this.variantLabel,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    required this.stockDeducted,
    this.variantId,
    this.productId,
    this.sku,
    this.quotedUnitPrice,
    this.approvedUnitPrice,
    this.imagePath,
    this.current,
    this.returned,
    this.resolution = LineResolution.resolved,
    this.customerText,
    this.quantityInferred = false,
    this.candidates = const [],
  });

  factory OrderLine.fromJson(Map<String, dynamic> j) {
    final ret = j['return'];
    return OrderLine(
      resolution: LineResolution.parse(j['resolution']),
      customerText: j['customer_text'] as String?,
      quantityInferred: j['quantity_basis'] == 'inferred',
      candidates: [
        for (final c in j['candidates'] as List? ?? const [])
          if (c is Map) LineCandidate.fromJson(c.cast<String, dynamic>()),
      ],
      id: j['id'] as String,
      variantId: j['variant_id'] as String?,
      productId: j['product_id'] as String?,
      name: j['name'] as String? ?? '',
      variantLabel: j['variant_label'] as String? ?? '',
      sku: j['sku'] as String?,
      quantity: (j['quantity'] as num).toInt(),
      quotedUnitPrice: (j['quoted_unit_price'] as num?)?.toInt(),
      approvedUnitPrice: (j['approved_unit_price'] as num?)?.toInt(),
      unitPrice: (j['unit_price'] as num?)?.toInt() ?? 0,
      lineTotal: (j['line_total'] as num?)?.toInt() ?? 0,
      stockDeducted: (j['stock_deducted'] as num?)?.toInt() ?? 0,
      imagePath: j['image_path'] as String?,
      current: j['current'] is Map
          ? LiveVariant.fromJson((j['current'] as Map).cast<String, dynamic>())
          : null,
      returned: ret is Map
          ? (
              restock: (ret['restock_qty'] as num).toInt(),
              writeOff: (ret['writeoff_qty'] as num).toInt(),
            )
          : null,
    );
  }

  final String id;
  final String? variantId;
  final String? productId;

  /// Snapshots taken when the line was added and frozen at approval.
  final String name;
  final String variantLabel;
  final String? sku;
  final int quantity;
  final int? quotedUnitPrice;
  final int? approvedUnitPrice;

  /// approvedUnitPrice ?? quotedUnitPrice.
  final int unitPrice;
  final int lineTotal;

  /// Units currently taken from stock for this line.
  final int stockDeducted;
  final String? imagePath;
  final LiveVariant? current;
  final ReturnDecision? returned;

  /// Unresolved AI lines carry what the customer wrote and the candidates.
  final LineResolution resolution;
  final String? customerText;

  /// The quantity was interpreted, not stated ("a couple" → 2): check it.
  final bool quantityInferred;
  final List<LineCandidate> candidates;

  bool get isResolved => resolution == LineResolution.resolved;

  /// Before approval: the catalog price differs from the quote (BR-23).
  bool get priceChanged =>
      approvedUnitPrice == null &&
      current != null &&
      quotedUnitPrice != null &&
      current!.price != quotedUnitPrice;

  /// Before approval: a resolved line whose variant cannot be sold. An
  /// unresolved AI line blocks approval through its issue instead.
  bool get unavailable => isResolved && (current == null || !current!.sellable);

  /// Before approval: units missing from stock (0 when enough or untracked).
  int get shortBy {
    final c = current;
    if (c == null || !c.trackStock) return 0;
    final missing = quantity - c.stockOnHand;
    return missing > 0 ? missing : 0;
  }
}

@immutable
class OrderEvent {
  const OrderEvent({
    required this.to,
    required this.actor,
    required this.createdAt,
    this.from,
    this.reason,
    this.note,
  });

  factory OrderEvent.fromJson(Map<String, dynamic> j) => OrderEvent(
    from: j['from'] == null ? null : OrderStatus.parse(j['from']),
    to: OrderStatus.parse(j['to']),
    actor: Actor.parse(j['actor']),
    reason: j['reason'] as String?,
    note: j['note'] as String?,
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
  );

  final OrderStatus? from;
  final OrderStatus to;
  final Actor actor;
  final String? reason;
  final String? note;
  final DateTime createdAt;
}

enum PaymentMethod {
  cod('cod'),
  other('other');

  const PaymentMethod(this.wire);
  final String wire;

  static PaymentMethod? parse(Object? v) => switch (v) {
    'cod' => PaymentMethod.cod,
    'other' => PaymentMethod.other,
    _ => null,
  };
}

@immutable
class Order {
  const Order({
    required this.id,
    required this.number,
    required this.status,
    required this.currency,
    required this.lines,
    required this.issues,
    required this.events,
    required this.discount,
    required this.subtotal,
    required this.total,
    required this.codDue,
    required this.codCollected,
    required this.codOutstanding,
    required this.version,
    required this.createdAt,
    required this.statusChangedAt,
    this.customerName,
    this.customerPhone,
    this.customerPhone2,
    this.zoneId,
    this.zoneName,
    this.cityText,
    this.area,
    this.landmark,
    this.addressDetails,
    this.deliveryFee,
    this.feeFromSeller = false,
    this.courierNote,
    this.paymentMethod,
    this.paymentNote,
    this.customerNote,
    this.internalNote,
    this.failureReason,
    this.closedReason,
    this.closedNote,
    this.approvedBy,
    this.approvedAt,
    this.confirmationMarkedSentAt,
    this.fromAi = false,
    this.isTest = false,
    this.conversationId,
  });

  factory Order.fromJson(Map<String, dynamic> j) {
    final customer = (j['customer'] as Map? ?? {}).cast<String, dynamic>();
    final delivery = (j['delivery'] as Map? ?? {}).cast<String, dynamic>();
    final payment = (j['payment'] as Map? ?? {}).cast<String, dynamic>();
    DateTime? time(Object? v) =>
        v is String ? DateTime.parse(v).toLocal() : null;
    return Order(
      id: j['id'] as String,
      number: (j['number'] as num).toInt(),
      status: OrderStatus.parse(j['status']),
      currency: j['currency'] == 'USD' ? Currency.usd : Currency.iqd,
      customerName: customer['name'] as String?,
      customerPhone: customer['phone'] as String?,
      customerPhone2: customer['phone2'] as String?,
      zoneId: delivery['zone_id'] as String?,
      zoneName: delivery['zone_name'] as String?,
      cityText: delivery['city_text'] as String?,
      area: delivery['area'] as String?,
      landmark: delivery['landmark'] as String?,
      addressDetails: delivery['details'] as String?,
      deliveryFee: (delivery['fee'] as num?)?.toInt(),
      feeFromSeller: delivery['fee_source'] == 'seller',
      courierNote: delivery['courier_note'] as String?,
      paymentMethod: PaymentMethod.parse(payment['method']),
      paymentNote: payment['note'] as String?,
      codDue: (payment['cod_due'] as num?)?.toInt() ?? 0,
      codCollected: (payment['cod_collected'] as num?)?.toInt() ?? 0,
      codOutstanding: (payment['cod_outstanding'] as num?)?.toInt() ?? 0,
      discount: (j['discount'] as num?)?.toInt() ?? 0,
      subtotal: (j['subtotal'] as num?)?.toInt() ?? 0,
      total: (j['total'] as num?)?.toInt() ?? 0,
      customerNote: j['customer_note'] as String?,
      internalNote: j['internal_note'] as String?,
      failureReason: j['failure_reason'] as String?,
      closedReason: j['closed_reason'] as String?,
      closedNote: j['closed_note'] as String?,
      approvedBy: j['approved_at'] == null
          ? null
          : Actor.parse(j['approved_by']),
      approvedAt: time(j['approved_at']),
      confirmationMarkedSentAt: time(j['confirmation_marked_sent_at']),
      fromAi: j['origin'] == 'ai',
      isTest: j['is_test'] == true,
      conversationId: j['conversation_id'] as String?,
      version: (j['version'] as num).toInt(),
      createdAt: time(j['created_at'])!,
      statusChangedAt: time(j['status_changed_at']) ?? time(j['created_at'])!,
      issues: [
        for (final i in j['issues'] as List? ?? [])
          OrderIssue.fromJson((i as Map).cast<String, dynamic>()),
      ],
      lines: [
        for (final l in j['lines'] as List? ?? [])
          OrderLine.fromJson((l as Map).cast<String, dynamic>()),
      ],
      events: [
        for (final e in j['events'] as List? ?? [])
          OrderEvent.fromJson((e as Map).cast<String, dynamic>()),
      ],
    );
  }

  final String id;
  final int number;
  final OrderStatus status;
  final Currency currency;

  /// Created by the AI assistant from a conversation (Phase 8).
  final bool fromAi;

  /// A sandbox order: never moves stock, never counted (BR-50).
  final bool isTest;

  /// The conversation an AI draft came from, while it exists.
  final String? conversationId;
  final String? customerName;

  /// E.164 (`+9647XXXXXXXXX`).
  final String? customerPhone;
  final String? customerPhone2;
  final String? zoneId;

  /// The zone's name when the order was saved (a snapshot).
  final String? zoneName;

  /// A place outside the configured zones, entered by the seller.
  final String? cityText;
  final String? area;
  final String? landmark;
  final String? addressDetails;
  final int? deliveryFee;

  /// The seller typed the fee instead of taking the zone's.
  final bool feeFromSeller;
  final String? courierNote;
  final PaymentMethod? paymentMethod;
  final String? paymentNote;
  final int discount;
  final int subtotal;
  final int total;
  final int codDue;
  final int codCollected;
  final int codOutstanding;
  final String? customerNote;
  final String? internalNote;
  final String? failureReason;
  final String? closedReason;
  final String? closedNote;
  final Actor? approvedBy;
  final DateTime? approvedAt;
  final DateTime? confirmationMarkedSentAt;
  final int version;
  final DateTime createdAt;
  final DateTime statusChangedAt;

  /// Missing required fields (BR-36), computed by the server.
  final List<OrderIssue> issues;
  final List<OrderLine> lines;
  final List<OrderEvent> events;

  /// "Erbil" (zone) or the seller's place.
  String? get place => zoneName ?? cityText;

  /// Lines that would block approval now (unavailable or short).
  List<OrderLine> get blockedLines => [
    for (final l in lines)
      if (l.unavailable || l.shortBy > 0) l,
  ];

  /// Lines whose catalog price changed since the quote (BR-23).
  List<OrderLine> get priceChanges => [
    for (final l in lines)
      if (l.priceChanged) l,
  ];

  /// Approve is possible in the UI (the server checks again).
  bool get canApprove =>
      status == OrderStatus.pendingApproval &&
      issues.isEmpty &&
      blockedLines.isEmpty;

  int get unitCount => lines.fold(0, (n, l) => n + l.quantity);
}

/// One row of the order list (OR-01).
@immutable
class OrderSummary {
  const OrderSummary({
    required this.id,
    required this.number,
    required this.status,
    required this.total,
    required this.currency,
    required this.itemCount,
    required this.unitCount,
    required this.codOutstanding,
    required this.issueCount,
    required this.createdAt,
    required this.version,
    this.customerName,
    this.customerPhone,
    this.firstItemName,
    this.firstItemLabel,
    this.firstItemQuantity,
  });

  factory OrderSummary.fromJson(Map<String, dynamic> j) {
    final first = j['first_item'] as Map?;
    return OrderSummary(
      id: j['id'] as String,
      number: (j['number'] as num).toInt(),
      status: OrderStatus.parse(j['status']),
      customerName: j['customer_name'] as String?,
      customerPhone: j['customer_phone'] as String?,
      total: (j['total'] as num?)?.toInt() ?? 0,
      currency: j['currency'] == 'USD' ? Currency.usd : Currency.iqd,
      codOutstanding: (j['cod_outstanding'] as num?)?.toInt() ?? 0,
      itemCount: (j['item_count'] as num?)?.toInt() ?? 0,
      unitCount: (j['unit_count'] as num?)?.toInt() ?? 0,
      issueCount: (j['issue_count'] as num?)?.toInt() ?? 0,
      firstItemName: first?['name'] as String?,
      firstItemLabel: first?['variant_label'] as String?,
      firstItemQuantity: (first?['quantity'] as num?)?.toInt(),
      createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      version: (j['version'] as num?)?.toInt() ?? 1,
    );
  }

  final String id;
  final int number;
  final OrderStatus status;
  final String? customerName;
  final String? customerPhone;
  final int total;
  final Currency currency;
  final int codOutstanding;
  final int itemCount;
  final int unitCount;

  /// Missing fields of a draft.
  final int issueCount;
  final String? firstItemName;
  final String? firstItemLabel;
  final int? firstItemQuantity;
  final DateTime createdAt;
  final int version;
}

@immutable
class OrderPage {
  const OrderPage(this.items, {required this.total, required this.hasMore});

  factory OrderPage.fromJson(Map<String, dynamic> j) => OrderPage(
    [
      for (final i in j['items'] as List? ?? [])
        OrderSummary.fromJson((i as Map).cast<String, dynamic>()),
    ],
    total: (j['total'] as num?)?.toInt() ?? 0,
    hasMore: j['has_more'] as bool? ?? false,
  );

  final List<OrderSummary> items;
  final int total;
  final bool hasMore;
}

/// Counts per filter, and the cash still to collect (BR-43).
@immutable
class OrderCounts {
  const OrderCounts({
    required this.byFilter,
    required this.codOutstanding,
    required this.currency,
    this.toDispatch = 0,
    this.deliveryFailed = 0,
    this.approvedToday = 0,
    this.valueApprovedToday = 0,
    this.deliveredToday = 0,
  });

  factory OrderCounts.fromJson(Map<String, dynamic> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return OrderCounts(
      byFilter: {for (final f in OrderFilter.values) f: n(f.wire)},
      codOutstanding: n('cod_outstanding'),
      currency: j['currency'] == 'USD' ? Currency.usd : Currency.iqd,
      toDispatch: n('to_dispatch'),
      deliveryFailed: n('delivery_failed'),
      approvedToday: n('approved_today'),
      valueApprovedToday: n('value_approved_today'),
      deliveredToday: n('delivered_today'),
    );
  }

  final Map<OrderFilter, int> byFilter;
  final int codOutstanding;
  final Currency currency;

  /// Approved or preparing (Today "To prepare or dispatch").
  final int toDispatch;
  final int deliveryFailed;

  /// Today in the store's time zone (Asia/Baghdad), committed orders only.
  final int approvedToday;
  final int valueApprovedToday;
  final int deliveredToday;

  int operator [](OrderFilter f) => byFilter[f] ?? 0;
}

/// A stock change caused by an order (approval, edit, cancel, return).
@immutable
class StockChange {
  const StockChange({
    required this.name,
    required this.label,
    required this.before,
    required this.after,
  });

  factory StockChange.fromJson(Map<String, dynamic> j) => StockChange(
    name: j['name'] as String? ?? '',
    label: j['label'] as String? ?? '',
    before: (j['before'] as num).toInt(),
    after: (j['after'] as num).toInt(),
  );

  final String name;
  final String label;
  final int before;
  final int after;
}

List<StockChange> stockChangesFrom(Object? list) => [
  for (final s in list as List? ?? [])
    StockChange.fromJson((s as Map).cast<String, dynamic>()),
];

/// One entry of the full history (OR-11).
@immutable
class HistoryEntry {
  const HistoryEntry({
    required this.kind,
    required this.actor,
    required this.createdAt,
    this.from,
    this.to,
    this.reason,
    this.note,
    this.before = const {},
    this.after = const {},
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
    kind: switch (j['kind']) {
      'status' => HistoryKind.status,
      'edit' => HistoryKind.edit,
      'note' => HistoryKind.note,
      'cash' => HistoryKind.cash,
      _ => HistoryKind.confirmation,
    },
    from: j['from'] == null ? null : OrderStatus.parse(j['from']),
    to: j['to'] == null ? null : OrderStatus.parse(j['to']),
    actor: Actor.parse(j['actor']),
    reason: j['reason'] as String?,
    note: j['note'] as String?,
    before: (j['before'] as Map? ?? {}).cast<String, dynamic>(),
    after: (j['after'] as Map? ?? {}).cast<String, dynamic>(),
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
  );

  final HistoryKind kind;
  final OrderStatus? from;
  final OrderStatus? to;
  final Actor actor;
  final String? reason;
  final String? note;

  /// For edits: the fields that changed, before and after.
  final Map<String, dynamic> before;
  final Map<String, dynamic> after;
  final DateTime createdAt;

  /// Changed field names, in a stable order (lines last).
  List<String> get changedFields {
    final keys = {...before.keys, ...after.keys}
      ..remove('stock_diff')
      ..remove('total');
    final sorted = keys.toList()..sort();
    if (sorted.remove('lines')) sorted.add('lines');
    return sorted;
  }
}

enum HistoryKind { status, edit, note, cash, confirmation }

/// Reasons (wire values) offered by the reject, cancel and delivery-failed
/// sheets. "other" needs a note.
const rejectReasons = [
  'customer_changed_mind',
  'not_serious',
  'duplicate',
  'out_of_stock',
  'cannot_deliver',
  'other',
];
const cancelReasons = [
  'customer_cancelled',
  'out_of_stock',
  'cannot_deliver',
  'duplicate',
  'other',
];
const deliveryFailureReasons = [
  'unreachable',
  'refused',
  'wrong_address',
  'other',
];
