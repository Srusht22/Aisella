# H. Setup and configuration

## 1. Prerequisites

| Tool | Version used | Notes |
|---|---|---|
| Flutter / Dart | 3.47.7 / 3.13.5 (stable) | As in Phase 4 |
| Docker | Any recent engine | The local Supabase stack runs in containers |
| Supabase CLI | 2.121 (`npx supabase` or a package-manager install) | Reads `supabase/config.toml` |
| `psql` | 16 (used here) | Only for the database tests |

Local stack images (pulled by `supabase start`): Postgres 17, GoTrue v2.197, PostgREST v16, Kong 2.8 and Mailpit. Studio, storage, realtime, edge functions and analytics are **disabled** in `config.toml` because Phase 5 does not use them.

## 2. Local backend

```sh
supabase start             # first run pulls the images; applies supabase/migrations
supabase status -o env     # prints API_URL, PUBLISHABLE_KEY, DB_URL, MAILPIT_URL, ...
supabase db reset          # re-creates the local database from the migrations (seed.sql is empty)
```

- The API runs at `http://127.0.0.1:54321` and Postgres at `127.0.0.1:54322` (`postgres`/`postgres`, local only). Mailpit, which catches the verification and reset emails, is at the `MAILPIT_URL` printed by `supabase status`.
- `seed.sql` contains **no** accounts or data. Create a seller by signing up in the app and opening the link from Mailpit.
- **Never** put the service-role or secret key from `supabase status` into app config. The app refuses to start with one.

## 3. App configuration

Copy `config/dev.example.json` to `config/dev.json` (git-ignored) and fill in:

```json
{
  "ENV_NAME": "dev",
  "SAMPLE_DATA": "false",
  "SUPABASE_URL": "http://127.0.0.1:54321",
  "SUPABASE_PUBLISHABLE_KEY": "<PUBLISHABLE_KEY from supabase status>"
}
```

- Use `http://10.0.2.2:54321` from the Android emulator, or the machine's LAN IP from a physical device.
- `http://` is allowed **only** when `ENV_NAME=dev`; staging and prod require `https://`.
- Run with `flutter run --dart-define-from-file=config/dev.json`.
- Key reference: [config/README.md](../../../config/README.md).

**Email links.** The verification and reset emails link to `app.aisellia://auth/callback` and `app.aisellia://auth/reset`. The Android intent filter and the iOS `CFBundleURLSchemes` entry route them to the app, and the Supabase client exchanges the PKCE code. On a desktop browser the link cannot open the app; open it on the device or emulator (for example `adb shell am start -d '<link>'`). The scheme is **provisional** until AD-10 fixes the app identifier.

## 4. Hosted project checklist (not done; needs authorization)

No hosted Supabase project was created or changed in Phase 5 ("do not deploy new production infrastructure without authorization"). When one is authorized, it needs **the same settings as `config.toml`**. Supabase does not sync dashboard settings from `config.toml` automatically unless `supabase config push` is used deliberately.

1. **Region and plan** per Phase 3 deployment and cost docs; separate `staging` and `prod` projects.
2. **Migrations:** `supabase link --project-ref <ref>` then `supabase db push`. Check that `pg_cron` is enabled and that the job `aisellia-purge-account-deletions` exists (`select * from cron.job`).
3. **API:** exposed schemas `api` only; extra search path `extensions`; turn off "automatically expose new tables".
4. **Auth:**
   - email provider on, confirmations on;
   - minimum password length 8;
   - secure password change on;
   - refresh-token rotation on (reuse interval 10 s);
   - JWT expiry 3600 s;
   - resend frequency 60 s;
   - leave the hosted defaults for the rate limits; **do not** copy the local `email_sent = 30`.
5. **Redirect URLs:** Site URL `app.aisellia://auth/callback`; additional redirect URLs `app.aisellia://auth/callback` and `app.aisellia://auth/reset`. Update all of them when AD-10 fixes the identifier.
6. **SMTP:** a production sender with a verified domain (SPF, DKIM, DMARC). The built-in Supabase mailer is rate-limited and for testing only. Localize the confirm-signup and reset-password templates (Sorani and English).
7. **Keys:** put only the **publishable** key and URL in the app's `staging.json` and `prod.json` (CI secrets, never committed). The secret key stays server-side and is not needed by anything in Phase 5.
8. **Verify** with a manual run on a device against **staging**: sign up, open the verification email, create the store, sign out, reset the password, sign in. The automated backend tests read emails from Mailpit, so they target the local stack only. Pointing them at staging would need a test inbox, which is not built.

## 5. Running the checks

```sh
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
dart run tool/gen_tokens.dart --check
dart run tool/check_imports.dart
dart run tool/check_directional.dart
flutter test                                          # unit, widget, golden
bash supabase/tests/run_db_tests.sh                   # pgTAP; refuses non-local database URLs
eval "$(supabase status -o env)"
SUPABASE_TEST_URL=$API_URL SUPABASE_TEST_PUBLISHABLE_KEY=$PUBLISHABLE_KEY \
  MAILPIT_TEST_URL=$MAILPIT_URL flutter test --tags backend
```

`run_db_tests.sh` connects to `postgresql://postgres:postgres@127.0.0.1:54322/postgres` by default (override with `SUPABASE_DB_URL`), refuses any URL that is not `127.0.0.1` or `localhost`, and runs each file in a transaction that is rolled back.
