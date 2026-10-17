// Map-based on purpose: it mirrors the server's JSON rows.
// ignore_for_file: avoid_dynamic_calls
import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/core/formatting/digits.dart';
import 'package:aisellia/core/formatting/money.dart';
import 'package:aisellia/features/catalog/domain/catalog.dart';
import 'package:aisellia/features/orders/data/orders_repository.dart';
import 'package:aisellia/features/orders/domain/order.dart';
import 'package:aisellia/features/orders/domain/order_draft.dart';

import 'catalog_fakes.dart';

/// In-memory orders with the server rules the screens depend on: status
/// from completeness, server prices and totals, owner approval only from
/// pending approval with re-validation and stock deduction, transitions,
/// idempotent replays, versions. Stock lives in the [catalog] fake.
/// Records calls for assertions.
class FakeOrdersRepository implements OrdersRepository {
  FakeOrdersRepository({FakeCatalogRepository? catalog, this.zoneFee = 5000})
    : catalog = catalog ?? FakeCatalogRepository();

  final FakeCatalogRepository catalog;

  /// Fee of the test store's zone `zone-1` ("Erbil").
  final int zoneFee;
  final _orders = <String, Map<String, dynamic>>{};
  final _keys = <String, Object>{};
  final calls = <String>[];
  var _number = 1000;
  var _clock = DateTime(2026, 10, 15, 9);

  /// The next call fails with this error (then it is cleared).
  ApiException? failNext;

  /// Lets a test answer a call only after a check (in-flight states).
  Future<void>? gate;

