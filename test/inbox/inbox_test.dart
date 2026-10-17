import 'package:aisellia/app/router.dart';
import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/features/inbox/domain/conversation.dart';
import 'package:aisellia/features/inbox/presentation/conversation_screen.dart';
import 'package:aisellia/features/orders/domain/order.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

typedef _Fake = FakeConversationsRepository;

void _go(WidgetTester tester, String path) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(routerProvider)
        .go(path);

Future<void> _pump(
  WidgetTester tester,
  FakeConversationsRepository conversations, {
  String route = Routes.inbox,
  String locale = 'en',
  Size size = const Size(390, 844),
  FakeOrdersRepository? orders,
}) async {
  await loadAppFonts();
  setScreen(tester, size: size);
  await tester.pumpWidget(
    testApp(
      conversations: conversations,
      orders: orders,
      sampleData: false,
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
  _go(tester, route);
  await tester.pumpAndSettle();
}

final _isolates = RegExp(
  '[${String.fromCharCode(0x2066)}-${String.fromCharCode(0x2069)}]',
);

Finder _has(String text) => find.byWidgetPredicate((w) {
  final data = w is Text
      ? (w.data ?? w.textSpan?.toPlainText())
      : w is SelectableText
      ? (w.data ?? w.textSpan?.toPlainText())
      : null;
  return data != null && data.replaceAll(_isolates, '').contains(text);
});

Future<void> _tap(WidgetTester tester, Finder f) async {
  for (final m in tester.stateList<ScaffoldMessengerState>(
    find.byType(ScaffoldMessenger),
  )) {
    m.removeCurrentSnackBar();
  }
  await tester.pumpAndSettle();
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _conv({
  String id = 'c1',
  String status = 'needs_reply',
  Map<String, dynamic>? suggestion,
  Map<String, dynamic>? order,
  Map<String, dynamic>? lastRun,
  List<String> escalation = const [],
  String source = 'instagram',
  bool aiPaused = false,
}) => _Fake.conversationJson(
  id: id,
  label: 'Nzar',
  source: source,
  status: status,
  escalation: escalation,
  suggestion: suggestion,
  order: order,
  lastRun: lastRun,
  aiPaused: aiPaused,
  messages: [
    _Fake.messageJson('m1', 'Hi, how much is the beige abaya size M?'),
  ],
);

void main() {
  group('Domain', () {
    test('a conversation parses messages, suggestion, run and draft', () {
      final c = Conversation.fromJson({
        ..._conv(
          suggestion: _Fake.suggestionJson(
            language: 'ckb',
            escalation: ['discount_request'],
            holding: true,
          ),
          order: {
            'id': 'o1',
            'number': 1001,
            'status': 'pending_approval',
            'is_test': false,
            'total': 75000,
            'currency': 'IQD',
            'issues': <Object>[],
          },
          lastRun: {'id': 'r1', 'status': 'timeout'},
        ),
        'ai': {'enabled': true, 'calls_today': 4, 'daily_limit': 300},
      });
      expect(c.messages.single.inbound, isTrue);
      expect(c.messages.single.origin, MessageOrigin.imported);
      expect(c.suggestion!.rtl, isTrue);
      expect(c.suggestion!.escalated, isTrue);
      expect(c.suggestion!.isHolding, isTrue);
      expect(c.lastRun!.status, AiRunStatus.timeout);
      expect(c.lastRun!.status.failed, isTrue);
      expect(c.order!.status, OrderStatus.pendingApproval);
      expect(c.callsToday, 4);
    });

    test('unknown wire values degrade safely', () {
      expect(ConversationStatus.parse('bogus'), ConversationStatus.needsReply);
      expect(ConversationSource.parse('tiktok'), ConversationSource.other);
      expect(AiRunStatus.parse('weird'), AiRunStatus.providerError);
      expect(MessageState.parse(null), MessageState.imported);
    });

    test('an AI order line keeps its resolution and candidates', () {
      final line = OrderLine.fromJson({
        'id': 'l1',
        'name': 'the black one',
        'variant_label': '',
        'quantity': 1,
        'quantity_basis': 'inferred',
        'resolution': 'choose_product',
        'customer_text': 'the black one',
        'candidates': [
          {
            'variant_id': 'v1',
            'name': 'Black Abaya',
            'variant_label': '',
            'price': 40000,
            'available': true,
          },
        ],
      });
      expect(line.isResolved, isFalse);
      expect(line.resolution, LineResolution.chooseProduct);
      expect(line.quantityInferred, isTrue);
      expect(line.candidates.single.name, 'Black Abaya');
      // Unresolved lines block through their issue, not as "not sold".
      expect(line.unavailable, isFalse);
      expect(Actor.parse('ai'), Actor.ai);
    });
  });

  group('Inbox', () {
    testWidgets('empty inbox explains how to paste a conversation', (
      tester,
    ) async {
      await _pump(tester, _Fake());
      expect(find.text('No conversations yet'), findsOneWidget);
      expect(_has('no channel connected'), findsOneWidget);
    });

    testWidgets('pasting a customer message creates a conversation', (
      tester,
    ) async {
      final fake = _Fake();
      await _pump(tester, fake);
      await _tap(tester, find.text('Paste a conversation'));
      await _tap(tester, find.text('Save conversation'));
      expect(find.text('Paste or type the message.'), findsOneWidget);
      expect(fake.calls, isNot(contains('create')));
      await tester.enterText(
        find.byType(TextField).last,
        'Do you have it in size M?',
      );
      await _tap(tester, find.text('Save conversation'));
      expect(fake.calls, contains('create'));
      expect(find.byType(ConversationScreen), findsOneWidget);
      expect(_has('Pasted manually from Instagram'), findsOneWidget);
    });

    testWidgets('a conversation that needs the seller shows the reason', (
      tester,
    ) async {
      await _pump(
        tester,
        _Fake(
          conversations: [
            _conv(status: 'needs_you', escalation: ['suspected_manipulation']),
          ],
        ),
      );
      expect(find.text('Needs you'), findsWidgets);
      expect(_has('Tried to give the assistant instructions'), findsOneWidget);
    });

    testWidgets('tablet shows list and conversation side by side', (
      tester,
    ) async {
      await _pump(
        tester,
        _Fake(conversations: [_conv()]),
        size: const Size(1280, 900),
      );
      expect(find.text('Select a conversation'), findsOneWidget);
      await _tap(tester, _has('Nzar'));
      expect(find.byType(ConversationScreen), findsOneWidget);
      expect(find.text('Select a conversation'), findsNothing);
    });
  });

  group('Conversation', () {
    testWidgets('a suggestion is labelled not sent and shows its sources', (
      tester,
    ) async {
      final fake = _Fake(conversations: [_conv()]);
      await _pump(tester, fake, route: Routes.conversation('c1'));
      await _tap(tester, find.text('Suggest a reply'));
      expect(fake.calls, contains('assist'));
      expect(find.text('Suggested reply — not sent'), findsOneWidget);
      expect(_has('35,000 IQD'), findsWidgets);
      expect(_has('Price · Beige Abaya / M'), findsOneWidget);
      expect(find.text('Suggest again'), findsOneWidget);
    });

    testWidgets('copying records "copied — not confirmed as sent"; the seller '
        'then marks it sent', (tester) async {
      String? clip;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clip = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      final fake = _Fake(
        conversations: [_conv(suggestion: _Fake.suggestionJson())],
      );
      await _pump(tester, fake, route: Routes.conversation('c1'));
      await _tap(tester, find.text('Copy reply'));
      expect(clip, contains('35,000 IQD'));
      expect(fake.calls, contains('copy'));
      expect(_has('AI reply copied · not confirmed as sent'), findsOneWidget);
      expect(find.text('Copied — not confirmed as sent'), findsOneWidget);
      // Never "Sent".
      expect(find.text('Sent'), findsNothing);
      await _tap(tester, find.text('I sent this'));
      expect(fake.calls, contains('sent'));
      expect(_has('Marked as sent by you'), findsOneWidget);
    });

    testWidgets('an escalated run offers only the holding reply', (
      tester,
    ) async {
      final fake = _Fake(conversations: [_conv()])
        ..nextAssist = (_) => (
          suggestion: _Fake.suggestionJson(
            text: 'Thank you for your message. The owner will reply to you personally shortly.',
            facts: const [],
            escalation: ['health_or_safety'],
            holding: true,
          ),
          status: 'succeeded',
          reasons: ['health_or_safety'],
        );
      await _pump(tester, fake, route: Routes.conversation('c1'));
      await _tap(tester, find.text('Suggest a reply'));
      expect(_has('The owner will reply to you personally'), findsOneWidget);
      expect(find.text('Needs you'), findsWidgets);
      expect(_has('Health or safety question'), findsOneWidget);
    });

    testWidgets('AI failure shows a clear message, retry and the manual path', (
      tester,
    ) async {
      final fake = _Fake(conversations: [_conv()]);
      await _pump(tester, fake, route: Routes.conversation('c1'));
      fake.failNext = const ApiException(ApiErrorCode.aiUnavailable);
      await _tap(tester, find.text('Suggest a reply'));
      expect(find.text('AI assistant temporarily unavailable.'), findsWidgets);
      expect(
        _has('You can reply yourself or create the order manually'),
        findsOneWidget,
      );
      // The messages are still there.
      expect(_has('how much is the beige abaya'), findsOneWidget);
      await _tap(tester, find.text('Retry'));
      expect(find.text('Suggested reply — not sent'), findsOneWidget);
    });

    testWidgets('a provider timeout recorded on the run is explained', (
      tester,
    ) async {
      final fake = _Fake(conversations: [_conv()])
        ..nextAssist = (_) =>
            (suggestion: null, status: 'timeout', reasons: <String>[]);
      await _pump(tester, fake, route: Routes.conversation('c1'));
      await _tap(tester, find.text('Suggest a reply'));
      expect(find.text('The AI took too long to answer.'), findsOneWidget);
    });

    testWidgets('with the AI switched off the buttons say why', (tester) async {
      final fake = _Fake(conversations: [_conv()])..aiEnabled = false;
      await _pump(tester, fake, route: Routes.conversation('c1'));
      expect(
        find.text('The AI assistant is switched off for your store.'),
        findsWidgets,
      );
      await tester.tap(find.text('Suggest a reply'));
      await tester.pumpAndSettle();
      expect(fake.calls, isNot(contains('assist')));
    });

    testWidgets('the AI draft is shown as not confirmed and opens the order', (
      tester,
    ) async {
      final fake = _Fake(
        conversations: [
          _conv(
            order: {
              'id': 'o1',
              'number': 1001,
              'status': 'pending_approval',
              'is_test': false,
              'total': 75000,
              'currency': 'IQD',
              'issues': <Object>[],
            },
          ),
        ],
      );
      await _pump(tester, fake, route: Routes.conversation('c1'));
      expect(_has('#1001'), findsOneWidget);
      expect(_has('not confirmed'), findsOneWidget);
    });

    testWidgets('sandbox conversations carry the test banner', (tester) async {
      await _pump(
        tester,
        _Fake(conversations: [_conv(source: 'sandbox')]),
        route: Routes.conversation('c1'),
      );
      expect(
        find.text('Sandbox — test only, not a real customer'),
        findsOneWidget,
      );
    });

    testWidgets(
      'Sorani: RTL layout, Sorani labels, reply in its own language',
      (tester) async {
        final fake = _Fake(
          conversations: [
            _conv(
              suggestion: _Fake.suggestionJson(
                text: 'سڵاو! نرخی Beige Abaya 35,000 د.ع یە.',
                language: 'ckb',
              ),
            ),
          ],
        );
        await _pump(
          tester,
          fake,
          route: Routes.conversation('c1'),
          locale: 'ckb',
        );
        final dir = Directionality.of(
          tester.element(find.byType(ConversationScreen)),
        );
        expect(dir, TextDirection.rtl);
        expect(find.text('وەڵامی پێشنیارکراو — نەنێردراوە'), findsOneWidget);
        expect(_has('35,000 د.ع'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('AI drafts on the order screen', () {
    testWidgets('attributed to the AI, linked to the conversation, with the '
        'unresolved line for the seller to choose', (tester) async {
      final orders = sampleOrders();
      orders.overlays['order-1006'] = {
        'origin': 'ai',
        'status': 'draft',
        'conversation_id': 'c1',
        'events': [
          {
            'from': null,
            'to': 'draft',
            'actor': 'ai',
            'created_at': '2026-10-15T08:00:00Z',
          },
        ],
        'issues': [
          {'field': 'lines', 'kind': 'unresolved', 'item_id': 'l-ai'},
        ],
        'lines': [
          {
            'id': 'l-ai',
            'variant_id': null,
            'name': 'the black one',
            'variant_label': '',
            'quantity': 1,
            'quantity_basis': 'inferred',
            'resolution': 'choose_product',
            'customer_text': 'the black one',
            'unit_price': 0,
            'line_total': 0,
            'stock_deducted': 0,
            'candidates': [
              {
                'variant_id': 'p-abaya-v0',
                'name': 'Black Abaya',
                'variant_label': '',
                'price': 40000,
                'available': true,
              },
            ],
          },
        ],
      };
      await _pump(
        tester,
        _Fake(conversations: [_conv()]),
        orders: orders,
        route: Routes.order('order-1006'),
      );
      expect(_has('Prepared by the AI assistant'), findsOneWidget);
      expect(find.text('Choose product'), findsOneWidget);
      expect(_has('Customer asked for: “the black one”'), findsOneWidget);
      expect(_has('Black Abaya'), findsWidgets);
      expect(_has('the AI assistant'), findsWidgets);
      // An unresolved line is an issue, not a "no longer sold" line.
      expect(find.text('No longer sold'), findsNothing);
      await _tap(tester, find.text('Open conversation'));
      expect(find.byType(ConversationScreen), findsOneWidget);
    });
  });

  group('AI settings', () {
    testWidgets('the owner switches the AI and writes a policy', (
      tester,
    ) async {
      final fake = _Fake();
      await _pump(tester, fake, route: Routes.storeAi);
      expect(_has('No written policies yet'), findsOneWidget);
      await _tap(tester, find.byType(Switch));
      expect(fake.aiEnabled, isFalse);
      await _tap(tester, find.text('Add policy'));
      await tester.enterText(
        find.byType(TextField).last,
        'Exchange within 3 days if unworn.',
      );
      await _tap(tester, find.text('Save'));
      expect(fake.calls, contains('policy'));
      expect(_has('Exchange within 3 days'), findsOneWidget);
    });
  });
}
