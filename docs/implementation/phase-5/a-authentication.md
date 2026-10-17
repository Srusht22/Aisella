# A. Authentication

## 1. Provider and configuration

| Item | Choice | Source |
|---|---|---|
| Identity provider | **Supabase Auth (GoTrue)**, email and password | Phase 3 ADR-002 and ADR-013 |
| Client SDK | `supabase_flutter` 2.18.3, **PKCE** flow | Phase 3 Flutter architecture |
| Token storage | `flutter_secure_storage` 11.2.0: iOS Keychain (`first_unlock_this_device`) and Android Keystore-backed storage | ADR-013; see [B §2](b-auth-state-and-routing.md#2-session-storage) |
| Client key | Publishable key only. The app **refuses to start** with a `sb_secret_…` key or a JWT whose role is `service_role` (`AppConfig.isPrivilegedKey`). | Phase 3 deployment §3 |
| Password hashing and verification | Done by the provider (bcrypt in GoTrue). The app never stores or hashes passwords. | Brief: no homemade password storage |
| Email verification and reset | The provider's email links, opened in the app through the deep link `app.aisellia://auth/…` and exchanged with the PKCE code verifier | Brief: no custom verification mechanism |

Provider settings, from `supabase/config.toml` (the hosted project must match them; see [H §4](h-setup-and-configuration.md#4-hosted-project-checklist-not-done-needs-authorization)):

| Setting | Value | Why |
|---|---|---|
| `enable_signup` | `true` | Sellers register themselves (US-001) |
| `enable_confirmations` | `true` | D-07: the email address must be verified |
| `minimum_password_length` | `8` | Journey A; the app checks the same rule for fast feedback |
| `secure_password_change` | `true` | Changing a password needs a recent sign-in |
| `jwt_expiry` | `3600` s | Access-token lifetime (default) |
| `enable_refresh_token_rotation` | `true`, reuse interval 10 s | A stolen refresh token stops working after one use |
| `max_frequency` (email) | `60s` | AU-05 and AU-06 resend cooldown |
| `site_url` / `additional_redirect_urls` | `app.aisellia://auth/callback`, `app.aisellia://auth/reset` | Only the app may receive links (provisional scheme until AD-10) |
| Rate limits | `sign_in_sign_ups` 30 per 5 min per IP, `token_verifications` 30, `token_refresh` 150; `email_sent` 30 per hour locally | Defaults, except `email_sent`, which is raised **locally only** for the integration tests |
| Unused providers | Phone, anonymous, OAuth, MFA and web3 are all off | Not in P0 |

## 2. Flows

All flows run against the real provider. The widget tests use a fake repository behind the same interface. The backend tests use the real one ([G](g-test-results.md)).

| Flow | Screens (Phase 2) | Behaviour | Verified |
|---|---|---|---|
| **Sign up** | Welcome AU-01 → Sign up AU-03 → Verify email AU-06 | Email, password (8+ characters, counted as code points) and acceptance of the Terms. The terms version (`2026-10`) is sent as user metadata and recorded on `app.profiles` by the sign-up trigger. An existing address gets "This email already has an account", with a link to sign in; no second account is created and the original password still works. | widget + backend |
| **Verify email** | AU-06 | Shows the address, a resend button with a 60 s cooldown and "Open sign in". The link opens the app and signs the seller in (PKCE exchange). | widget + backend (link fetched from Mailpit) |
| **Sign in** | AU-02 | A wrong password and an unknown account give **the same** message (US-002). An unverified account gets "Verify your email first", with resend. Offline gives "No connection"; HTTP 429 gives "Too many attempts". | widget + backend |
| **Forgot password** | AU-05 | Always answers "If an account exists, we sent a link", so it does not reveal whether the account exists. 60 s cooldown. | widget + backend |
| **Set a new password** | AU-05b (recovery) | The reset link opens the app in a restricted **recovery** state: the router allows only `/new-password`. Saving the password ends the recovery state, and the seller continues signed in. | widget + backend (real link and PKCE code) |
| **Change password** (signed in) | ST-07 Account | Sends a reset link to the account's email (the provider requires a recent sign-in for an in-session change, `secure_password_change`). | widget |
| **Sign out** | Store menu | Revokes the refresh token on the server, deletes the keystore entry, rebuilds all user-scoped state empty, and goes to Welcome. | widget + backend (revocation) |
| **Sign out of all devices** | ST-07 Account | Same, with scope `global`: every refresh token of the user is revoked. | widget |
| **Session restore** | Starting | See [B §3](b-auth-state-and-routing.md#3-session-restore). | widget |
| **Re-authentication** | ST-08 Delete account | Password re-entry triggers a fresh sign-in, which renews the session's `amr` password timestamp that the database checks. | widget + backend |
| **Account deletion** | ST-08 | See [D §6](d-ownership-and-authorization.md#6-account-deletion). | widget + backend + pgTAP |

**Error handling.** Provider error codes are mapped in one place (`mapAuthErrorCode`) to the failures the UI distinguishes: invalid credentials, email not confirmed, email in use, weak password, invalid email, same password, rate limited, network, link invalid or expired, and unknown. Raw provider messages are never shown. Exceptions and logs carry no tokens, passwords or emails: SDK debug logging is off, and startup failures log only the exception type.

## 3. Decision P5-D1: verification before first sign-in

Phase 2 AU-06 shows **"Continue setup"** on the Verify email screen, so a seller could build the store before clicking the link. With `enable_confirmations = true`, Supabase Auth issues **no session** until the address is verified, and it offers no supported "allow unverified sign-in" option. Faking the step locally would break the brief's rules: no local booleans as auth, and no verification that bypasses the provider.

**Adaptation (implemented):** AU-06 waits for the link. It shows the address, Resend (60 s), and "Open sign in" for a seller who verified on another device. Once the link is opened, the seller lands directly on store setup.

**Owner decision needed.** Accept P5-D1, or choose one of these alternatives:
- (a) turn confirmations off and enforce verification at a later gate, such as before connecting messaging; this needs an `email_verified` check in the database;
- (b) use an OTP code typed in the app instead of a link. The provider supports this; it would be a change to the Phase 2 design.

## 4. Behaviour that differs from the specs, and why

| Spec | Implemented | Reason |
|---|---|---|
| AU-06 "Continue setup" before verification | Wait for the link | P5-D1 above |
| Phase 3 config key `SUPABASE_ANON_KEY` | `SUPABASE_PUBLISHABLE_KEY` | SDK 2.18 renamed the parameter; both key formats are accepted ([config/README.md](../../../config/README.md)) |
| Change password in-session (ST-07) | Reset link by email | `secure_password_change` needs a recent sign-in. A link is simpler and avoids a second password form. |
| Deletion confirmation email (US-004) | Not sent | Needs the production SMTP sender ([I §6](i-phase-5-completion-report.md#6-known-issues-and-risks)) |