  Future<void> _step(String call) async {
    calls.add(call);
    final g = gate;
    if (g != null) await g;
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  DateTime _now() => _clock = _clock.add(const Duration(minutes: 1));

  T _replay<T>(String key, T Function() run) {
    final hit = _keys[key];
    if (hit != null) return hit as T;
    final r = run();
    _keys[key] = r as Object;
    return r;
  }

  Map<String, dynamic> raw(String id) => _orders[id]!;

  // -------------------------------------------------------------------------
  // Building orders as the server returns them.
  // -------------------------------------------------------------------------

  List<Map<String, dynamic>> _issues(Map<String, dynamic> o) => [
    if (o['customer_name'] == null)
      {'field': 'customer_name', 'kind': 'missing'},
    if (o['customer_phone'] == null)
      {'field': 'customer_phone', 'kind': 'missing'},
    if (o['zone_id'] == null && o['city_text'] == null)
      {'field': 'zone', 'kind': 'missing'},
    if (o['area'] == null) {'field': 'area', 'kind': 'missing'},
    if (o['fee'] == null) {'field': 'delivery_fee', 'kind': 'missing'},
    if (o['payment_method'] == null)
      {'field': 'payment_method', 'kind': 'missing'},
    if ((o['lines'] as List).isEmpty) {'field': 'lines', 'kind': 'missing'},
  ];

  Map<String, dynamic>? _current(String variantId) {
    final p = catalog.productOfVariant(variantId);
    if (p == null) return null;
    final v = p.variants.firstWhere((x) => x.id == variantId);
    return {
      'price': v.price,
      'stock_on_hand': v.stockOnHand,
      'track_stock': p.trackStock,
      'available': v.available,
      'product_status': p.status.name,
      'variant_status': v.archived ? 'archived' : 'active',
    };
  }

  int _subtotal(Map<String, dynamic> o) => (o['lines'] as List).fold(
    0,
    (s, l) =>
        s + (l['quantity'] as int) * ((l['approved'] ?? l['quoted']) as int),
  );

  Order _order(String id) {
    final o = _orders[id]!;
    final subtotal = _subtotal(o);
    final fee = o['fee'] as int?;
    final total = subtotal - (o['discount'] as int) + (fee ?? 0);
    return Order.fromJson({
      'id': id,
      'number': o['number'],
      'status': o['status'],
      'currency': 'IQD',
      'customer': {
        'name': o['customer_name'],
        'phone': o['customer_phone'],
        'phone2': o['customer_phone2'],
      },
      'delivery': {
        'zone_id': o['zone_id'],
        'zone_name': o['zone_id'] == null ? null : 'Erbil',
        'city_text': o['city_text'],
        'area': o['area'],
        'landmark': o['landmark'],
        'details': o['address_details'],
        'fee': fee,
        'fee_source': o['fee_source'],
        'courier_note': o['courier_note'],
      },
      'payment': {
        'method': o['payment_method'],
        'note': o['payment_note'],
        'cod_due': o['cod_due'],
        'cod_collected': o['cod_collected'],
        'cod_outstanding': ((o['cod_due'] as int) - (o['cod_collected'] as int))
            .clamp(0, 1 << 40),
      },
      'discount': o['discount'],
      'subtotal': subtotal,
      'total': total,
      'customer_note': o['customer_note'],
      'internal_note': o['internal_note'],
      'failure_reason': o['failure_reason'],
      'closed_reason': o['closed_reason'],
      'closed_note': o['closed_note'],
      'approved_by': o['approved_at'] == null ? 'system' : 'you',
      'approved_at': o['approved_at'],
      'confirmation_marked_sent_at': o['marked_sent_at'],
      'version': o['version'],
      'created_at': o['created_at'],
      'status_changed_at': o['created_at'],
      'issues': o['status'] == 'draft' || o['status'] == 'pending_approval'
          ? _issues(o)
          : const [],
      'events': o['events'],
      'lines': [
        for (final l in o['lines'] as List)
          {
            'id': l['id'],
            'variant_id': l['variant_id'],
            'product_id': l['product_id'],
            'name': l['name'],
            'variant_label': l['label'],
            'quantity': l['quantity'],
            'quoted_unit_price': l['quoted'],
            'approved_unit_price': l['approved'],
            'unit_price': l['approved'] ?? l['quoted'],
            'line_total':
                (l['quantity'] as int) *
                ((l['approved'] ?? l['quoted']) as int),
            'stock_deducted': l['held'],
            'current': _current(l['variant_id'] as String),
            'return': l['return'],
          },
      ],
    });
  }

  void _event(
    Map<String, dynamic> o,
    String? from,
    String to, {
    String actor = 'you',
    String? reason,
    String? note,
  }) => (o['events'] as List).add({
    'from': from,
    'to': to,
    'actor': actor,
    'reason': reason,
    'note': note,
    'created_at': _now().toUtc().toIso8601String(),
  });

  void _write(Map<String, dynamic> o, OrderDraft d) {
    final j = d.toJson();
    for (final k in [
      'customer_name',
      'customer_phone',
      'customer_phone2',
      'zone_id',
      'city_text',
      'area',
      'landmark',
      'address_details',
      'payment_method',
      'payment_note',
      'customer_note',
      'internal_note',
    ]) {
      o[k] = j[k];
    }
    o['discount'] = d.discount;
    o['fee'] = d.deliveryFee ?? (d.zoneId != null ? zoneFee : null);
    o['fee_source'] = d.deliveryFee != null
        ? 'seller'
        : d.zoneId != null
        ? 'zone'
        : null;
  }

  void _validate(OrderDraft d) {
    final errors = d.fieldErrors;
    for (final (i, l) in d.lines.indexed) {
      if (catalog.productOfVariant(l.variantId) == null) {
        errors['lines.$i.variant_id'] = 'unknown';
      }
    }
    if (errors.isNotEmpty) {
      throw ApiException(ApiErrorCode.validationFailed, fields: errors);
    }
  }

  List<Map<String, dynamic>> _draftLines(Map<String, dynamic> o, OrderDraft d) {
    final old = {
      for (final l in o['lines'] as List? ?? const []) l['variant_id']: l,
    };
    return [
      for (final l in d.lines)
        if (old[l.variantId] case final Map<String, dynamic> kept)
          {...kept, 'quantity': l.quantity}
        else
          _newLine(l.variantId, l.quantity),
    ];
  }

  Map<String, dynamic> _newLine(String variantId, int quantity) {
    final p = catalog.productOfVariant(variantId)!;
    final v = p.variants.firstWhere((x) => x.id == variantId);
    return {
      'id': 'line-$variantId-${_now().millisecondsSinceEpoch}',
      'variant_id': variantId,
      'product_id': p.id,
      'name': p.name,
      'label': v.label,
      'quantity': quantity,
      'quoted': v.price,
      'approved': null,
      'held': 0,
      'return': null,
    };
  }

  void _reevaluate(Map<String, dynamic> o) {
    final target = _issues(o).isEmpty ? 'pending_approval' : 'draft';
    if (o['status'] != target) {
      _event(o, o['status'] as String, target, actor: 'system');
      o['status'] = target;
    }
  }

  Map<String, dynamic> _lock(String id, int? version, {Set<String>? from}) {
    final o = _orders[id];
    if (o == null) throw const ApiException(ApiErrorCode.notFound);
    if (from != null && !from.contains(o['status'])) {
      throw ApiException(
        ApiErrorCode.invalidTransition,
        details: {'current_status': o['status']},
      );
    }
    if (version != null && version != o['version']) {
      throw ApiException(
        ApiErrorCode.conflictVersion,
        currentVersion: o['version'] as int,
      );
    }
    return o;
  }

  /// A complete pending order (or a draft) placed directly, as setup.
  Order seed(OrderDraft draft, {String? status, DateTime? createdAt}) {
    final id = 'order-${++_number}';
    final o = <String, dynamic>{
      'number': _number,
      'status': 'draft',
      'version': 1,
      'cod_due': 0,
      'cod_collected': 0,
      'created_at': (createdAt ?? _now()).toUtc().toIso8601String(),
      'events': <Map<String, dynamic>>[],
      'lines': <Map<String, dynamic>>[],
    };
    _write(o, draft);
    o['lines'] = _draftLines(o, draft);
    _orders[id] = o;
    o['status'] = _issues(o).isEmpty ? 'pending_approval' : 'draft';
    _event(o, null, o['status'] as String);
    if (status != null && status != o['status']) {
      _forceApprove(o);
      if (status != 'approved') {
        o['status'] = status;
        _event(o, 'approved', status);
      }
    }
    return _order(id);
  }

  List<StockChange> _forceApprove(
    Map<String, dynamic> o, {
    Map<String, String> choices = const {},
  }) {
    final changes = <StockChange>[];
    for (final l in o['lines'] as List) {
      final c = _current(l['variant_id'] as String)!;
      l['approved'] = choices[l['id']] == 'current' ? c['price'] : l['quoted'];
      if (c['track_stock'] as bool) {
        final before = c['stock_on_hand'] as int;
        catalog.moveStock(
          l['variant_id'] as String,
          -(l['quantity'] as int),
          StockReason.orderApproved,
        );
        l['held'] = l['quantity'];
        changes.add(
          StockChange(
            name: l['name'] as String,
            label: l['label'] as String,
            before: before,
            after: before - (l['quantity'] as int),
          ),
        );
      }
    }
    o['status'] = 'approved';
    o['approved_at'] = _now().toUtc().toIso8601String();
    final total =
        _subtotal(o) - (o['discount'] as int) + ((o['fee'] as int?) ?? 0);
    o['cod_due'] = o['payment_method'] == 'cod' ? total : 0;
    _event(o, 'pending_approval', 'approved');
    return changes;
  }

  // -------------------------------------------------------------------------
  // OrdersRepository
  // -------------------------------------------------------------------------

  bool _matches(Map<String, dynamic> o, OrderFilter f) => switch (f) {
    OrderFilter.all => true,
    OrderFilter.needsApproval => o['status'] == 'pending_approval',
    OrderFilter.drafts => o['status'] == 'draft',
    OrderFilter.active => const [
      'approved',
      'processing',
      'dispatched',
    ].contains(o['status']),
    OrderFilter.delivered => o['status'] == 'delivered',
    OrderFilter.problems =>
      o['status'] == 'delivery_failed' ||
          (o['status'] == 'delivered' &&
              (o['cod_collected'] as int) < (o['cod_due'] as int)),
    OrderFilter.closed => const [
      'rejected',
      'cancelled',
      'returned',
    ].contains(o['status']),
  };

  @override
  Future<OrderPage> listOrders(
    String storeId,
    OrderQuery query, {
    int offset = 0,
    int limit = 30,
  }) async {
    await _step('list:${query.filter.name}:${query.text}');
    final q = Digits.normalize(query.text).toLowerCase();
    final digits = q.replaceAll(RegExp(r'[^0-9]'), '');
    final rows =
        _orders.entries.where((e) {
          final o = e.value;
          if (!_matches(o, query.filter)) return false;
          if (q.isEmpty) return true;
          final phone = '${o['customer_phone'] ?? ''}';
          final local = phone.isEmpty ? '' : '0${phone.substring(4)}';
          return '${o['customer_name'] ?? ''}'.toLowerCase().contains(q) ||
              digits == '${o['number']}' ||
              (digits.length >= 4 &&
                  (phone.contains(digits) || local.contains(digits))) ||
              (o['lines'] as List).any(
                (l) => '${l['name']}'.toLowerCase().contains(q),
              );
        }).toList()..sort(
          (a, b) =>
              (b.value['number'] as int).compareTo(a.value['number'] as int),
        );
    final page = rows.skip(offset).take(limit);
    return OrderPage(
      [
        for (final e in page)
          () {
            final o = _order(e.key);
            return OrderSummary(
              id: o.id,
              number: o.number,
              status: o.status,
              customerName: o.customerName,
              customerPhone: o.customerPhone,
              total: o.total,
              currency: Currency.iqd,
              codOutstanding:
                  o.status == OrderStatus.dispatched ||
                      o.status == OrderStatus.delivered
                  ? o.codOutstanding
                  : 0,
              itemCount: o.lines.length,
              unitCount: o.unitCount,
              issueCount: o.status == OrderStatus.draft ? o.issues.length : 0,
              firstItemName: o.lines.firstOrNull?.name,
              firstItemLabel: o.lines.firstOrNull?.variantLabel,
              firstItemQuantity: o.lines.firstOrNull?.quantity,
              createdAt: o.createdAt,
              version: o.version,
            );
          }(),
      ],
      total: rows.length,
      hasMore: rows.length > offset + limit,
    );
  }

  @override
  Future<OrderCounts> counts(String storeId) async {
    await _step('counts');
    final all = _orders.values;
    int n(bool Function(Map<String, dynamic>) f) => all.where(f).length;
    return OrderCounts(
      byFilter: {
        for (final f in OrderFilter.values) f: n((o) => _matches(o, f)),
      },
      codOutstanding: all
          .where((o) => const ['dispatched', 'delivered'].contains(o['status']))
          .fold(
            0,
            (s, o) => s + (o['cod_due'] as int) - (o['cod_collected'] as int),
          ),
      currency: Currency.iqd,
      toDispatch: n(
        (o) => const ['approved', 'processing'].contains(o['status']),
      ),
      deliveryFailed: n((o) => o['status'] == 'delivery_failed'),
    );
  }

  @override
  Future<Order> getOrder(String storeId, String orderId) async {
    await _step('get:$orderId');
    if (!_orders.containsKey(orderId)) {
      throw const ApiException(ApiErrorCode.notFound);
    }
    return _order(orderId);
  }

  @override
  Future<List<HistoryEntry>> history(String storeId, String orderId) async {
    await _step('history:$orderId');
    final o = _lock(orderId, null);
    return [
      for (final e in o['events'] as List)
        HistoryEntry.fromJson({...e as Map<String, dynamic>, 'kind': 'status'}),
      ...[
        for (final e in o['edits'] as List? ?? const [])
          HistoryEntry.fromJson(e as Map<String, dynamic>),
      ],
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<Order> createOrder(
    String storeId,
    OrderDraft draft, {
    required String idempotencyKey,
  }) async {
    await _step('create');
    _validate(draft);
    return _replay(idempotencyKey, () => seed(draft));
  }

  @override
  Future<Order> updateDraft(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required OrderDraft draft,
    required String idempotencyKey,
  }) async {
    await _step('updateDraft:$orderId');
    return _replay(idempotencyKey, () {
      final o = _lock(
        orderId,
        expectedVersion,
        from: {'draft', 'pending_approval'},
      );
      _validate(draft);
      _write(o, draft);
      o['lines'] = _draftLines(o, draft);
      o['version'] = (o['version'] as int) + 1;
      (o['edits'] ??= <Map<String, dynamic>>[]).add({
        'kind': 'edit',
        'actor': 'you',
        'before': <String, dynamic>{},
        'after': {'area': o['area']},
        'created_at': _now().toUtc().toIso8601String(),
      });
      _reevaluate(o);
      return _order(orderId);
    });
  }

  @override
  Future<(Order, List<StockChange>)> approve(
    String storeId,
    String orderId, {
    required int expectedVersion,
    Map<String, String> priceChoices = const {},
    required String idempotencyKey,
  }) async {
    await _step('approve:$orderId');
    return _replay(idempotencyKey, () {
      final o = _orders[orderId];
      if (o == null) throw const ApiException(ApiErrorCode.notFound);
      if (o['status'] == 'draft') {
        throw ApiException(
          ApiErrorCode.incompleteOrder,
          details: {'issues': _issues(o)},
        );
      }
      _lock(orderId, expectedVersion, from: {'pending_approval'});
      final unavailable = <Map<String, dynamic>>[];
      final short = <Map<String, dynamic>>[];
      final changed = <Map<String, dynamic>>[];
      for (final l in o['lines'] as List) {
        final c = _current(l['variant_id'] as String)!;
        final sellable =
            c['product_status'] == 'active' &&
            c['variant_status'] == 'active' &&
            ((c['track_stock'] as bool) || (c['available'] as bool));
        if (!sellable) {
          unavailable.add({'item_id': l['id'], 'reason': 'inactive'});
        } else if ((c['track_stock'] as bool) &&
            (c['stock_on_hand'] as int) < (l['quantity'] as int)) {
          short.add({
            'item_id': l['id'],
            'requested': l['quantity'],
            'available': c['stock_on_hand'],
          });
        }
        if (c['price'] != l['quoted'] && !priceChoices.containsKey(l['id'])) {
          changed.add({
            'item_id': l['id'],
            'quoted': l['quoted'],
            'current': c['price'],
          });
        }
      }
      if (unavailable.isNotEmpty) {
        throw ApiException(
          ApiErrorCode.lineUnavailable,
          details: {'lines': unavailable},
        );
      }
      if (short.isNotEmpty) {
        throw ApiException(
          ApiErrorCode.insufficientStock,
          details: {'lines': short},
        );
      }
      if (changed.isNotEmpty) {
        throw ApiException(
          ApiErrorCode.priceChanged,
          details: {'items': changed},
        );
      }
      final stock = _forceApprove(o, choices: priceChoices);
      o['version'] = (o['version'] as int) + 1;
      return (_order(orderId), stock);
    });
  }

  @override
  Future<Order> reject(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required String reason,
    String? note,
    required String idempotencyKey,
  }) async {
    await _step('reject:$orderId:$reason');
    return _replay(idempotencyKey, () {
      final o = _lock(
        orderId,
        expectedVersion,
        from: {'draft', 'pending_approval'},
      );
      _event(o, o['status'] as String, 'rejected', reason: reason, note: note);
      o
        ..['status'] = 'rejected'
        ..['closed_reason'] = reason
        ..['closed_note'] = note
        ..['version'] = (o['version'] as int) + 1;
      return _order(orderId);
    });
  }

  @override
  Future<(Order, List<StockChange>)> editApproved(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required OrderDraft draft,
    required String idempotencyKey,
  }) async {
    await _step('editApproved:$orderId');
    return _replay(idempotencyKey, () {
      final o = _lock(
        orderId,
        expectedVersion,
        from: {'approved', 'processing'},
      );
      _validate(draft);
      final old = {for (final l in o['lines'] as List) l['variant_id']: l};
      final short = <Map<String, dynamic>>[];
      for (final (i, l) in draft.lines.indexed) {
        final held = (old[l.variantId]?['held'] as int?) ?? 0;
        final c = _current(l.variantId)!;
        if ((c['track_stock'] as bool) &&
            (c['stock_on_hand'] as int) < l.quantity - held) {
          short.add({
            'index': i,
            'requested': l.quantity - held,
            'available': c['stock_on_hand'],
          });
        }
      }
      if (short.isNotEmpty) {
        throw ApiException(
          ApiErrorCode.insufficientStock,
          details: {'lines': short},
        );
      }
      final diff = <StockChange>[];
      final lines = <Map<String, dynamic>>[];
      for (final l in draft.lines) {
        final line =
            (old.remove(l.variantId) as Map<String, dynamic>?) ??
            (_newLine(l.variantId, l.quantity)..['approved'] = null);
        line['approved'] ??= line['quoted'];
        final c = _current(l.variantId)!;
        final target = (c['track_stock'] as bool) ? l.quantity : 0;
        final delta = (line['held'] as int) - target;
        if (delta != 0) {
          final before = c['stock_on_hand'] as int;
          catalog.moveStock(l.variantId, delta, StockReason.orderEdited);
          diff.add(
            StockChange(
              name: line['name'] as String,
              label: line['label'] as String,
              before: before,
              after: before + delta,
            ),
          );
        }
        lines.add({...line, 'quantity': l.quantity, 'held': target});
      }
      for (final l in old.values) {
        if ((l['held'] as int) > 0) {
          catalog.moveStock(
            l['variant_id'] as String,
            l['held'] as int,
            StockReason.orderEdited,
          );
        }
      }
      _write(o, draft);
      o['lines'] = lines;
      final total =
          _subtotal(o) - (o['discount'] as int) + ((o['fee'] as int?) ?? 0);
      o['cod_due'] = o['payment_method'] == 'cod' ? total : 0;
      o['version'] = (o['version'] as int) + 1;
      return (_order(orderId), diff);
    });
  }

