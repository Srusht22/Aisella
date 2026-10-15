import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_config.dart';
import '../core/settings/app_settings.dart';
import '../design_system/gallery/gallery_screen.dart';
import '../features/auth/application/auth_controller.dart';
import '../features/auth/domain/auth_status.dart';
import '../features/auth/presentation/email_link_screens.dart';
import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/sign_up_screen.dart';
import '../features/auth/presentation/terms_screen.dart';
import '../features/auth/presentation/welcome_screen.dart';
import '../features/common/deferred_feature_screen.dart';
import '../features/common/not_found_screen.dart';
import '../features/inbox/inbox_screen.dart';
import '../features/onboarding/language_selection_screen.dart';
import '../features/onboarding/presentation/setup_screens.dart';
import '../features/orders/presentation/draft_review_preview_screen.dart';
import '../features/orders/presentation/orders_home_screen.dart';
import '../features/products/presentation/products_screen.dart';
import '../features/settings/language_display_screen.dart';
import '../features/settings/store_menu_screen.dart';
import '../features/settings/store_settings_screens.dart';
import '../features/store/application/workspace_controller.dart';
import '../features/today/presentation/today_screen.dart';
import 'gate_screens.dart';
import 'route_guard.dart';
import 'shell.dart';

export 'route_guard.dart' show Routes;

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Re-runs the redirect when any input of the navigation decision changes.
class _GateListenable extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// The navigation inputs, read fresh on every redirect.
RouteGate readGate(Ref ref) {
  final auth = ref.read(authControllerProvider);
  return RouteGate(
    languageChosen: ref.read(settingsProvider).languageChosen,
    auth: auth,
    workspace: auth is SignedIn
        ? workspaceGateFor(ref.read(workspaceProvider), auth.user.id)
        : const GateLoading(),
  );
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _GateListenable();
  ref.listen(settingsProvider, (_, _) => refresh.ping());
  ref.listen(authControllerProvider, (_, _) => refresh.ping());
  ref.listen(workspaceProvider, (_, _) => refresh.ping());
  ref.onDispose(refresh.dispose);
  final isProduction = ref.read(appConfigProvider).isProduction;

  String? email(GoRouterState s) => s.uri.queryParameters['email'];

  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: Routes.starting,
    refreshListenable: refresh,
    redirect: (context, state) => guardRedirect(state.uri.path, readGate(ref)),
    errorBuilder: (context, state) => const NotFoundScreen(),
    routes: [
      GoRoute(path: '/', redirect: (_, _) => Routes.today),
      GoRoute(
        path: Routes.language,
        builder: (_, _) => const LanguageSelectionScreen(),
      ),
      GoRoute(path: Routes.starting, builder: (_, _) => const StartingScreen()),
      GoRoute(
        path: Routes.unavailable,
        builder: (_, _) => const WorkspaceUnavailableScreen(),
      ),
      GoRoute(
        path: Routes.accountClosed,
        builder: (_, _) => const AccountClosedScreen(),
      ),
      // Public (signed out).
      GoRoute(path: Routes.welcome, builder: (_, _) => const WelcomeScreen()),
      GoRoute(
        path: Routes.signIn,
        builder: (_, s) => SignInScreen(initialEmail: email(s)),
      ),
      GoRoute(path: Routes.signUp, builder: (_, _) => const SignUpScreen()),
      GoRoute(
        path: Routes.verifyEmail,
        builder: (_, s) => VerifyEmailScreen(email: email(s) ?? ''),
      ),
      GoRoute(
        path: Routes.forgotPassword,
        builder: (_, s) => ForgotPasswordScreen(initialEmail: email(s)),
      ),
      GoRoute(path: Routes.terms, builder: (_, _) => const TermsScreen()),
      // Recovery session.
      GoRoute(
        path: Routes.newPassword,
        builder: (_, _) => const NewPasswordScreen(),
      ),
      // Store setup.
      GoRoute(
        path: Routes.setupStore,
        builder: (_, _) => const SetupStoreScreen(),
      ),
      GoRoute(
        path: Routes.setupZones,
        builder: (_, _) => const SetupZonesScreen(),
      ),
      GoRoute(
        path: Routes.setupPayments,
        builder: (_, _) => const SetupPaymentsScreen(),
      ),
      // Workspace.
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
            path: 'profile',
            builder: (_, _) => const StoreProfileScreen(),
          ),
          GoRoute(
            path: 'zones',
            builder: (_, _) => const DeliveryZonesScreen(),
          ),
          GoRoute(path: 'payments', builder: (_, _) => const PaymentsScreen()),
          GoRoute(
            path: 'account',
            builder: (_, _) => const AccountScreen(),
            routes: [
              GoRoute(
                path: 'delete',
                builder: (_, _) => const DeleteAccountScreen(),
              ),
            ],
          ),
          GoRoute(path: 'terms', builder: (_, _) => const TermsScreen()),
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
