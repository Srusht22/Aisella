import 'dart:typed_data';

import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/features/catalog/data/media_store.dart';
import 'package:aisellia/features/catalog/domain/catalog.dart';
import 'package:aisellia/features/catalog/domain/product_draft.dart';
import 'package:aisellia/features/store/domain/store_validation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Map<String, dynamic> productJson({bool track = true}) => {
  'id': 'p1',
  'store_id': 's1',
  'name': 'Linen Shirt',
  'description': null,
  'category': 'Clothing',
  'base_price': 25000,
  'track_stock': track,
  'option_types': ['Size'],
  'status': 'active',
  'version': 3,
  'low_stock_default': 3,
  'variants': [
    {
      'id': 'v1',
      'option_values': ['S'],
      'label': 'S',
      'sku': 'SH-S',
      'price_override': null,
      'price': 25000,
      'stock_on_hand': 0,
      'available': true,
      'low_stock_threshold': null,
      'status': 'active',
      'has_history': true,
    },
    {
      'id': 'v2',
      'option_values': ['M'],
      'label': 'M',
      'sku': null,
      'price_override': 27000,
      'price': 27000,
      'stock_on_hand': 2,
      'available': true,
      'low_stock_threshold': 1,
      'status': 'active',
      'has_history': false,
    },
    {
      'id': 'v3',
      'option_values': ['L'],
      'label': 'L',
      'price': 25000,
      'stock_on_hand': 9,
      'status': 'archived',
      'has_history': true,
    },
  ],
  'images': [
    {'id': 'i1', 'path': 's1/products/p1/a.jpg', 'position': 0},
  ],
};