  @override
  Future<(Order, List<StockChange>)> cancel(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required String reason,
    String? note,
    required String idempotencyKey,
  }) async {
    await _step('cancel:$orderId:$reason');
    return _replay(idempotencyKey, () {
      final o = _lock(
        orderId,
        expectedVersion,
        from: {'approved', 'processing'},
      );
      final back = <StockChange>[];
      for (final l in o['lines'] as List) {
        final held = l['held'] as int;
        if (held > 0) {
          catalog.moveStock(
            l['variant_id'] as String,
            held,
            StockReason.orderCancelled,
          );
          l['held'] = 0;
          back.add(
            StockChange(
              name: l['name'] as String,
              label: l['label'] as String,
              before: 0,
              after: held,
            ),
          );
        }
      }
      _event(o, o['status'] as String, 'cancelled', reason: reason, note: note);
      o
        ..['status'] = 'cancelled'
        ..['closed_reason'] = reason
        ..['cod_due'] = 0
        ..['version'] = (o['version'] as int) + 1;
      return (_order(orderId), back);
    });
  }

  static const _allowed = {
    'processing': {'approved'},
    'dispatched': {'approved', 'processing', 'delivery_failed'},
    'delivered': {'dispatched'},
    'delivery_failed': {'dispatched'},
  };

  @override
  Future<Order> transition(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required OrderStatus to,
    Map<String, dynamic> payload = const {},
    required String idempotencyKey,
  }) async {
    await _step('transition:$orderId:${to.wire}');
    return _replay(idempotencyKey, () {
      final o = _lock(orderId, expectedVersion, from: _allowed[to.wire]);
      if (to == OrderStatus.delivered && payload['cod_collected'] is int) {
        o['cod_collected'] =
            (o['cod_collected'] as int) + (payload['cod_collected'] as int);
      }
      if (to == OrderStatus.deliveryFailed) {
        o['failure_reason'] = payload['reason'];
      }
      if (to == OrderStatus.dispatched) {
        o['courier_note'] = payload['courier_note'] ?? o['courier_note'];
      }
      _event(
        o,
        o['status'] as String,
        to.wire,
        reason: payload['reason'] as String?,
      );
      o
        ..['status'] = to.wire
        ..['version'] = (o['version'] as int) + 1;
      return _order(orderId);
    });
  }

  @override
  Future<(Order, List<StockChange>)> recordReturn(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required Map<String, ReturnDecision> lines,
    String? note,
    required String idempotencyKey,
  }) async {
    await _step('return:$orderId');
    return _replay(idempotencyKey, () {
      final o = _lock(
        orderId,
        expectedVersion,
        from: {'dispatched', 'delivery_failed'},
      );
      final back = <StockChange>[];
      for (final l in o['lines'] as List) {
        final d = lines[l['id']]!;
        l['return'] = {'restock_qty': d.restock, 'writeoff_qty': d.writeOff};
        final n = d.restock.clamp(0, l['held'] as int);
        if (n > 0) {
          catalog.moveStock(
            l['variant_id'] as String,
            n,
            StockReason.orderReturned,
          );
          l['held'] = (l['held'] as int) - n;
          back.add(
            StockChange(
              name: l['name'] as String,
              label: l['label'] as String,
              before: 0,
              after: n,
            ),
          );
        }
      }
      _event(o, o['status'] as String, 'returned', note: note);
      o
        ..['status'] = 'returned'
        ..['cod_due'] = 0
        ..['version'] = (o['version'] as int) + 1;
      return (_order(orderId), back);
    });
  }

  @override
  Future<Order> recordCash(
    String storeId,
    String orderId, {
    required int amount,
    required String idempotencyKey,
  }) async {
    await _step('cash:$orderId:$amount');
    return _replay(idempotencyKey, () {
      final o = _lock(orderId, null, from: {'delivered'});
      o
        ..['cod_collected'] = (o['cod_collected'] as int) + amount
        ..['version'] = (o['version'] as int) + 1;
      return _order(orderId);
    });
  }

  @override
  Future<Order> markConfirmationSent(String storeId, String orderId) async {
    await _step('marked:$orderId');
    final o = _lock(orderId, null);
    o['marked_sent_at'] ??= _now().toUtc().toIso8601String();
    return _order(orderId);
  }

  @override
  Future<Order> updateNote(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required String note,
  }) async {
    await _step('note:$orderId');
    final o = _lock(orderId, expectedVersion);
    o
      ..['internal_note'] = note.trim().isEmpty ? null : note.trim()
      ..['version'] = (o['version'] as int) + 1;
    return _order(orderId);
  }
}

