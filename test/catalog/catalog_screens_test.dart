import 'package:aisellia/app/router.dart';
import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/features/catalog/data/media_store.dart';
import 'package:aisellia/features/catalog/domain/catalog.dart';
import 'package:aisellia/features/catalog/presentation/product_detail_screen.dart';
import 'package:aisellia/features/catalog/presentation/product_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void _go(WidgetTester tester, String path) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(routerProvider)
        .go(path);

Future<void> _openProducts(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Products'),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpApp(
  WidgetTester tester,
  FakeCatalogRepository catalog, {
  FakeMediaStore? media,
  String? locale = 'en',
}) async {
  setScreen(tester);
  await tester.pumpWidget(
    testApp(catalog: catalog, media: media, sampleData: false, locale: locale),
  );
  await tester.pumpAndSettle();
}

/// The text field labelled [label] (AppTextField renders its label above).
Finder _field(String label) => find
    .descendant(
      of: find
          .ancestor(of: find.text(label), matching: find.byType(Column))
          .first,
      matching: find.byType(TextField),
    )
    .first;

/// Text equal to [text] once bidi isolates are removed.
Finder _t(String text) => find.byWidgetPredicate((w) {
  final data = w is Text ? (w.data ?? w.textSpan?.toPlainText()) : null;
  return data != null && data.replaceAll(RegExp('[\u2066-\u2069]'), '') == text;
});

Finder _chip(String label) => find.descendant(
  of: find.byType(ChoiceChip),
  matching: find.textContaining(label),
);

Future<void> _tapChip(WidgetTester tester, String label) async {
  await tester.ensureVisible(_chip(label));
  await tester.pumpAndSettle();
  await tester.tap(_chip(label));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String text) async {
  final f = _field(label);
  await tester.ensureVisible(f.first);
  await tester.enterText(f.first, text);
  await tester.pump();
}

