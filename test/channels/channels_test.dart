import 'package:aisellia/app/router.dart';
import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/design_system/components/app_button.dart';
import 'package:aisellia/features/channels/domain/channel.dart';
import 'package:aisellia/features/inbox/domain/conversation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

typedef _Conv = FakeConversationsRepository;
typedef _Ch = FakeChannelsRepository;

void _go(WidgetTester tester, String path) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(routerProvider)
        .go(path);

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

Future<void> _pump(
  WidgetTester tester, {
  required _Conv conversations,
  required _Ch channels,
  required String route,
  String locale = 'en',
  Size size = const Size(390, 844),
  Future<bool> Function(Uri)? openUrl,
}) async {
  await loadAppFonts();
  setScreen(tester, size: size);
  await tester.pumpWidget(
    testApp(
      conversations: conversations,
      channels: channels,
      sampleData: false,
      locale: locale,
      openUrl: openUrl,
    ),
  );
  await tester.pumpAndSettle();
  _go(tester, route);
  await tester.pumpAndSettle();
}

const _customerText = 'Salam, how much is the beige abaya size M?';
const _reply = 'The Beige Abaya in size M is available, price 35,000 IQD.';

Map<String, dynamic> _live({
  String id = 'live1',
  Map<String, dynamic>? channel,
  Map<String, dynamic>? suggestion,
  List<Map<String, dynamic>> extra = const [],
  Map<String, dynamic>? order,
}) => _Conv.conversationJson(
  id: id,
  label: 'Nzar',
  source: 'live',
  channel: channel ?? _Ch.channelJson(),
  suggestion: suggestion,
  order: order,
  messages: [
    _Conv.messageJson(
      'in1',
      _customerText,
      origin: 'channel_in',
      state: 'live',
    ),
    ...extra,
  ],
);

