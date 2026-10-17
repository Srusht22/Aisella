import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/domain/auth_status.dart';
import '../features/store/domain/store.dart';

/// Route paths (Phase 3 Flutter architecture §5).
abstract final class Routes {
  static const language = '/language';
  static const starting = '/starting';
  static const unavailable = '/unavailable';
  static const accountClosed = '/account-closed';

  // Public (signed out).
  static const welcome = '/welcome';
  static const signIn = '/sign-in';
  static const signUp = '/sign-up';
  static const verifyEmail = '/verify-email';
  static const forgotPassword = '/forgot-password';
  static const terms = '/terms';

  // Recovery session only.
  static const newPassword = '/new-password';

  // Store setup (AU-07..09).
  static const setupStore = '/setup/store';
  static const setupZones = '/setup/zones';
  static const setupPayments = '/setup/payments';

  // Workspace.
  static const today = '/today';
  static const inbox = '/inbox';
  static const orders = '/orders';
  static const orderNew = '/orders/new';
  static String order(String id) => '/orders/$id';
  static String orderEdit(String id) => '/orders/$id/edit';
  static String orderHistory(String id) => '/orders/$id/history';
  static const products = '/products';
  static const productNew = '/products/new';
  static String product(String id) => '/products/$id';
  static String productEdit(String id) => '/products/$id/edit';
  static String productHistory(String id) => '/products/$id/history';
  static const store = '/store';
  static const storeProfile = '/store/profile';
  static const storeZones = '/store/zones';
  static const storePayments = '/store/payments';
  static const storeInventory = '/store/inventory';
  static const storeAccount = '/store/account';
  static const storeDeleteAccount = '/store/account/delete';
  static const storeLanguage = '/store/language';
  static const storeGallery = '/store/gallery';
  static const storeLegal = '/store/terms';
  static String later(String feature) => '/later/$feature';
}

const publicRoutes = {
  Routes.welcome,
  Routes.signIn,
  Routes.signUp,
  Routes.verifyEmail,
  Routes.forgotPassword,
  Routes.terms,
};

const _setupRoutes = {
  Routes.setupStore,
  Routes.setupZones,
  Routes.setupPayments,
};

/// Routes that exist only to get a seller into the workspace; a seller who
/// is already there is sent to Today instead.
const _entryRoutes = {
  ...publicRoutes,
  ..._setupRoutes,
  Routes.language,
  Routes.starting,
  Routes.unavailable,
  Routes.accountClosed,
  Routes.newPassword,
};

/// Where a signed-in seller stands, derived from the server context.
sealed class WorkspaceGate {
  const WorkspaceGate();
}

class GateLoading extends WorkspaceGate {
  const GateLoading();
}

class GateUnavailable extends WorkspaceGate {
  const GateUnavailable();
}

class GateNoStore extends WorkspaceGate {
  const GateNoStore();
}

class GateOnboarding extends WorkspaceGate {
  const GateOnboarding(this.step);
  final OnboardingStep step;
}

class GateReady extends WorkspaceGate {
  const GateReady();
}

class GateDeletionPending extends WorkspaceGate {
  const GateDeletionPending();
}

/// Derives the gate for [userId] from the workspace provider's value. Data
/// that belongs to a different user (kept by the provider while it reloads
/// after a sign-in) is never used: that state counts as loading.
WorkspaceGate workspaceGateFor(
  AsyncValue<AccountContext?> workspace,
  String userId,
) {
  final ctx = workspace.value;
  if (ctx != null && ctx.userId == userId) {
    if (ctx.deletionPending) return const GateDeletionPending();
    final store = ctx.store;
    if (store == null) return const GateNoStore();
    if (store.onboardingStep != OnboardingStep.done) {
      return GateOnboarding(store.onboardingStep);
    }
    return const GateReady();
  }
  if (workspace.hasError && !workspace.isLoading) {
    return const GateUnavailable();
  }
  return const GateLoading();
}

/// Inputs of the navigation decision.
@immutable
class RouteGate {
  const RouteGate({
    required this.languageChosen,
    required this.auth,
    this.workspace = const GateLoading(),
  });

  final bool languageChosen;
  final AuthStatus auth;

  /// Meaningful only when [auth] is [SignedIn].
  final WorkspaceGate workspace;
}

/// The single navigation guard (Phase 5 §5). Returns the location to
/// redirect to, or null when [path] may be shown in this state.
///
/// Every state has one home route, and that home is always allowed in the
/// same state, so redirects cannot loop.
String? guardRedirect(String path, RouteGate gate) =>
    isAllowed(path, gate) ? null : homeFor(gate);

String homeFor(RouteGate gate) {
  if (!gate.languageChosen) return Routes.language;
  return switch (gate.auth) {
    AuthInitializing() => Routes.starting,
    PasswordRecovery() => Routes.newPassword,
    SignedOut(reason: SignedOutReason.sessionExpired) => Routes.signIn,
    SignedOut() => Routes.welcome,
    SignedIn() => switch (gate.workspace) {
      GateLoading() => Routes.starting,
      GateUnavailable() => Routes.unavailable,
      GateDeletionPending() => Routes.accountClosed,
      GateNoStore() => Routes.setupStore,
      GateOnboarding(step: OnboardingStep.payments) => Routes.setupPayments,
      GateOnboarding() => Routes.setupZones,
      GateReady() => Routes.today,
    },
  };
}

bool isAllowed(String path, RouteGate gate) {
  if (!gate.languageChosen) return path == Routes.language;
  return switch (gate.auth) {
    AuthInitializing() => path == Routes.starting,
    PasswordRecovery() => path == Routes.newPassword,
    SignedOut() => publicRoutes.contains(path),
    SignedIn() => switch (gate.workspace) {
      GateLoading() => path == Routes.starting,
      GateUnavailable() => path == Routes.unavailable,
      GateDeletionPending() => path == Routes.accountClosed,
      GateNoStore() => path == Routes.setupStore,
      GateOnboarding(step: OnboardingStep.payments) =>
        path == Routes.setupZones || path == Routes.setupPayments,
      GateOnboarding() => path == Routes.setupZones,
      GateReady() => !_entryRoutes.contains(path),
    },
  };
}