/// A complete order for [variantId] (the test store's zone, COD).
OrderDraft completeOrder({
  String variantId = 'p-abaya-v0',
  int quantity = 2,
  String name = 'Nzar Ahmad',
  String phone = '+9647501112233',
}) => OrderDraft(
  customerName: name,
  customerPhone: phone,
  zoneId: 'zone-1',
  area: 'Ankawa',
  paymentMethod: PaymentMethod.cod,
  lines: [
    DraftLine(
      variantId: variantId,
      name: '',
      label: '',
      unitPrice: 0,
      quantity: quantity,
    ),
  ],
);

/// A realistic order book over the [sampleCatalog] (fictional names; mixed
/// scripts): a pending order and a draft today, an approved and a dispatched
/// one yesterday, a delivered one with cash still due, a cancelled one.
FakeOrdersRepository sampleOrders([FakeCatalogRepository? catalog]) {
  final repo = FakeOrdersRepository(
    catalog: catalog ?? FakeCatalogRepository(products: sampleCatalog()),
  );
  final today = DateTime(2026, 10, 15, 9, 40);
  final yesterday = DateTime(2026, 10, 14, 16, 5);
  final earlier = DateTime(2026, 10, 9, 11, 20);
  repo
    ..seed(
      completeOrder(name: 'Shilan Hama', phone: '+9647701234567', quantity: 1),
      status: 'cancelled',
      createdAt: earlier,
    )
    ..seed(
      completeOrder(variantId: 'p-shirt-v2', name: 'Dara Kamal', quantity: 1),
      status: 'delivered',
      createdAt: earlier.add(const Duration(days: 1)),
    )
    ..seed(
      completeOrder(variantId: 'p-oud-v0', name: 'Karwan Ali', quantity: 3),
      status: 'dispatched',
      createdAt: yesterday,
    )
    ..seed(
      completeOrder(name: 'ڕێزان عومەر', phone: '+9647511112222', quantity: 1),
      status: 'approved',
      createdAt: yesterday.add(const Duration(hours: 1)),
    )
    ..seed(
      const OrderDraft(
        customerName: 'Hevi',
        cityText: 'Koya',
        lines: [
          DraftLine(
            variantId: 'p-shirt-v0',
            name: '',
            label: '',
            unitPrice: 0,
            quantity: 1,
          ),
        ],
      ),
      createdAt: today,
    )
    ..seed(
      completeOrder(name: 'Nzar Ahmad').addLine(
        const DraftLine(
          variantId: 'p-oud-v0',
          name: '',
          label: '',
          unitPrice: 0,
          quantity: 1,
        ),
      ),
      createdAt: today.add(const Duration(minutes: 20)),
    );
  return repo;
}
