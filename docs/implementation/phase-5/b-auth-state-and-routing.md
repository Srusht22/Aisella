# B. Auth state, session lifecycle and protected navigation

## 1. Layers

```
Screens ──call──▶ AuthController (Notifier<AuthStatus>) ──▶ AuthRepository ──▶ supabase_flutter (GoTrue)
   ▲                     │                                                          │
   │                     ▼                                                          ▼
 GoRouter ◀── guardRedirect(path, RouteGate) ◀── WorkspaceController ──▶ StoreRepository ──▶ PostgREST `api`
```

- `lib/features/auth/`: `domain` (`AuthStatus`, `AuthFailure`, credential rules), `data` (`SupabaseAuthRepository`, error mapping), `application` (`AuthController`), `presentation` (screens).
- `lib/app/route_guard.dart` is a **pure** function of the route gate. It is tested exhaustively, with no widgets involved.
- `tool/check_imports.dart` enforces the layer boundaries, including a new rule: `application` may not import `presentation`.

## 2. Session storage

- The session (access token, refresh token, expiry) is persisted only through the SDK's `LocalStorage` hook, implemented by `SecureSessionStorage` over `flutter_secure_storage`. That is the Keychain on iOS (`first_unlock_this_device`: not readable while the device is locked, not migrated by backups) and Keystore-backed encrypted storage on Android. The PKCE code verifier for email links uses the same storage (`SecurePkceStorage`).
- Nothing auth-related goes to `shared_preferences`. That store holds only device UI preferences (language, theme, motion) and an install marker.
- **Reinstall on iOS:** the Keychain survives app deletion. On the first launch after an install (no install marker in preferences), `clearSessionLeftFromPreviousInstall` deletes any session or PKCE entries, so a reinstalled app never restores a previous seller.
- **No token in logs:** SDK `debug: false`; the app logs only exception types. `AuthUser` (id, email, verified) is the only identity the UI sees; tokens never leave the SDK.

## 3. Session restore

1. `bootstrap.dart` initializes Supabase with the secure storage before `runApp`. If initialization fails, the app shows a startup-error screen and nothing else.
2. `AuthController` starts in `AuthInitializing`. The router allows only `/starting` in that state, so protected content cannot appear before the session is known.
3. The SDK reads the stored session and refreshes it if it has expired. It then emits `initialSession`, which becomes `SignedIn(user)` or `SignedOut(none)`.
4. If signed in, `WorkspaceController` loads `api.get_my_context()` for **that user id** and the router sends the seller to the right place (§5). Data still cached for a different user counts as loading and is never shown.
5. If the stored refresh token was revoked or expired, the refresh fails, the SDK emits `signedOut`, and the state becomes `SignedOut(sessionExpired)`. The router shows **Sign in** with the message "Your session ended. Please sign in again."

## 4. Application auth state

`AuthStatus` is a sealed type: `AuthInitializing`, `SignedOut(reason)`, `SignedIn(user)` and `PasswordRecovery(user)`. `AuthController` is the **only** place it changes, and only from provider events or the controller's own methods. No screen holds a "logged in" flag.

| Event | New state |
|---|---|
| `initialSession` | `SignedIn` or `SignedOut(none)` |
| `signedIn` (sign-in, email link) | `SignedIn` |
| `passwordRecovery` (reset link) | `PasswordRecovery`: restricted until `updatePassword` succeeds |
| `tokenRefreshed`, `userUpdated` | Fresh user data; a recovery session stays restricted |
| `signedOut` after the seller's Sign out | `SignedOut(signedOut)` → Welcome |
| `signedOut` without a request (refresh failed or revoked) | `SignedOut(sessionExpired)` → Sign in, with an explanation |
| API answers 401 (`PGRST301`/`PGRST303`, or `UNAUTHENTICATED`) on a workspace call | `sessionRejected()` clears the local session, keeping the reason `sessionExpired` |

**Revocation.**
- *Sign out:* `signOut(scope: local)` revokes this device's refresh token on the server; *sign out everywhere* uses `scope: global`. The backend test shows that a revoked refresh token cannot be used.
- *Offline sign-out:* if the server cannot be reached, the local session is still deleted. That refresh token then expires on the server by itself.
- *Residual window:* an access JWT is a bearer token valid until it expires (up to 1 h, `jwt_expiry`). After a sign-out, a copy of it taken from the device before the sign-out still works until then. This is inherent to stateless JWTs and is documented in [I §6](i-phase-5-completion-report.md#6-known-issues-and-risks).

**User-scoped state.** `workspaceProvider` and `zonesProvider` depend on the current user id. On sign-out or a user switch they rebuild empty, so no store data survives into the next session. Riverpod 3's automatic retry is turned off for them (`noAutomaticRetry`), so failures are shown and not retried silently.

## 5. Protected navigation

`guardRedirect(path, gate)` returns `null` (stay) or the **home** of the current state. It is the router's only redirect and re-runs whenever settings, auth or workspace state changes.

| State | Home | Allowed paths |
|---|---|---|
| Language not chosen | `/language` | that one only |
| `AuthInitializing`, or signed in with the workspace loading | `/starting` | that one only |
| `PasswordRecovery` | `/new-password` | that one only |
| `SignedOut(sessionExpired)` | `/sign-in` | public routes |
| `SignedOut` (other reasons) | `/welcome` | public routes: welcome, sign-in, sign-up, verify-email, forgot-password, terms |
| Signed in, context failed to load | `/unavailable` (Retry, Sign out) | that one only |
| Signed in, account deletion pending | `/account-closed` (Sign out) | that one only |
| Signed in, no store | `/setup/store` | that one only |
| Onboarding at `zones` | `/setup/zones` | that one only |
| Onboarding at `payments` | `/setup/payments` | zones and payments (Back works) |
| Workspace ready | `/today` | everything except the entry routes (public, setup, language, starting, unavailable, account-closed, new-password) |

**Rules:**
- **No loops:** every state's home is allowed in that same state. `route_guard_test.dart` checks this for every combination of state and route, and separate tests check that a signed-out seller is refused every non-public route and that a ready seller cannot reopen sign-in or setup.
- **Deep links** to protected paths are redirected exactly like taps. Auth links (`app.aisellia://auth/…`) are handled by the SDK and never reach the router (`flutter_deeplinking_enabled=false`, `FlutterDeepLinkingEnabled=false`).
- **Back stack:** a redirect *replaces* the location, so Back after sign-out cannot return to a protected screen. A widget test signs out from the Store menu, presses system Back and finds no protected screen.
- The design gallery route exists only in non-production builds (unchanged from Phase 4).
