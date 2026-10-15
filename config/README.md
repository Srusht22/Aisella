# App build configuration

Values are passed with `--dart-define-from-file=config/<env>.json`.

* Only **public, non-secret** values belong here (Phase 3 `deployment-and-operations.md` §3).
  Privileged keys (service-role or `sb_secret_…`, AI, messaging) never go into the app — the app
  **refuses to start** if `SUPABASE_PUBLISHABLE_KEY` is a secret or service-role key.
* Commit only `*.example.json`; real files are git-ignored.

| Key | Phase | Meaning |
|---|---|---|
| `ENV_NAME` | 4 | `dev`, `staging` or `prod`. Non-prod builds show an environment pill. Defaults to `dev`. |
| `SAMPLE_DATA` | 4 | `true` adds clearly labelled sample data to screens whose features are not built yet (Today counts, Products, the draft-review preview). **Must be `false` in prod**; the app refuses to start with `ENV_NAME=prod` and `SAMPLE_DATA=true`. Defaults to `true` in dev and `false` elsewhere. Sign-in, store and settings are always real. |
| `SUPABASE_URL` | 5 | Supabase project URL. `https://` is required outside dev; `http://` is accepted only in dev for the local stack (`http://127.0.0.1:54321`; from the Android emulator use `http://10.0.2.2:54321`). Required. |
| `SUPABASE_PUBLISHABLE_KEY` | 5 | The project's **publishable** key (`sb_publishable_…`, or the legacy `anon` JWT). Public by design: every table is protected by RLS and every write by an authorizing database function. Required. |
| `SENTRY_DSN` | later | Public DSN (added with crash reporting). |

Phase 3 named the key `SUPABASE_ANON_KEY`; Phase 5 uses `SUPABASE_PUBLISHABLE_KEY` because the
Supabase SDK (supabase_flutter 2.18) renamed the parameter and accepts both key formats.

For the local stack, copy `dev.example.json` to `dev.json` (git-ignored) and paste the publishable
key from `supabase status`. See `docs/implementation/phase-5/` for the full setup.
