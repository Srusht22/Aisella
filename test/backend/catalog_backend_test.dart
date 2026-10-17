// Phase 6 end-to-end tests against the LOCAL Supabase stack: the app's own
// catalog repository and media store, real JWTs, PostgREST, Postgres and the
// Storage API. Run like backend_integration_test.dart (tag `backend`).
@Tags(['backend'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/core/formatting/money.dart';
import 'package:aisellia/features/catalog/data/catalog_repository.dart';
import 'package:aisellia/features/catalog/data/media_store.dart';
import 'package:aisellia/features/catalog/domain/catalog.dart';
import 'package:aisellia/features/catalog/domain/product_draft.dart';
import 'package:aisellia/features/store/data/store_repository.dart';
import 'package:aisellia/features/store/domain/store.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import 'backend_support.dart';

class Seller {
  Seller(this.client, this.storeId);
  final SupabaseClient client;
  final String storeId;
  CatalogRepository get catalog => SupabaseCatalogRepository(client);
  SupabaseMediaStore get media => SupabaseMediaStore(client);
}

Future<Seller> newSeller(String who) async {
  final client = await verifiedSeller(uniqueEmail(who));
  final store = await SupabaseStoreRepository(client).createStore(
    const StoreDraft(
      name: 'Catalog test',
      contactPhone: '+9647501234567',
      currency: Currency.iqd,
      replyLocale: 'ckb',
      businessCity: 'erbil',
    ),
    idempotencyKey: newIdempotencyKeyForTest(),
  );
  return Seller(client, store.id);
}

String newIdempotencyKeyForTest() =>
    productImagePath('x', 'y').split('/')[3].replaceAll('.jpg', '');

Uint8List photo() {
  final image = img.Image(width: 900, height: 1200);
  img.fill(image, color: img.ColorRgb8(30, 90, 160));
  image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(36, 1);
  return img.encodeJpg(image);
}

Future<(int, String?)> fetch(String url) async {
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    final type = res.headers.contentType?.mimeType;
    await res.drain<void>();
    return (res.statusCode, type);
  } finally {
    client.close();
  }
}

Future<String> signedUrl(SupabaseMediaStore media, String path) async =>
    ((await media.image(path)) as NetworkImage).url;

ProductDraft shirt({List<String> images = const [], int stock = 5}) =>
    ProductDraft(
      name: 'Linen Shirt',
      category: 'Clothing',
      basePrice: 25000,
      optionTypes: const [
        OptionType(name: 'Size', values: ['S', 'M']),
      ],
      variants: [
        VariantDraft(
          optionValues: const ['S'],
          sku: 'SH-S-${DateTime.now().microsecondsSinceEpoch}',
          initialStock: stock,
        ),
        const VariantDraft(optionValues: ['M'], priceOverride: 27000),
      ],
      images: images,
    );

void main() {
  group('Catalog through PostgREST and Storage', skip: backendSkip, () {
    test('create with an uploaded image, read back, search, summary', () async {
      final a = await newSeller('cat-a');
      final productId = newIdempotencyKeyForTest();
      final path = productImagePath(a.storeId, productId);
      await a.media.upload(path, await prepareProductImage(photo()));

      final key = newIdempotencyKeyForTest();
      final draft = shirt(images: [path]);
      final (created, _) = await a.catalog.upsertProduct(
        a.storeId,
        productId,
        expectedVersion: null,
        draft: draft,
        idempotencyKey: key,
      );
      expect(created.variants.map((v) => v.label), ['S', 'M']);
      expect(created.images.single.path, path);

      // A retry with the same key is answered from the first result.
      final (replayed, _) = await a.catalog.upsertProduct(
        a.storeId,
        productId,
        expectedVersion: null,
        draft: draft,
        idempotencyKey: key,
      );
      expect(replayed.version, created.version);

      final read = await a.catalog.getProduct(a.storeId, productId);
      expect(read.basePrice, 25000);
      expect(read.variants[1].price, 27000);
      final (status, type) = await fetch(await signedUrl(a.media, path));
      expect((status, type), (200, 'image/jpeg'));

      final page = await a.catalog.listProducts(
        a.storeId,
        const CatalogQuery(text: 'linen'),
      );
      expect(page.items.single.priceMin, 25000);
      expect(page.items.single.priceMax, 27000);
      expect(page.items.single.imagePath, path);
      final summary = await a.catalog.summary(a.storeId);
      expect(summary.total, 1);
      expect(summary.categories.single.name, 'Clothing');
    });

    test('stock: add, stale preview, never negative, history', () async {
      final a = await newSeller('stock');
      final productId = newIdempotencyKeyForTest();
      final (p, _) = await a.catalog.upsertProduct(
        a.storeId,
        productId,
        expectedVersion: null,
        draft: shirt(),
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      final small = p.variants.first;
      final added = await a.catalog.adjustStock(
        a.storeId,
        small.id,
        mode: AdjustMode.add,
        quantity: 7,
        reason: StockReason.received,
        expectedStock: 5,
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      expect((added.previousStock, added.stockOnHand), (5, 12));
      await expectLater(
        a.catalog.adjustStock(
          a.storeId,
          small.id,
          mode: AdjustMode.remove,
          quantity: 1,
          reason: StockReason.soldInShop,
          expectedStock: 5,
          idempotencyKey: newIdempotencyKeyForTest(),
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiErrorCode.stockChanged)
              .having((e) => e.currentStock, 'current', 12),
        ),
      );
      await expectLater(
        a.catalog.adjustStock(
          a.storeId,
          small.id,
          mode: AdjustMode.remove,
          quantity: 13,
          reason: StockReason.soldInShop,
          idempotencyKey: newIdempotencyKeyForTest(),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.insufficientStock,
          ),
        ),
      );
      final (history, more) = await a.catalog.listMovements(
        a.storeId,
        productId,
      );
      expect(more, isFalse);
      expect(history.map((m) => m.reason), [
        StockReason.received,
        StockReason.initialStock,
      ]);
      expect(history.first.resultingQty, 12);
    });

    test(
      '20 parallel removals of 1 from a stock of 5: exactly 5 succeed',
      () async {
        final a = await newSeller('race');
        final productId = newIdempotencyKeyForTest();
        final (p, _) = await a.catalog.upsertProduct(
          a.storeId,
          productId,
          expectedVersion: null,
          draft: shirt(),
          idempotencyKey: newIdempotencyKeyForTest(),
        );
        final variant = p.variants.first;
        final outcomes = await Future.wait([
          for (var i = 0; i < 20; i++)
            a.catalog
                .adjustStock(
                  a.storeId,
                  variant.id,
                  mode: AdjustMode.remove,
                  quantity: 1,
                  reason: StockReason.soldInShop,
                  idempotencyKey: newIdempotencyKeyForTest(),
                )
                .then<Object>((r) => r)
                .catchError((Object e) => e),
        ]);
        expect(outcomes.whereType<StockAdjustment>(), hasLength(5));
        expect(outcomes.whereType<ApiException>().map((e) => e.code).toSet(), {
          ApiErrorCode.insufficientStock,
        });
        final after = await a.catalog.getProduct(a.storeId, productId);
        expect(after.variants.first.stockOnHand, 0);
        final (history, _) = await a.catalog.listMovements(
          a.storeId,
          productId,
        );
        expect(
          history.fold<int>(0, (sum, m) => sum + m.delta),
          0,
          reason: 'stock = sum of movements',
        );
        expect(
          history.where((m) => m.reason == StockReason.soldInShop),
          hasLength(5),
        );
      },
    );

    test(
      'removing an image returns its path; the object can then be deleted',
      () async {
        final a = await newSeller('img');
        final productId = newIdempotencyKeyForTest();
        final keep = productImagePath(a.storeId, productId);
        final drop = productImagePath(a.storeId, productId);
        final jpeg = await prepareProductImage(photo());
        await a.media.upload(keep, jpeg);
        await a.media.upload(drop, jpeg);
        final (p, _) = await a.catalog.upsertProduct(
          a.storeId,
          productId,
          expectedVersion: null,
          draft: shirt(images: [keep, drop]),
          idempotencyKey: newIdempotencyKeyForTest(),
        );
        // Still referenced: the server refuses to delete it.
        await a.media.remove([drop]);
        expect((await fetch(await signedUrl(a.media, drop))).$1, 200);

        final (_, removed) = await a.catalog.upsertProduct(
          a.storeId,
          productId,
          expectedVersion: p.version,
          draft: ProductDraft.fromProduct(p).copyWith(images: [keep]),
          idempotencyKey: newIdempotencyKeyForTest(),
        );
        expect(removed, [drop]);
        await a.media.remove(removed);
        await expectLater(
          SupabaseMediaStore(a.client).image(drop),
          throwsA(isA<StorageException>()),
        );
        expect((await fetch(await signedUrl(a.media, keep))).$1, 200);
      },
    );

    test(
      'tenant isolation: B cannot read, change, upload or delete A\'s catalog',
      () async {
        final a = await newSeller('iso-a');
        final b = await newSeller('iso-b');
        final productId = newIdempotencyKeyForTest();
        final path = productImagePath(a.storeId, productId);
        await a.media.upload(path, await prepareProductImage(photo()));
        final (p, _) = await a.catalog.upsertProduct(
          a.storeId,
          productId,
          expectedVersion: null,
          draft: shirt(images: [path]),
          idempotencyKey: newIdempotencyKeyForTest(),
        );

        Matcher notFound() => throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.notFound,
          ),
        );
        await expectLater(
          b.catalog.getProduct(a.storeId, productId),
          notFound(),
        );
        await expectLater(
          b.catalog.getProduct(b.storeId, productId),
          notFound(),
        );
        await expectLater(
          b.catalog.listProducts(a.storeId, const CatalogQuery()),
          notFound(),
        );
        expect(
          (await b.catalog.listProducts(
            b.storeId,
            const CatalogQuery(text: 'linen'),
          )).items,
          isEmpty,
        );
        await expectLater(
          b.catalog.adjustStock(
            b.storeId,
            p.variants.first.id,
            mode: AdjustMode.set,
            quantity: 0,
            reason: StockReason.damaged,
            idempotencyKey: newIdempotencyKeyForTest(),
          ),
          notFound(),
        );
        await expectLater(
          b.catalog.upsertProduct(
            a.storeId,
            productId,
            expectedVersion: p.version,
            draft: shirt(),
            idempotencyKey: newIdempotencyKeyForTest(),
          ),
          notFound(),
        );
        // Storage: no upload under A's prefix, no signed URL, no delete.
        await expectLater(
          b.media.upload(
            productImagePath(a.storeId, productId),
            await prepareProductImage(photo()),
          ),
          throwsA(
            isA<MediaException>().having(
              (e) => e.failure,
              'f',
              MediaFailure.refused,
            ),
          ),
        );
        await expectLater(
          b.media.image(path),
          throwsA(isA<StorageException>()),
        );
        await b.media.remove([path]);
        expect(
          (await fetch(await signedUrl(a.media, path))).$1,
          200,
          reason: 'A\'s image is still there',
        );
        final again = await a.catalog.getProduct(a.storeId, productId);
        expect(again.variants.first.stockOnHand, 5);
      },
    );
  });
}
