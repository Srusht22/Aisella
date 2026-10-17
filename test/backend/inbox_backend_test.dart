// Phase 8 end-to-end tests against the LOCAL Supabase stack: the app's own
// conversations repository, real JWTs, PostgREST and Postgres. Run like
// backend_integration_test.dart (tag `backend`). The AI model itself is not
// called here (see supabase/functions/ai-assist/tests for the worker).
@Tags(['backend'])
library;

import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/features/inbox/data/conversations_repository.dart';
import 'package:aisellia/features/inbox/domain/conversation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_support.dart';
import 'catalog_backend_test.dart' show newIdempotencyKeyForTest, newSeller;

Future<Object> attempt(Future<Object?> call) =>
    call.then<Object>((r) => r ?? 'ok').catchError((Object e) => e);

void main() {
  group('Conversations through PostgREST', skip: backendSkip, () {
    test('paste, import, reply, status, and nothing is ever "sent"', () async {
      final a = await newSeller('inbox-a');
      final repo = SupabaseConversationsRepository(a.client);
      final key = newIdempotencyKeyForTest();
      final id = await repo.create(
        a.storeId,
        source: ConversationSource.whatsapp,
        customerLabel: 'Nzar',
        messages: [(inbound: true, body: 'Hi, is the beige abaya in M?')],
        idempotencyKey: key,
      );
      // A retry with the same key creates nothing new.
      expect(
        await repo.create(
          a.storeId,
          source: ConversationSource.whatsapp,
          customerLabel: 'Nzar',
          messages: [(inbound: true, body: 'Hi, is the beige abaya in M?')],
          idempotencyKey: key,
        ),
        id,
      );
      var c = await repo.get(a.storeId, id);
      expect(c.summary.status, ConversationStatus.needsReply);
      expect(c.messages.single.origin, MessageOrigin.imported);
      expect(c.aiEnabled, isTrue);

      await repo.recordSellerReply(
        a.storeId,
        id,
        'Yes, it is.',
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      c = await repo.get(a.storeId, id);
      expect(c.summary.status, ConversationStatus.waiting);
      expect(c.messages.last.state, MessageState.markedSent);

      await repo.importMessages(a.storeId, id, [
        (inbound: true, body: 'Great, 2 please'),
      ], idempotencyKey: newIdempotencyKeyForTest());
      c = await repo.get(a.storeId, id);
      expect(c.summary.status, ConversationStatus.needsReply);
      expect(c.messages.length, 3);

      await repo.update(
        a.storeId,
        id,
        expectedVersion: c.summary.version,
        status: ConversationStatus.closed,
      );
      expect(
        (await repo.list(a.storeId, InboxFilter.closed)).items.map((i) => i.id),
        contains(id),
      );
      expect(
        (await repo.list(a.storeId, InboxFilter.open)).items.map((i) => i.id),
        isNot(contains(id)),
      );
    });

    test('policies and the AI switch', () async {
      final a = await newSeller('inbox-pol');
      final repo = SupabaseConversationsRepository(a.client);
      final p = await repo.upsertPolicy(
        a.storeId,
        topic: PolicyTopic.exchange,
        body: 'Exchange within 3 days if unworn.',
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      expect((await repo.aiSettings(a.storeId)).policies.single.id, p.id);
      await repo.setAiEnabled(a.storeId, false);
      expect((await repo.aiSettings(a.storeId)).enabled, isFalse);
      final id = await repo.create(
        a.storeId,
        source: ConversationSource.other,
        messages: [(inbound: true, body: 'Hello')],
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      // The switch is enforced by the database, before any AI call.
      final denied = await attempt(
        callApi(
          a.client,
          'request_ai_assist',
          params: {
            'p_store_id': a.storeId,
            'p_conversation_id': id,
            'p_mode': 'reply',
            'p_idempotency_key': newIdempotencyKeyForTest(),
          },
        ),
      );
      expect((denied as ApiException).code, ApiErrorCode.aiDisabled);
      await repo.deletePolicy(a.storeId, p.id, expectedVersion: p.version);
      expect((await repo.aiSettings(a.storeId)).policies, isEmpty);
    });

    test('another seller sees nothing and changes nothing', () async {
      final a = await newSeller('inbox-iso-a');
      final b = await newSeller('inbox-iso-b');
      final repoA = SupabaseConversationsRepository(a.client);
      final repoB = SupabaseConversationsRepository(b.client);
      final id = await repoA.create(
        a.storeId,
        source: ConversationSource.instagram,
        messages: [(inbound: true, body: 'Private message for A')],
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      for (final call in <Future<Object?> Function()>[
        () => repoB.get(a.storeId, id),
        () => repoB.get(b.storeId, id),
        () => repoB.importMessages(a.storeId, id, [
          (inbound: true, body: 'x'),
        ], idempotencyKey: newIdempotencyKeyForTest()),
        () => repoB.deleteConversation(a.storeId, id),
        () => repoB.list(a.storeId, InboxFilter.open),
      ]) {
        final e = await attempt(call());
        expect((e as ApiException).code, ApiErrorCode.notFound);
      }
      expect((await repoB.list(b.storeId, InboxFilter.open)).items, isEmpty);
      expect((await repoA.get(a.storeId, id)).messages.length, 1);
    });

    test('without the AI worker running, asking for help fails cleanly and '
        'everything else keeps working', () async {
      final a = await newSeller('inbox-ai-down');
      final repo = SupabaseConversationsRepository(a.client);
      final id = await repo.create(
        a.storeId,
        source: ConversationSource.instagram,
        messages: [(inbound: true, body: 'How much?')],
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      final e = await attempt(
        repo.requestAssist(
          a.storeId,
          id,
          idempotencyKey: newIdempotencyKeyForTest(),
        ),
      );
      expect(e, isA<ApiException>());
      final c = await repo.get(a.storeId, id);
      expect(c.messages.single.body, 'How much?');
      expect(c.suggestion, isNull);
    });
  });
}
