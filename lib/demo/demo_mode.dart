import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../core/clock.dart';
import '../features/auth/application/auth_controller.dart';
import '../features/catalog/data/catalog_repository.dart';
import '../features/catalog/data/media_store.dart';
import '../features/channels/application/channel_providers.dart';
import '../features/fulfilment/application/fulfilment_providers.dart';
import '../features/fulfilment/domain/fulfilment.dart';
import '../features/inbox/data/conversations_repository.dart';
import '../features/orders/data/orders_repository.dart';
import '../features/store/application/workspace_controller.dart';
import '../features/store/domain/store.dart';
import '../features/today/data/today_repository.dart';
import 'catalog_fakes.dart';
import 'channel_fakes.dart';
import 'fakes.dart';
import 'fulfilment_fakes.dart';
import 'inbox_fakes.dart';
import 'order_fakes.dart';

/// Guest demo: the whole app on in-memory sample data, with no account and
/// no backend. Offered on test builds only. Nothing is saved; leaving (sign
/// out) or reloading returns to the real app.
final demoMode = ValueNotifier<bool>(false);

/// True inside the demo, for the ribbon.
final isDemoProvider = Provider<bool>((ref) => false);

/// Swaps between the real app and the demo. Each side gets its own
/// [ProviderScope], so no demo state can leak into the real app.
class DemoSwitch extends StatelessWidget {
  const DemoSwitch({
    super.key,
    required this.realOverrides,
    required this.child,
  });

  /// Configuration and preferences shared by both sides (and the backend
  /// client for the real side).
  final List<Override> realOverrides;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: demoMode,
    builder: (context, demo, _) => demo
        ? ProviderScope(
            key: const ValueKey('demo'),
            overrides: [...realOverrides, ...demoOverrides()],
            child: child,
          )
        : ProviderScope(
            key: const ValueKey('real'),
            overrides: realOverrides,
            child: child,
          ),
  );
}

/// Repositories for the demo, seeded with a realistic small store.
List<Override> demoOverrides({DateTime Function() now = DateTime.now}) {
  final catalog = FakeCatalogRepository(products: sampleCatalog());
  final orders = sampleOrders(catalog, now());
  final conversations = demoConversations();
  return [
    isDemoProvider.overrideWithValue(true),
    clockProvider.overrideWithValue(now),
    authRepositoryProvider.overrideWithValue(
      _DemoAuthRepository(initialUser: testUser),
    ),
    storeRepositoryProvider.overrideWithValue(
      FakeStoreRepository(store: testStore(), zones: [demoZone]),
    ),
    todayRepositoryProvider.overrideWithValue(
      const SampleTodayRepository(latency: Duration(milliseconds: 300)),
    ),
    catalogRepositoryProvider.overrideWithValue(catalog),
    ordersRepositoryProvider.overrideWithValue(orders),
    conversationsRepositoryProvider.overrideWithValue(conversations),
    channelsRepositoryProvider.overrideWithValue(
      FakeChannelsRepository(conversations: conversations),
    ),
    fulfilmentRepositoryProvider.overrideWithValue(
      FakeFulfilmentRepository(
        orders: orders,
        couriers: const [
          Courier(
            id: 'courier-1',
            name: 'Aram',
            phone: '+9647501112233',
            active: true,
            version: 1,
          ),
        ],
      ),
    ),
    mediaStoreProvider.overrideWithValue(FakeMediaStore()),
    photoPickerProvider.overrideWithValue(FakePhotoPicker()),
  ];
}

const demoZone = DeliveryZone(
  id: 'zone-1',
  name: 'Erbil',
  fee: 5000,
  timeText: null,
  version: 1,
);

/// Three conversations: one with a suggested reply waiting, one that needs
/// the seller, one waiting for the customer. "Suggest a reply" produces a
/// catalog-based suggestion.
FakeConversationsRepository demoConversations() {
  const fake = FakeConversationsRepository.conversationJson;
  const msg = FakeConversationsRepository.messageJson;
  const suggestion = FakeConversationsRepository.suggestionJson;
  final repo = FakeConversationsRepository(
    conversations: [
      fake(
        id: 'demo-c1',
        label: 'Nzar Ahmad',
        messages: [msg('dm1', 'سڵاو، بۆنی عود ماوە؟ نرخی چەندە؟')],
        suggestion: suggestion(
          text: 'بەڵێ، بۆنی عود بەردەستە. نرخەکەی ١٥،٠٠٠ دینارە.',
          language: 'ckb',
          facts: const [
            {
              'fact': 'variant_price',
              'label': 'بۆنی عود',
              'value': '15,000 IQD',
            },
          ],
        ),
      ),
      fake(
        id: 'demo-c2',
        label: 'Shilan',
        source: 'whatsapp',
        status: 'needs_you',
        escalation: const ['discount_request'],
        messages: [
          msg('dm2', 'Can I get a discount if I buy two leather bags?'),
        ],
      ),
      fake(
        id: 'demo-c3',
        label: 'Dara Kamal',
        source: 'messenger',
        status: 'waiting',
        messages: [
          msg('dm3', 'Is the linen shirt available in size L?'),
          msg(
            'dm4',
            'Yes, size L is available for 25,000 IQD. Shall I prepare the order?',
            inbound: false,
            origin: 'seller',
            state: 'sent',
          ),
        ],
      ),
    ],
  );
  repo.nextAssist = (_) => (
    suggestion: suggestion(
      id: 's-demo',
      text: 'Yes, it is available. The price is 15,000 IQD.',
      facts: const [
        {
          'fact': 'variant_price',
          'label': 'Oud Perfume',
          'value': '15,000 IQD',
        },
      ],
    ),
    status: 'succeeded',
    reasons: const <String>[],
  );
  return repo;
}

/// Leaving the demo (sign out) returns to the real app.
class _DemoAuthRepository extends FakeAuthRepository {
  _DemoAuthRepository({super.initialUser});

  @override
  Future<void> signOut({bool allDevices = false}) async {
    demoMode.value = false;
  }
}
