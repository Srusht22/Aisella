import 'package:flutter/foundation.dart';

import '../../../core/formatting/money.dart';

/// A store's courier (Phase 10, roadmap R8). [owed] is cash on delivery the
/// courier still has to hand over for delivered orders; [carrying] is the
/// cash still to collect on orders the courier is delivering.
@immutable
class Courier {
  const Courier({
    required this.id,
    required this.name,
    required this.active,
    required this.version,
    this.phone,
    this.owed = 0,
    this.owedOrders = 0,
    this.carrying = 0,
    this.carryingOrders = 0,
  });

  factory Courier.fromJson(Map<String, dynamic> j) => Courier(
    id: j['id'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    active: j['active'] != false,
    version: (j['version'] as num?)?.toInt() ?? 1,
    owed: (j['owed'] as num?)?.toInt() ?? 0,
    owedOrders: (j['owed_orders'] as num?)?.toInt() ?? 0,
    carrying: (j['carrying'] as num?)?.toInt() ?? 0,
    carryingOrders: (j['carrying_orders'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String name;

  /// E.164 (`+9647XXXXXXXXX`).
  final String? phone;
  final bool active;
  final int version;
  final int owed;
  final int owedOrders;
  final int carrying;
  final int carryingOrders;
}

enum DeliveryListStatus {
  open,
  handedOver,
  cancelled;

  static DeliveryListStatus parse(Object? v) => switch (v) {
    'handed_over' => DeliveryListStatus.handedOver,
    'cancelled' => DeliveryListStatus.cancelled,
    _ => DeliveryListStatus.open,
  };
}

@immutable
class StopItem {
  const StopItem({required this.name, required this.quantity, this.variant});

  final String name;
  final String? variant;
  final int quantity;
}

/// One order on a delivery list, with what the courier needs.
@immutable
class DeliveryStop {
  const DeliveryStop({
    required this.orderId,
    required this.number,
    required this.status,
    required this.cashToCollect,
    required this.total,
    required this.currency,
    required this.items,
    required this.complete,
    this.customerName,
    this.phone,
    this.phone2,
    this.zone,
    this.city,
    this.area,
    this.landmark,
    this.address,
    this.customerNote,
  });

  factory DeliveryStop.fromJson(Map<String, dynamic> j) => DeliveryStop(
    orderId: j['order_id'] as String,
    number: (j['number'] as num).toInt(),
    status: j['status'] as String? ?? '',
    customerName: j['customer_name'] as String?,
    phone: j['phone'] as String?,
    phone2: j['phone2'] as String?,
    zone: j['zone'] as String?,
    city: j['city'] as String?,
    area: j['area'] as String?,
    landmark: j['landmark'] as String?,
    address: j['address'] as String?,
    customerNote: j['customer_note'] as String?,
    cashToCollect: (j['cash_to_collect'] as num?)?.toInt() ?? 0,
    total: (j['total'] as num?)?.toInt() ?? 0,
    currency: j['currency'] == 'USD' ? Currency.usd : Currency.iqd,
    complete: (j['issues'] as List? ?? const []).isEmpty,
    items: [
      for (final i in j['items'] as List? ?? const [])
        if (i is Map)
          StopItem(
            name: i['name'] as String? ?? '',
            variant: (i['variant'] as String?)?.isEmpty == true
                ? null
                : i['variant'] as String?,
            quantity: (i['quantity'] as num?)?.toInt() ?? 1,
          ),
    ],
  );

  final String orderId;
  final int number;
  final String status;
  final String? customerName;
  final String? phone;
  final String? phone2;
  final String? zone;
  final String? city;
  final String? area;
  final String? landmark;
  final String? address;
  final String? customerNote;
  final int cashToCollect;
  final int total;
  final Currency currency;
  final List<StopItem> items;

  /// No missing delivery details (it can be dispatched).
  final bool complete;

  String get place => zone ?? city ?? '';
}

@immutable
class DeliveryList {
  const DeliveryList({
    required this.id,
    required this.number,
    required this.status,
    required this.version,
    required this.orderCount,
    required this.codTotal,
    required this.createdAt,
    this.courierId,
    this.courierName,
    this.courierPhone,
    this.handedOverAt,
    this.stops = const [],
  });

  factory DeliveryList.fromJson(Map<String, dynamic> j) {
    final courier = j['courier'] is Map
        ? (j['courier'] as Map).cast<String, dynamic>()
        : null;
    DateTime? time(Object? v) =>
        v is String ? DateTime.parse(v).toLocal() : null;
    return DeliveryList(
      id: j['id'] as String,
      number: (j['number'] as num).toInt(),
      status: DeliveryListStatus.parse(j['status']),
      version: (j['version'] as num?)?.toInt() ?? 1,
      orderCount: (j['order_count'] as num?)?.toInt() ?? 0,
      codTotal: (j['cod_total'] as num?)?.toInt() ?? 0,
      courierId: courier?['id'] as String?,
      courierName: courier?['name'] as String?,
      courierPhone: courier?['phone'] as String?,
      createdAt: time(j['created_at']) ?? DateTime.now(),
      handedOverAt: time(j['handed_over_at']),
      stops: [
        for (final s in j['stops'] as List? ?? const [])
          DeliveryStop.fromJson((s as Map).cast<String, dynamic>()),
      ],
    );
  }

  final String id;
  final int number;
  final DeliveryListStatus status;
  final int version;
  final int orderCount;

  /// Cash on delivery still to collect on the list's orders.
  final int codTotal;
  final String? courierId;
  final String? courierName;
  final String? courierPhone;
  final DateTime createdAt;
  final DateTime? handedOverAt;
  final List<DeliveryStop> stops;

  bool get isOpen => status == DeliveryListStatus.open;
}

/// An order that can go on a new list (ready to leave, on no open list).
@immutable
class ReadyOrder {
  const ReadyOrder({
    required this.orderId,
    required this.number,
    required this.total,
    required this.currency,
    required this.complete,
    this.customerName,
    this.place,
  });

  factory ReadyOrder.fromJson(Map<String, dynamic> j) => ReadyOrder(
    orderId: j['order_id'] as String,
    number: (j['number'] as num).toInt(),
    customerName: j['customer_name'] as String?,
    place: [
      j['zone'] as String?,
      j['area'] as String?,
    ].whereType<String>().join(' · '),
    total: (j['total'] as num?)?.toInt() ?? 0,
    currency: j['currency'] == 'USD' ? Currency.usd : Currency.iqd,
    complete: j['complete'] == true,
  );

  final String orderId;
  final int number;
  final String? customerName;
  final String? place;
  final int total;
  final Currency currency;

  /// Has every delivery detail (only complete orders can be handed over).
  final bool complete;
}

@immutable
class DeliveryListsPage {
  const DeliveryListsPage({required this.lists, required this.ready});

  factory DeliveryListsPage.fromJson(Map<String, dynamic> j) =>
      DeliveryListsPage(
        lists: [
          for (final l in j['items'] as List? ?? const [])
            DeliveryList.fromJson((l as Map).cast<String, dynamic>()),
        ],
        ready: [
          for (final r in j['ready'] as List? ?? const [])
            ReadyOrder.fromJson((r as Map).cast<String, dynamic>()),
        ],
      );

  final List<DeliveryList> lists;
  final List<ReadyOrder> ready;
}

/// How a transfer or wallet payment was made (record only; Phase 1 15b).
enum PaymentChannel {
  fib('fib'),
  fastpay('fastpay'),
  zaincash('zaincash'),
  asiahawala('asiahawala'),
  bankTransfer('bank_transfer'),
  other('other');

  const PaymentChannel(this.wire);
  final String wire;

  static PaymentChannel parse(Object? v) =>
      values.where((c) => c.wire == v).firstOrNull ?? PaymentChannel.other;
}

/// The result of a courier settlement: which orders it paid off.
@immutable
class Settlement {
  const Settlement({required this.allocations, required this.courier});

  factory Settlement.fromJson(Map<String, dynamic> j) => Settlement(
    allocations: [
      for (final a in j['allocations'] as List? ?? const [])
        if (a is Map)
          (
            number: (a['number'] as num).toInt(),
            amount: (a['amount'] as num).toInt(),
          ),
    ],
    courier: Courier.fromJson((j['courier'] as Map).cast<String, dynamic>()),
  );

  final List<({int number, int amount})> allocations;
  final Courier courier;
}
