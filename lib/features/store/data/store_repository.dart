import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/api.dart';
import '../domain/store.dart';

/// Store, onboarding and delivery-zone operations. Every call is authorized by
/// the server; the client never decides which store it may touch.
abstract interface class StoreRepository {
  Future<AccountContext> loadContext();

  Future<Store> createStore(StoreDraft draft, {required String idempotencyKey});

  /// [changes] uses API field names (`name`, `contact_phone`, `currency`,
  /// `reply_locale`, `business_city`, `cod_enabled`, `other_payment_enabled`).
  Future<Store> updateStore(
    String storeId, {
    required int expectedVersion,
    required Map<String, Object> changes,
    required String idempotencyKey,
  });

  Future<Store> advanceOnboarding(String storeId, OnboardingStep step);

  Future<List<DeliveryZone>> listZones(String storeId);

  Future<DeliveryZone> upsertZone(
    String storeId, {
    String? zoneId,
    int? expectedVersion,
    required String name,
    required int fee,
    String? timeText,
    required String idempotencyKey,
  });

  Future<void> deactivateZone(
    String storeId, {
    required String zoneId,
    required int expectedVersion,
  });
}

class SupabaseStoreRepository implements StoreRepository {
  SupabaseStoreRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<AccountContext> loadContext() async =>
      AccountContext.fromJson(await callApi(_client, 'get_my_context'));

  @override
  Future<Store> createStore(
    StoreDraft draft, {
    required String idempotencyKey,
  }) async => Store.fromJson(
    await callApi(
      _client,
      'create_store',
      params: {
        'p_name': draft.name,
        'p_contact_phone': draft.contactPhone,
        'p_currency': currencyCode(draft.currency),
        'p_reply_locale': draft.replyLocale,
        'p_business_city': draft.businessCity,
        'p_idempotency_key': idempotencyKey,
      },
    ),
  );

  @override
  Future<Store> updateStore(
    String storeId, {
    required int expectedVersion,
    required Map<String, Object> changes,
    required String idempotencyKey,
  }) async => Store.fromJson(
    await callApi(
      _client,
      'update_store',
      params: {
        'p_store_id': storeId,
        'p_expected_version': expectedVersion,
        'p_changes': changes,
        'p_idempotency_key': idempotencyKey,
      },
    ),
  );

  @override
  Future<Store> advanceOnboarding(String storeId, OnboardingStep step) async =>
      Store.fromJson(
        await callApi(
          _client,
          'advance_onboarding',
          params: {'p_store_id': storeId, 'p_step': step.name},
        ),
      );

  @override
  Future<List<DeliveryZone>> listZones(String storeId) async {
    try {
      final rows = await _client
          .from('delivery_zones')
          .select('id, name, fee, time_text, version')
          .eq('store_id', storeId)
          .eq('active', true)
          .order('sort')
          .timeout(apiTimeout);
      return [for (final row in rows) DeliveryZone.fromJson(row)];
    } on PostgrestException catch (e) {
      throw mapPostgrestException(e);
    } on Exception catch (e) {
      throw e is ApiException ? e : const ApiException(ApiErrorCode.network);
    }
  }

  @override
  Future<DeliveryZone> upsertZone(
    String storeId, {
    String? zoneId,
    int? expectedVersion,
    required String name,
    required int fee,
    String? timeText,
    required String idempotencyKey,
  }) async => DeliveryZone.fromJson(
    await callApi(
      _client,
      'upsert_zone',
      params: {
        'p_store_id': storeId,
        'p_zone_id': zoneId,
        'p_expected_version': expectedVersion,
        'p_name': name,
        'p_fee': fee,
        'p_time_text': timeText,
        'p_idempotency_key': idempotencyKey,
      },
    ),
  );

  @override
  Future<void> deactivateZone(
    String storeId, {
    required String zoneId,
    required int expectedVersion,
  }) async {
    await callApi(
      _client,
      'deactivate_zone',
      params: {
        'p_store_id': storeId,
        'p_zone_id': zoneId,
        'p_expected_version': expectedVersion,
      },
    );
  }
}