void main() {
  group('Server contract parsing', () {
    test('a product with variants and images', () {
      final p = Product.fromJson(productJson());
      expect(p.name, 'Linen Shirt');
      expect(p.optionTypes, ['Size']);
      expect(p.variants, hasLength(3));
      expect(p.activeVariants.map((v) => v.label), ['S', 'M']);
      expect(p.variants[1].priceOverride, 27000);
      expect(p.images.single.path, 's1/products/p1/a.jpg');
      expect(p.defaultVariant, isNull, reason: 'it has options');
    });

    test('stock state per variant follows the thresholds (BR-18)', () {
      final p = Product.fromJson(productJson());
      expect(p.statusOf(p.variants[0]), StockStatus.out);
      // Own threshold 1 overrides the store default 3: 2 is not low.
      expect(p.statusOf(p.variants[1]), StockStatus.inStock);
      final untracked = Product.fromJson(productJson(track: false));
      expect(untracked.statusOf(untracked.variants[0]), StockStatus.available);
    });

    test('a list page and the summary', () {
      final page = CatalogPage.fromJson({
        'items': [
          {
            'id': 'p1',
            'name': 'A',
            'status': 'inactive',
            'track_stock': true,
            'price_min': 1000,
            'price_max': 2000,
            'variant_count': 2,
            'stock_total': 3,
            'low_count': 1,
            'out_count': 0,
            'stock_state': 'low',
            'image_path': null,
            'version': 2,
          },
        ],
        'total': 31,
        'has_more': true,
      });
      expect(page.items.single.status, ProductStatus.inactive);
      expect(page.items.single.stockStatus, StockStatus.low);
      expect(page.hasMore, isTrue);
      final summary = CatalogSummary.fromJson({
        'total': 5,
        'all': 4,
        'low': 1,
        'out': 2,
        'inactive': 1,
        'archived': 1,
        'categories': [
          {'name': 'Perfumes', 'count': 2},
        ],
        'low_stock_default': 3,
      });
      expect(summary.attention, 3);
      expect(summary.categories.single.name, 'Perfumes');
    });

    test('movements', () {
      final m = InventoryMovement.fromJson({
        'id': 7,
        'variant_id': 'v1',
        'variant_label': 'S',
        'delta': -2,
        'resulting_qty': 3,
        'reason': 'sold_in_shop',
        'note': null,
        'created_at': '2026-10-17T08:00:00Z',
        'actor': 'you',
      });
      expect(m.reason, StockReason.soldInShop);
      expect(m.actor, MovementActor.you);
      expect(StockReason.parse('order_approved'), StockReason.orderApproved);
    });

    test('stock errors carry the current stock', () {
      try {
        unwrapEnvelope({
          'ok': false,
          'error': {
            'code': 'STOCK_CHANGED',
            'details': {'current_stock': 10},
          },
        });
        fail('expected an exception');
      } on ApiException catch (e) {
        expect(e.code, ApiErrorCode.stockChanged);
        expect(e.currentStock, 10);
      }
      expect(
        () => unwrapEnvelope({
          'ok': false,
          'error': {
            'code': 'VARIANT_IN_USE',
            'details': {
              'variant_ids': ['v1'],
            },
          },
        }),
        throwsA(
          isA<ApiException>().having((e) => e.details['variant_ids'], 'ids', [
            'v1',
          ]),
        ),
      );
    });
  });

  group('Numbers typed by sellers', () {
    test('Western, Eastern Arabic and Persian digits with grouping', () {
      expect(parseWholeNumber('35,000', min: 1, max: maxPrice).$1, 35000);
      expect(parseWholeNumber('٣٥٬٠٠٠', min: 1, max: maxPrice).$1, 35000);
      expect(parseWholeNumber('۱۲', min: 0, max: maxStock).$1, 12);
    });
    test('decimals, negatives, zero prices and empty input are refused', () {
      expect(
        parseWholeNumber('12.5', min: 1, max: maxPrice).$2,
        FieldIssue.invalid,
      );
      expect(
        parseWholeNumber('-3', min: 0, max: maxStock).$2,
        FieldIssue.invalid,
      );
      expect(
        parseWholeNumber('0', min: 1, max: maxPrice).$2,
        FieldIssue.invalid,
      );
      expect(
        parseWholeNumber(' ', min: 1, max: maxPrice).$2,
        FieldIssue.required,
      );
      expect(parseWholeNumber('', min: 0, max: 9, required: false), (
        null,
        null,
      ));
    });
  });

  group('Variants (PR-04)', () {
    const size = OptionType(name: 'Size', values: ['S', 'M']);
    const colour = OptionType(name: 'Colour', values: ['Black', 'Beige']);

    test('every combination of the option values', () {
      final v = combineVariants([size, colour], const []);
      expect(v.map((x) => x.label), [
        'S · Black',
        'S · Beige',
        'M · Black',
        'M · Beige',
      ]);
    });

    test('existing variants keep their id, SKU and price; removed ones are skipped', () {
      final current = [
        const VariantDraft(
          id: 'v1',
          optionValues: ['s'],
          sku: 'X',
          priceOverride: 9,
        ),
      ];
      final v = combineVariants(
        [size],
        current,
        removed: {
          const VariantDraft(optionValues: ['M']).comboKey,
        },
      );
      expect(v.single.id, 'v1');
      expect(v.single.sku, 'X');
      expect(v.single.optionValues, ['S']);
    });

    test(
      'a variant with history is archived, not dropped, when its value goes',
      () {
        final current = [
          const VariantDraft(id: 'v1', optionValues: ['L'], hasHistory: true),
          const VariantDraft(optionValues: ['XL']),
        ];
        final v = combineVariants([size], current);
        expect(v.map((x) => '${x.label}:${x.archived}'), [
          'S:false',
          'M:false',
          'L:true',
        ]);
      },
    );

    test('turning options off leaves one default variant', () {
      final v = combineVariants(const [], [
        const VariantDraft(id: 'v1', optionValues: ['S'], hasHistory: true),
      ]);
      expect(v.first.optionValues, isEmpty);
      expect(v.first.archived, isFalse);
      expect(v[1].archived, isTrue);
    });
  });

  group('Product draft', () {
    test('validation keys match the server', () {
      final issues = validateProductDraft(
        const ProductDraft(
          name: ' ',
          basePrice: 0,
          optionTypes: [
            OptionType(name: 'Size', values: ['S']),
            OptionType(name: 'size'),
          ],
          variants: [
            VariantDraft(optionValues: ['S'], sku: 'a'),
            VariantDraft(optionValues: ['M'], sku: 'A '),
          ],
        ),
      );
      expect(issues, {
        'name': FieldIssue.required,
        'base_price': FieldIssue.invalid,
        'option_types.1': FieldIssue.duplicate,
        'option_values.1': FieldIssue.required,
        'variants.1.sku': FieldIssue.duplicate,
      });
    });

    test('initial stock is sent only for new variants of tracked products', () {
      const draft = ProductDraft(
        name: 'Abaya',
        basePrice: 35000,
        variants: [
          VariantDraft(
            id: 'v1',
            optionValues: [],
            initialStock: 4,
            stockOnHand: 2,
          ),
        ],
      );
      final json = draft.toJson();
      expect(
        (json['variants']! as List).single,
        isNot(contains('initial_stock')),
      );
      const fresh = ProductDraft(
        name: 'Abaya',
        basePrice: 35000,
        variants: [VariantDraft(optionValues: [], initialStock: 4)],
      );
      expect(
        ((fresh.toJson()['variants']! as List).single as Map)['initial_stock'],
        4,
      );
      expect(
        (fresh.copyWith(trackStock: false).toJson()['variants']! as List)
            .single,
        isNot(contains('initial_stock')),
      );
      expect(fresh.copyWith(active: false).toJson()['status'], 'inactive');
    });

    test('the adjustment preview', () {
      expect(adjustmentResult(AdjustMode.add, 12, 3), 15);
      expect(adjustmentResult(AdjustMode.remove, 12, 13), -1);
      expect(adjustmentResult(AdjustMode.set, 12, 4), 4);
      expect(adjustmentResult(AdjustMode.set, 12, null), isNull);
    });
  });

  group('Photos before upload (BR-71)', () {
    Uint8List photoWithLocation({int w = 2400, int h = 1800}) {
      final image = img.Image(width: w, height: h);
      img.fill(image, color: img.ColorRgb8(200, 120, 40));
      image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(36, 1);
      image.exif.imageIfd['Make'] = img.IfdValueAscii('PhoneCo');
      return img.encodeJpg(image);
    }

    test('the source really carries location data', () {
      final decoded = img.decodeJpg(photoWithLocation())!;
      expect(decoded.exif.gpsIfd.isEmpty, isFalse);
    });

    test('square, at most 1600 px, JPEG, without any metadata', () {
      final out = prepareProductImageSync(photoWithLocation())!;
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, productImageEdge);
      expect(decoded.height, productImageEdge);
      expect(decoded.exif.isEmpty, isTrue);
      expect(out.lengthInBytes, lessThanOrEqualTo(maxUploadBytes));
    });

    test('small photos are cropped but not enlarged', () {
      final out = prepareProductImageSync(photoWithLocation(w: 300, h: 500))!;
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (300, 300));
    });

    test('PNG input becomes JPEG; non-images are refused', () {
      final png = img.encodePng(img.Image(width: 10, height: 20));
      final out = prepareProductImageSync(png)!;
      expect(img.findFormatForData(out), img.ImageFormat.jpg);
      expect(prepareProductImageSync(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });

    test('files over 10 MB are refused before decoding', () async {
      await expectLater(
        prepareProductImage(Uint8List(maxSourceImageBytes + 1)),
        throwsA(
          isA<MediaException>().having(
            (e) => e.failure,
            'failure',
            MediaFailure.tooLarge,
          ),
        ),
      );
    });

    test('storage paths are scoped to the store and product', () {
      final path = productImagePath('store-1', 'prod-1');
      expect(
        path,
        matches(RegExp(r'^store-1/products/prod-1/[0-9a-f-]{36}\.jpg$')),
      );
    });
  });
}
