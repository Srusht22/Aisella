import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_config.dart';
import '../core/settings/app_settings.dart';
import '../design_system/gallery/gallery_screen.dart';
import '../features/common/deferred_feature_screen.dart';
import '../features/common/not_found_screen.dart';
import '../features/inbox/inbox_screen.dart';
import '../features/onboarding/language_selection_screen.dart';
import '../features/orders/presentation/draft_review_preview_screen.dart';
import '../features/orders/presentation/orders_home_screen.dart';
import '../features/products/presentation/products_screen.dart';
import '../features/settings/language_display_screen.dart';
import '../features/settings/store_menu_screen.dart';
import '../features/today/presentation/today_screen.dart';
import 'shell.dart';

/// Route paths (Phase 3 Flutter architecture §5).
abstract final class Routes {
  static const language = '/language';
  static const today = '/today';
  static const inbox = '/inbox';
  static const orders = '/orders';
  static const draftPreview = '/orders/preview-draft';
  static const products = '/products';
  static const store = '/store';
  static const storeLanguage = '/store/language';
  static const storeGallery = '/store/gallery';
  static String later(DeferredFeature f) => '/later/${f.name}';
}

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Rebuilds redirects when the language choice changes.
class _SettingsListenable extends ChangeNotifier {
  void ping() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _SettingsListenable();
  ref.listen(settingsProvider, (_, _) => refresh.ping());
  ref.onDispose(refresh.dispose);
  final isProduction = ref.read(appConfigProvider).isProduction;

  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: Routes.today,
    refreshListenable: refresh,
    redirect: (context, state) {
      final chosen = ref.read(settingsProvider).languageChosen;
      final atLanguage = state.matchedLocation == Routes.language;
      if (!chosen && !atLanguage) return Routes.language;
      if (chosen && atLanguage) return Routes.today;
      return null;
    },
    errorBuilder: (context, state) => const NotFoundScreen(),
    routes: [
      GoRoute(path: '/', redirect: (_, _) => Routes.today),
      GoRoute(
        path: Routes.language,
        builder: (_, _) => const LanguageSelectionScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.today,
                builder: (_, _) => const TodayScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.inbox,
                builder: (_, _) => const InboxScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.orders,
                builder: (_, _) => const OrdersHomeScreen(),
                routes: [
                  GoRoute(
                    path: 'preview-draft',
                    builder: (_, _) => const DraftReviewPreviewScreen(),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.products,
                builder: (_, _) => const ProductsScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: Routes.store,
        parentNavigatorKey: _rootKey,
        builder: (_, _) => const StoreMenuScreen(),
        routes: [
          GoRoute(
            path: 'language',
            builder: (_, _) => const LanguageDisplayScreen(),
          ),
          // Debug gallery: not registered in production, so a deep link
          // cannot reach it either.
          if (!isProduction)
            GoRoute(path: 'gallery', builder: (_, _) => const GalleryScreen()),
        ],
      ),
      GoRoute(
        path: '/later/:feature',
        parentNavigatorKey: _rootKey,
        builder: (_, state) {
          final feature = DeferredFeature.values
              .where((f) => f.name == state.pathParameters['feature'])
              .firstOrNull;
          return feature == null
              ? const NotFoundScreen()
              : DeferredFeatureScreen(feature: feature);
        },
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