Future<void> _tapFinder(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  group('Product list (PR-01)', () {
    testWidgets('an empty catalog explains itself and opens the editor', (
      tester,
    ) async {
      await _pumpApp(tester, FakeCatalogRepository());
      await _openProducts(tester);
      expect(find.text('Add your first product'), findsOneWidget);
      await tester.tap(find.text('Add product'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductEditorScreen), findsOneWidget);
      expect(find.text('New product'), findsOneWidget);
    });

    testWidgets('rows show price ranges and stock state in words', (
      tester,
    ) async {
      await _pumpApp(tester, FakeCatalogRepository(products: sampleCatalog()));
      await _openProducts(tester);
      expect(
        _t('5 products'),
        findsOneWidget,
        reason: 'All excludes nothing archived here',
      );
      expect(_t('12 in stock'), findsOneWidget);
      expect(_t('2 options low'), findsOneWidget);
      expect(find.text('Out of stock'), findsWidgets);
      expect(
        find.text('Available'),
        findsOneWidget,
        reason: 'untracked product',
      );
      expect(find.text('Inactive'), findsWidgets);
      expect(
        find.bySemanticsLabel(
          RegExp(r'^Linen Shirt, .*25,000.*3 options, 2 options low$'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('filters, debounced search and clearing', (tester) async {
      final catalog = FakeCatalogRepository(products: sampleCatalog());
      await _pumpApp(tester, catalog);
      await _openProducts(tester);

      await _tapChip(tester, 'Low stock');
      expect(find.text('Linen Shirt'), findsOneWidget);
      expect(find.text('Black Abaya'), findsNothing);

      await _tapChip(tester, 'Out of stock');
      expect(find.text('Leather Bag'), findsOneWidget);
      expect(find.text('Black Abaya'), findsNothing);

      await _tapChip(tester, 'All');
      final before = catalog.calls.length;
      await tester.enterText(find.byType(TextField), 'l');
      await tester.enterText(find.byType(TextField), 'li');
      await tester.enterText(find.byType(TextField), 'linen');
      await tester.pump(const Duration(milliseconds: 100));
      expect(catalog.calls.length, before, reason: 'no request while typing');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(
        catalog.calls.where((c) => c.startsWith('list:')).last,
        startsWith('list:linen|all'),
      );
      expect(find.text('Linen Shirt'), findsOneWidget);
      expect(find.text('Black Abaya'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(_t('No results for “zzz”'), findsOneWidget);
    });

    testWidgets('a load failure offers Retry', (tester) async {
      final catalog = FakeCatalogRepository(products: sampleCatalog())
        ..failNext = const ApiException(ApiErrorCode.network);
      setScreen(tester);
      await tester.pumpWidget(testApp(catalog: catalog, sampleData: false));
      await tester.pumpAndSettle();
      // The summary took the failure; reload the list explicitly.
      catalog.failNext = const ApiException(ApiErrorCode.network);
      await _openProducts(tester);
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Black Abaya'), findsOneWidget);
    });

    testWidgets('tablets show the list and the selected product side by side', (
      tester,
    ) async {
      setScreen(tester, size: const Size(1280, 800));
      await tester.pumpWidget(
        testApp(
          catalog: FakeCatalogRepository(products: sampleCatalog()),
          sampleData: false,
        ),
      );
      await tester.pumpAndSettle();
      _go(tester, Routes.products);
      await tester.pumpAndSettle();
      expect(find.text('Select a product to see its details'), findsOneWidget);
      await tester.tap(find.text('Linen Shirt'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductDetailScreen), findsOneWidget);
      expect(
        find.text('Black Abaya'),
        findsOneWidget,
        reason: 'the list stays visible',
      );
      expect(find.text('Adjust'), findsNWidgets(3));
    });
  });

  group('Product editor (PR-03/PR-04/PR-07)', () {
    testWidgets('invalid input is never sent; errors are on the fields', (
      tester,
    ) async {
      final catalog = FakeCatalogRepository();
      await _pumpApp(tester, catalog);
      _go(tester, Routes.productNew);
      await tester.pumpAndSettle();
      await _tapText(tester, 'Save');
      expect(find.text('2 fields need attention'), findsOneWidget);
      expect(find.text('Enter a product name'), findsOneWidget);
      expect(find.text('Enter a price'), findsOneWidget);
      await _enter(tester, 'Price (required)', '12.5');
      await _tapText(tester, 'Save');
      expect(find.text('Enter a whole number above 0'), findsOneWidget);
      expect(catalog.calls.where((c) => c.startsWith('upsert')), isEmpty);
    });

    testWidgets('create a product with initial stock, then land on its page', (
      tester,
    ) async {
      final catalog = FakeCatalogRepository();
      await _pumpApp(tester, catalog);
      _go(tester, Routes.productNew);
      await tester.pumpAndSettle();
      await _enter(tester, 'Name (required)', 'Beige Abaya');
      await _enter(tester, 'Price (required)', '٣٥٬٠٠٠');
      await _enter(tester, 'Quantity in stock', '5');
      await _tapText(tester, 'Clothing and fashion');
      await _tapText(tester, 'Save');
      expect(find.text('Product added'), findsOneWidget);
      expect(find.byType(ProductDetailScreen), findsOneWidget);
      expect(_t('5 in stock'), findsOneWidget);
      final saved = catalog.product(
        catalog.calls.firstWhere((c) => c.startsWith('upsert')).split(':')[1],
      )!;
      expect(saved.basePrice, 35000, reason: 'Eastern digits are normalised');
      expect(saved.category, 'Clothing and fashion');
    });

    testWidgets(
      'options generate combinations; Doesn\'t exist and Set for all',
      (tester) async {
        final catalog = FakeCatalogRepository();
        await _pumpApp(tester, catalog);
        _go(tester, Routes.productNew);
        await tester.pumpAndSettle();
        await _enter(tester, 'Name (required)', 'Linen Shirt');
        await _enter(tester, 'Price (required)', '25000');
        await _tapText(tester, 'This product has options');
        await _enter(tester, 'Option name, like Size', 'Size');
        for (final v in ['S', 'M', 'L']) {
          await _enter(tester, 'Add value', v);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
        }
        expect(_t('3 of 100 combinations'), findsOneWidget);
        await _tapText(tester, "Doesn't exist");
        expect(_t('2 of 100 combinations'), findsOneWidget);
        expect(find.text('Add back'), findsOneWidget);
        await _enter(tester, 'Stock for all', '4');
        await _tapText(tester, 'Apply');
        await _tapText(tester, 'Save');
        expect(find.text('Product added'), findsOneWidget);
        final id = catalog.calls
            .firstWhere((c) => c.startsWith('upsert'))
            .split(':')[1];
        final p = catalog.product(id)!;
        expect(p.optionTypes, ['Size']);
        expect(p.variants.map((v) => '${v.label}:${v.stockOnHand}'), [
          'S:4',
          'M:4',
        ]);
      },
    );

    testWidgets(
      'photos upload independently; a failed one does not block Save',
      (tester) async {
        final catalog = FakeCatalogRepository();
        final media = FakeMediaStore();
        await _pumpApp(tester, catalog, media: media);
        _go(tester, Routes.productNew);
        await tester.pumpAndSettle();
        await _enter(tester, 'Name (required)', 'Perfume');
        await _enter(tester, 'Price (required)', '15000');

        await _tapFinder(tester, find.bySemanticsLabel('Add photo').first);
        await tester.tap(find.text('Choose from gallery'));
        await tester.pumpAndSettle();
        expect(media.uploaded, hasLength(1));
        expect(find.text('Main photo'), findsOneWidget);

        media.failNextUpload = MediaFailure.network;
        await _tapFinder(tester, find.bySemanticsLabel('Add photo').first);
        await tester.tap(find.text('Take photo'));
        await tester.pumpAndSettle();
        expect(find.text('Not uploaded — Retry'), findsWidgets);
        expect(
          find.text("1 photo didn't upload and won't be saved."),
          findsOneWidget,
        );

        await _tapText(tester, 'Save');
        final id = catalog.calls
            .firstWhere((c) => c.startsWith('upsert'))
            .split(':')[1];
        expect(
          catalog.product(id)!.images.map((i) => i.path),
          media.uploaded.keys.toList(),
        );
        expect(
          media.uploaded.keys.single,
          startsWith('${testStore().id}/products/$id/'),
        );
      },
    );

    testWidgets(
      'a network failure keeps the input and the retry is the same request',
      (tester) async {
        final catalog = FakeCatalogRepository()
          ..failNext = const ApiException(ApiErrorCode.network);
        await _pumpApp(tester, catalog);
        // The summary consumed failNext; arm it for the save.
        catalog.failNext = null;
        _go(tester, Routes.productNew);
        await tester.pumpAndSettle();
        await _enter(tester, 'Name (required)', 'Abaya');
        await _enter(tester, 'Price (required)', '35000');
        catalog.failNext = const ApiException(ApiErrorCode.network);
        await _tapText(tester, 'Save');
        expect(
          find.text(
            "Couldn't reach Aisellia. Check your connection and try again.",
          ),
          findsOneWidget,
        );
        expect(find.text('Abaya'), findsOneWidget, reason: 'input preserved');
        await _tapText(tester, 'Save');
        expect(find.text('Product added'), findsOneWidget);
        expect(
          catalog.calls.where((c) => c.startsWith('upsert')).toSet(),
          hasLength(1),
          reason: 'both attempts were the same product',
        );
      },
    );

    testWidgets('server field errors appear on the field', (tester) async {
      final catalog = FakeCatalogRepository();
      await _pumpApp(tester, catalog);
      _go(tester, Routes.productNew);
      await tester.pumpAndSettle();
      await _enter(tester, 'Name (required)', 'Abaya');
      await _enter(tester, 'Price (required)', '35000');
      catalog.failNext = const ApiException(
        ApiErrorCode.validationFailed,
        fields: {'base_price': 'out_of_range'},
      );
      await _tapText(tester, 'Save');
      expect(find.text('1 field needs attention'), findsOneWidget);
      expect(find.text('Enter a whole number above 0'), findsOneWidget);
    });

    testWidgets('leaving with unsaved edits asks first', (tester) async {
      await _pumpApp(tester, FakeCatalogRepository(products: sampleCatalog()));
      _go(tester, Routes.product('p-abaya'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit product'), findsOneWidget);
      expect(
        find.text(
          'To change stock, use Adjust on the product page. Every change is recorded.',
        ),
        findsOneWidget,
      );
      await _enter(tester, 'Name (required)', 'Black Abaya XL');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Edit product'), findsOneWidget);
    });
  });

  group('Stock (PR-02/PR-05/PR-06)', () {
    Future<void> openAbaya(
      WidgetTester tester,
      FakeCatalogRepository catalog,
    ) async {
      await _pumpApp(tester, catalog);
      _go(tester, Routes.product('p-abaya'));
      await tester.pumpAndSettle();
    }

    testWidgets('adjust: preview, confirmed result, history', (tester) async {
      final catalog = FakeCatalogRepository(products: sampleCatalog());
      await openAbaya(tester, catalog);
      expect(_t('12 in stock'), findsOneWidget);
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();
      await _enter(tester, 'Quantity', '3');
      expect(_t('15'), findsOneWidget, reason: 'result preview');
      await _tapText(tester, 'Received stock');
      await _tapText(tester, 'Save adjustment');
      expect(_t('Stock updated · 12 → 15'), findsOneWidget);
      expect(_t('15 in stock'), findsOneWidget);
      expect(catalog.calls, contains('adjust:p-abaya-v0:add:3:received'));

      // Let the snackbar leave; it covers the bottom rows.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await _tapText(tester, 'Inventory history');
      expect(find.text('Received stock'), findsOneWidget);
      expect(_t('Stock 15'), findsOneWidget);
    });

    testWidgets('stock never goes negative and a reason is required', (
      tester,
    ) async {
      final catalog = FakeCatalogRepository(products: sampleCatalog());
      await openAbaya(tester, catalog);
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await _enter(tester, 'Quantity', '13');
      expect(_t('Only 12 in stock'), findsOneWidget);
      await _enter(tester, 'Quantity', '2');
      await _tapText(tester, 'Save adjustment');
      expect(find.text('Choose a reason'), findsOneWidget);
      expect(catalog.calls.where((c) => c.startsWith('adjust')), isEmpty);
    });

    testWidgets('a change made elsewhere is shown, not overwritten', (
      tester,
    ) async {
      final catalog = FakeCatalogRepository(products: sampleCatalog());
      await openAbaya(tester, catalog);
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();
      await _enter(tester, 'Quantity', '1');
      await _tapText(tester, 'Sold in shop');
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      catalog.setStockElsewhere('p-abaya', 10);
      await _tapText(tester, 'Save adjustment');
      expect(_t('Stock changed to 10 while you were editing'), findsOneWidget);
      expect(_t('9'), findsOneWidget, reason: 'preview recalculated from 10');
      await _tapText(tester, 'Save adjustment');
      expect(_t('Stock updated · 10 → 9'), findsOneWidget);
    });

    testWidgets('archive asks first and the product says it is archived', (
      tester,
    ) async {
      final catalog = FakeCatalogRepository(products: sampleCatalog());
      await openAbaya(tester, catalog);
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Its stock history is kept'), findsOneWidget);
      await tester.tap(find.text('Archive').last);
      await tester.pumpAndSettle();
      expect(find.text('Product archived'), findsOneWidget);
      expect(
        find.text('Archived — restore it to sell it again.'),
        findsOneWidget,
      );
      expect(catalog.product('p-abaya')!.status, ProductStatus.archived);
    });

    testWidgets('untracked products show availability, not counts', (
      tester,
    ) async {
      await _pumpApp(tester, FakeCatalogRepository(products: sampleCatalog()));
      _go(tester, Routes.product('p-oud'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Stock isn't counted"), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      expect(find.text('Adjust'), findsNothing);
    });

    testWidgets('a product of another store is simply not available', (
      tester,
    ) async {
      await _pumpApp(tester, FakeCatalogRepository());
      _go(tester, Routes.product('someone-elses'));
      await tester.pumpAndSettle();
      expect(find.text("This product isn't available"), findsOneWidget);
    });
  });

  group('Today and the setup checklist', () {
    testWidgets(
      'the first product completes the checklist item; low stock is real',
      (tester) async {
        await _pumpApp(
          tester,
          FakeCatalogRepository(products: sampleCatalog()),
        );
        expect(_t('3 of 5 done'), findsOneWidget);
        expect(find.text('Low or out of stock'), findsOneWidget);
        await tester.tap(find.text('Low or out of stock'));
        await tester.pumpAndSettle();
        expect(
          find.text('Linen Shirt'),
          findsOneWidget,
          reason: 'opened on the Low stock filter',
        );
        expect(find.text('Black Abaya'), findsNothing);
      },
    );
  });

  group('Store inventory setting', () {
    testWidgets('the low-stock default is saved to the store', (tester) async {
      final backend = FakeStoreRepository(store: testStore());
      setScreen(tester);
      await tester.pumpWidget(
        testApp(
          catalog: FakeCatalogRepository(products: sampleCatalog()),
          storeBackend: backend,
          sampleData: false,
        ),
      );
      await tester.pumpAndSettle();
      _go(tester, Routes.storeInventory);
      await tester.pumpAndSettle();
      await _enter(tester, 'Low-stock alert at', 'x');
      await _tapText(tester, 'Save');
      expect(find.text('Enter a whole number, 0 or more'), findsOneWidget);
      await _enter(tester, 'Low-stock alert at', '٥');
      await _tapText(tester, 'Save');
      expect(backend.calls.last, 'updateStore:{low_stock_default: 5}');
      expect(find.text('Saved'), findsOneWidget);
    });
  });

  group('Sorani', () {
    testWidgets('the list is RTL; prices stay LTR isolates', (tester) async {
      await _pumpApp(
        tester,
        FakeCatalogRepository(products: sampleCatalog()),
        locale: 'ckb',
      );
      _go(tester, Routes.products);
      await tester.pumpAndSettle();
      expect(
        Directionality.of(tester.element(find.text('بۆنی عود'))),
        TextDirection.rtl,
      );
      expect(find.textContaining('\u2066'), findsWidgets);
    });
  });
}