void main() {
  group('Domain', () {
    test('five connection states, unknown values degrade to disconnected', () {
      expect(
        [
          'disconnected',
          'awaiting_authorization',
          'connected',
          'error',
          'unavailable',
          'bogus',
        ].map(ConnectionUiState.parse),
        [
          ConnectionUiState.disconnected,
          ConnectionUiState.awaitingAuthorization,
          ConnectionUiState.connected,
          ConnectionUiState.error,
          ConnectionUiState.unavailable,
          ConnectionUiState.disconnected,
        ],
      );
      expect(ConnectMethod.parse('bot_token')!.usesBrowser, isFalse);
      expect(ConnectMethod.parse('meta_login')!.usesBrowser, isTrue);
      expect(ConnectMethod.parse('carrier_pigeon'), isNull);
    });

    test('templates render like the server (same cases as pgTAP suite 24)', () {
      const t = MessageTemplate(
        id: 't',
        name: 'order_ready',
        language: 'ckb',
        body: 'سڵاو {{1}}، داواکارییەکەت {{2}} ئامادەیە. Order {{2}} is ready.',
        paramCount: 2,
      );
      expect(
        t.render(['ئارام', 'A-17']),
        'سڵاو ئارام، داواکارییەکەت A-17 ئامادەیە. Order A-17 is ready.',
      );
      const odd = MessageTemplate(
        id: 'o',
        name: 'odd',
        language: 'en',
        body: '{{1}}{{1}} {{2}}',
        paramCount: 2,
      );
      expect(odd.render([r'$&', '{1}']), r'$&$& {1}');
      // The server's parameter rule.
      expect(MessageTemplate.paramOk('A-17'), isTrue);
      for (final bad in ['', 'A\n17', 'A    17', '{{2}}', 'x' * 301, 'a\tb']) {
        expect(MessageTemplate.paramOk(bad), isFalse, reason: bad);
      }
    });

    test('a live conversation parses its channel, delivery and send', () {
      final c = Conversation.fromJson({
        ..._live(
          extra: [
            _Conv.messageJson(
              'o1',
              'ok',
              inbound: false,
              origin: 'seller_sent',
              state: 'live',
              delivery: 'unknown',
              send: {
                'id': 's1',
                'state': 'unknown',
                'kind': 'reply',
                'attempts': 1,
                'can_cancel': false,
                'can_resolve': true,
              },
            ),
          ],
        ),
        'ai': {'enabled': true, 'calls_today': 0, 'daily_limit': 300},
      });
      expect(c.summary.isLive, isTrue);
      expect(c.summary.source, ConversationSource.live);
      expect(c.summary.channel!.providerName, 'WhatsApp');
      expect(c.messages.first.origin, MessageOrigin.channelIn);
      expect(c.messages.last.delivery, DeliveryState.unknown);
      expect(c.messages.last.send!.canResolve, isTrue);
      expect(DeliveryState.parse('teleported'), isNull);
    });

    test('channel errors map to their own codes', () {
      for (final (wire, code) in [
        ('REPLY_WINDOW_CLOSED', ApiErrorCode.replyWindowClosed),
        ('CHANNEL_NOT_CONNECTED', ApiErrorCode.channelUnavailable),
        ('CHANNEL_CAPABILITY_MISSING', ApiErrorCode.channelUnavailable),
        ('CONTACT_BLOCKED', ApiErrorCode.contactUnavailable),
        ('CONTACT_ANONYMIZED', ApiErrorCode.contactUnavailable),
        ('SEND_NOT_UNKNOWN', ApiErrorCode.sendStateChanged),
        ('TOKEN_REJECTED', ApiErrorCode.tokenRejected),
        ('ACCOUNT_IN_USE', ApiErrorCode.accountInUse),
      ]) {
        expect(
          () => unwrapEnvelope({
            'ok': false,
            'error': {'code': wire},
          }),
          throwsA(isA<ApiException>().having((e) => e.code, wire, code)),
        );
      }
    });
  });

  group('Connected accounts', () {
    testWidgets('lists accounts in their states and the providers to add', (
      tester,
    ) async {
      final ch = _Ch(
        connections: [
          _Ch.connectionJson(id: 'k1', name: 'Shop bot'),
          _Ch.connectionJson(
            id: 'k2',
            provider: 'whatsapp',
            name: 'Shop WhatsApp',
            uiState: 'unavailable',
          ),
          _Ch.connectionJson(
            id: 'k3',
            provider: 'viber',
            name: 'Shop Viber',
            uiState: 'error',
          ),
        ],
      );
      await _pump(
        tester,
        conversations: _Conv(),
        channels: ch,
        route: Routes.storeChannels,
      );
      expect(_has('Shop bot'), findsOneWidget);
      expect(_has('Connected'), findsWidgets);
      expect(_has('Sending not available yet'), findsOneWidget);
      expect(_has('Messages are received, but replies cannot'), findsOneWidget);
      expect(_has('Needs attention'), findsOneWidget);
      // A provider that is not released cannot be opened.
      expect(_has('Not available yet'), findsOneWidget);
      await _tap(tester, _has('TikTok'));
      expect(_has('Connect TikTok'), findsNothing);
    });

    testWidgets('a bot connects with its token; the token is never kept', (
      tester,
    ) async {
      final ch = _Ch();
      await _pump(
        tester,
        conversations: _Conv(),
        channels: ch,
        route: Routes.storeChannels,
      );
      expect(_has('No account connected yet.'), findsOneWidget);
      await _tap(tester, _has('Telegram'));
      expect(_has('Connect Telegram'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'too short');
      await _tap(tester, find.widgetWithText(AppButton, 'Connect'));
      expect(_has('Paste the whole token, without spaces.'), findsOneWidget);
      expect(ch.calls.where((c) => c.startsWith('connectBot')), isEmpty);

      await tester.enterText(
        find.byType(TextField).last,
        '123456789:AAEexampleexampleexampleexample',
      );
      await _tap(tester, find.widgetWithText(AppButton, 'Connect'));
      expect(
        ch.calls,
        containsAllInOrder([
          'begin:telegram',
          'connectBot:telegram:nonce-1:***',
        ]),
      );
      expect(ch.calls.join(), isNot(contains('AAEexample')));
      expect(_has('Shop bot'), findsOneWidget);
    });

    testWidgets('a token the provider refuses shows a clear error', (
      tester,
    ) async {
      final ch = _Ch();
      await _pump(
        tester,
        conversations: _Conv(),
        channels: ch,
        route: Routes.storeChannels,
      );
      await _tap(tester, _has('Telegram'));
      await tester.enterText(
        find.byType(TextField).last,
        '123456789:AAEexampleexampleexampleexample',
      );
      ch.refuseToken = const ApiException(ApiErrorCode.tokenRejected);
      await _tap(tester, find.widgetWithText(AppButton, 'Connect'));
      expect(_has('The provider did not accept this token.'), findsOneWidget);
      expect(ch.connectionRows, isEmpty);
      // The sheet stays open with the error; nothing was connected.
      expect(_has('Connect Telegram'), findsOneWidget);
    });

    testWidgets('Instagram opens the provider page (https) for authorization', (
      tester,
    ) async {
      final opened = <Uri>[];
      final ch = _Ch();
      await _pump(
        tester,
        conversations: _Conv(),
        channels: ch,
        route: Routes.storeChannels,
        openUrl: (u) async {
          opened.add(u);
          return true;
        },
      );
      await _tap(tester, _has('Instagram'));
      await _tap(tester, find.widgetWithText(AppButton, 'Open Instagram'));
      expect(opened.single.scheme, 'https');
      expect(opened.single.queryParameters['state'], 'nonce-1');
      expect(_has('Waiting for authorization'), findsOneWidget);
    });

    testWidgets('a page that cannot be opened is reported', (tester) async {
      await _pump(
        tester,
        conversations: _Conv(),
        channels: _Ch(),
        route: Routes.storeChannels,
        openUrl: (_) async => false,
      );
      await _tap(tester, _has('Instagram'));
      await _tap(tester, find.widgetWithText(AppButton, 'Open Instagram'));
      expect(_has('The page could not be opened.'), findsOneWidget);
    });

    testWidgets('disconnecting asks first, then removes the account', (
      tester,
    ) async {
      final ch = _Ch(connections: [_Ch.connectionJson(name: 'Shop bot')]);
      await _pump(
        tester,
        conversations: _Conv(),
        channels: ch,
        route: Routes.storeChannels,
      );
      await _tap(tester, find.widgetWithText(AppButton, 'Disconnect'));
      expect(_has('Disconnect Shop bot?'), findsOneWidget);
      await _tap(tester, find.widgetWithText(AppButton, 'Cancel'));
      expect(ch.calls.where((c) => c.startsWith('disconnect')), isEmpty);
      await _tap(tester, find.widgetWithText(AppButton, 'Disconnect'));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(AppButton, 'Disconnect'),
        ),
      );
      expect(ch.calls, contains('disconnect:k1'));
      expect(_has('No account connected yet.'), findsOneWidget);
    });

    testWidgets('the store menu opens connected accounts', (tester) async {
      await _pump(
        tester,
        conversations: _Conv(),
        channels: _Ch(),
        route: Routes.store,
      );
      await _tap(tester, _has('Connected accounts'));
      // The providers the store can add are listed.
      expect(_has('Telegram'), findsOneWidget);
      expect(_has('No account connected yet.'), findsOneWidget);
    });
  });

  group('Live conversation', () {
    testWidgets(
      '"Use this reply" fills the reply box; nothing is sent until the exact text is confirmed',
      (tester) async {
        final conv = _Conv(
          conversations: [
            _live(suggestion: _Conv.suggestionJson(text: _reply)),
          ],
        );
        final ch = _Ch(conversations: conv);
        await _pump(
          tester,
          conversations: conv,
          channels: ch,
          route: Routes.conversation('live1'),
        );
        expect(_has('Arrived through Shop.'), findsOneWidget);
        expect(_has('From the customer'), findsOneWidget);
        expect(find.text('Copy reply'), findsNothing);
        await _tap(tester, find.text('Use this reply'));
        final box = find.descendant(
          of: find.byKey(const ValueKey('live-composer')),
          matching: find.byType(TextField),
        );
        expect(tester.widget<TextField>(box).controller!.text, _reply);

        // The seller edits, then backs out of the confirmation.
        await tester.enterText(box, '$_reply Delivery tomorrow.');
        await _tap(tester, find.widgetWithText(AppButton, 'Send'));
        expect(_has('Send this message?'), findsOneWidget);
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('send-confirm-text')),
              )
              .data,
          '$_reply Delivery tomorrow.',
        );
        await _tap(tester, find.widgetWithText(AppButton, 'Cancel'));
        expect(ch.sentTexts, isEmpty);

        await _tap(tester, find.widgetWithText(AppButton, 'Send'));
        await _tap(
          tester,
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(AppButton, 'Send'),
          ),
        );
        expect(ch.sentTexts, ['$_reply Delivery tomorrow.']);
        expect(ch.calls, contains('send:reply:s-1'));
        expect(_has('Sent by you from Aisellia'), findsOneWidget);
        expect(_has('Sent'), findsWidgets);
        expect(tester.widget<TextField>(box).controller!.text, isEmpty);
      },
    );

    testWidgets('an unknown outcome is never resent without the seller', (
      tester,
    ) async {
      final conv = _Conv(conversations: [_live()]);
      final ch = _Ch(conversations: conv)..dispatchOutcome = 'unknown';
      await _pump(
        tester,
        conversations: conv,
        channels: ch,
        route: Routes.conversation('live1'),
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('live-composer')),
          matching: find.byType(TextField),
        ),
        'Your order is on its way.',
      );
      await _tap(tester, find.widgetWithText(AppButton, 'Send'));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(AppButton, 'Send'),
        ),
      );
      expect(_has('Not known if sent'), findsOneWidget);
      expect(_has('It is never resent automatically.'), findsOneWidget);
      expect(ch.sentTexts, hasLength(1));

      // "Send again" asks first (the customer could get it twice).
      await _tap(tester, find.widgetWithText(AppButton, 'Send again'));
      expect(_has('the customer will receive it twice'), findsOneWidget);
      await _tap(tester, find.widgetWithText(AppButton, 'Cancel'));
      expect(ch.sentTexts, hasLength(1));

      await _tap(tester, find.widgetWithText(AppButton, 'It arrived'));
      expect(ch.calls, contains('resolve:send-1:mark_sent'));
      expect(_has('Not known if sent'), findsNothing);
      expect(ch.sentTexts, hasLength(1));
    });

    testWidgets('"Send again" creates a new send and submits it', (
      tester,
    ) async {
      final conv = _Conv(conversations: [_live()]);
      final ch = _Ch(conversations: conv)..dispatchOutcome = 'unknown';
      await _pump(
        tester,
        conversations: conv,
        channels: ch,
        route: Routes.conversation('live1'),
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('live-composer')),
          matching: find.byType(TextField),
        ),
        'Your order is on its way.',
      );
      await _tap(tester, find.widgetWithText(AppButton, 'Send'));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(AppButton, 'Send'),
        ),
      );
      ch.dispatchOutcome = 'delivered';
      await _tap(tester, find.widgetWithText(AppButton, 'Send again'));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(AppButton, 'Send again'),
        ),
      );
      expect(
        ch.calls,
        containsAllInOrder(['resolve:send-1:send_again', 'dispatch:send-2']),
      );
      expect(_has('Delivered'), findsOneWidget);
    });

    testWidgets('a failed send shows why, from the safe error code', (
      tester,
    ) async {
      final conv = _Conv(
        conversations: [
          _live(
            extra: [
              _Conv.messageJson(
                'o1',
                'Earlier reply',
                inbound: false,
                origin: 'seller_sent',
                state: 'live',
                delivery: 'failed',
                send: {
                  'id': 'sx',
                  'state': 'failed',
                  'kind': 'reply',
                  'error_code': 'recipient_unavailable',
                  'attempts': 1,
                },
              ),
              _Conv.messageJson(
                'o2',
                'Queued reply',
                inbound: false,
                origin: 'seller_sent',
                state: 'live',
                delivery: 'queued',
                send: {
                  'id': 'sq',
                  'state': 'queued',
                  'kind': 'reply',
                  'attempts': 1,
                  'can_cancel': true,
                },
              ),
            ],
          ),
        ],
      );
      final ch = _Ch(conversations: conv);
      ch.calls.clear();
      await _pump(
        tester,
        conversations: conv,
        channels: ch,
        route: Routes.conversation('live1'),
      );
      expect(_has('Not sent'), findsOneWidget);
      expect(
        _has('This customer cannot receive messages from the store.'),
        findsOneWidget,
      );
      expect(_has('Will be tried again automatically.'), findsOneWidget);
      // The fake only knows sends it created; the cancel reaches the server.
      ch.failNext = const ApiException(ApiErrorCode.sendStateChanged);
      await _tap(tester, find.widgetWithText(AppButton, 'Cancel sending'));
      expect(ch.calls, contains('cancel:sq'));
      expect(_has('This message changed meanwhile.'), findsOneWidget);
    });

    testWidgets(
      'window closed: no free text, an approved template with its parameters instead',
      (tester) async {
        final conv = _Conv(
          conversations: [
            _live(
              channel: _Ch.channelJson(windowOpen: false, templates: true),
              suggestion: _Conv.suggestionJson(text: _reply),
            ),
          ],
        );
        final ch = _Ch(
          conversations: conv,
          templateItems: [
            {
              'id': 't1',
              'name': 'order_ready',
              'language': 'en',
              'body_text': 'Hello {{1}}, your order {{2}} is ready.',
              'param_count': 2,
            },
          ],
        );
        await _pump(
          tester,
          conversations: conv,
          channels: ch,
          route: Routes.conversation('live1'),
        );
        expect(_has('Customer-service window closed'), findsOneWidget);
        expect(find.byKey(const ValueKey('live-composer')), findsNothing);
        // "Use this reply" cannot be used while the window is closed.
        final use = tester.widget<AppButton>(
          find.widgetWithText(AppButton, 'Use this reply'),
        );
        expect(use.onPressed, isNull);

        await _tap(tester, find.text('Send an approved template'));
        await _tap(tester, find.text('order_ready'));
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('template-param-0')),
            matching: find.byType(TextField),
          ),
          'Nzar',
        );
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('template-param-1')),
            matching: find.byType(TextField),
          ),
          'A    17',
        );
        await tester.pumpAndSettle();
        await _tap(tester, find.widgetWithText(AppButton, 'Send').last);
        expect(_has('Each value needs 1 to 300 characters'), findsOneWidget);

        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('template-param-1')),
            matching: find.byType(TextField),
          ),
          'A-17',
        );
        await tester.pumpAndSettle();
        expect(_has('Hello Nzar, your order A-17 is ready.'), findsOneWidget);
        await _tap(tester, find.widgetWithText(AppButton, 'Send').last);
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('send-confirm-text')),
              )
              .data,
          'Hello Nzar, your order A-17 is ready.',
        );
        await _tap(
          tester,
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(AppButton, 'Send'),
          ),
        );
        expect(ch.calls, contains('sendTemplate:t1:Nzar|A-17'));
        expect(ch.sentTexts, ['Hello Nzar, your order A-17 is ready.']);
      },
    );

    testWidgets('an account that cannot send explains why and offers no send', (
      tester,
    ) async {
      final conv = _Conv(
        conversations: [
          _live(channel: _Ch.channelJson(uiState: 'unavailable')),
        ],
      );
      await _pump(
        tester,
        conversations: conv,
        channels: _Ch(conversations: conv),
        route: Routes.conversation('live1'),
      );
      expect(
        _has('Replies cannot be sent from this account right now.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('live-composer')), findsNothing);
      expect(find.text('Send an approved template'), findsNothing);
    });

    testWidgets(
      'an approved order\'s confirmation is server text, confirmed first',
      (tester) async {
        final conv = _Conv(
          conversations: [
            _live(
              order: {
                'id': 'o1',
                'number': 1001,
                'status': 'approved',
                'is_test': false,
                'total': 75000,
                'currency': 'IQD',
                'issues': <Object>[],
              },
            ),
          ],
        );
        final ch = _Ch(conversations: conv);
        await _pump(
          tester,
          conversations: conv,
          channels: ch,
          route: Routes.conversation('live1'),
        );
        await _tap(tester, find.text('Send order confirmation'));
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('send-confirm-text')),
              )
              .data,
          'Order #1001 is confirmed: 75,000 IQD.',
        );
        await _tap(
          tester,
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(AppButton, 'Send'),
          ),
        );
        expect(ch.calls, contains('send:order_confirmation:-'));
      },
    );

    testWidgets(
      'the inbox names the channel and flags a reply that did not go out',
      (tester) async {
        final conv = _Conv(
          conversations: [
            {
              ..._live(),
              'last_message': {
                'direction': 'out',
                'preview': 'Your order is ready',
                'delivery_state': 'failed',
              },
            },
          ],
        );
        await _pump(
          tester,
          conversations: conv,
          channels: _Ch(conversations: conv),
          route: Routes.inbox,
        );
        expect(_has('WhatsApp'), findsWidgets);
        expect(_has('Not sent'), findsOneWidget);
      },
    );

    for (final locale in ['ckb']) {
      testWidgets('live conversation lays out right to left in $locale', (
        tester,
      ) async {
        final conv = _Conv(
          conversations: [
            _live(suggestion: _Conv.suggestionJson(text: _reply)),
          ],
        );
        await _pump(
          tester,
          conversations: conv,
          channels: _Ch(conversations: conv),
          route: Routes.conversation('live1'),
          locale: locale,
          size: const Size(320, 640),
        );
        expect(tester.takeException(), isNull);
        expect(
          Directionality.of(tester.element(find.byType(Scaffold).first)),
          TextDirection.rtl,
        );
      });
    }
  });
}
