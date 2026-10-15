# App build configuration

Values are passed with `--dart-define-from-file=config/<env>.json`.

* Only **public, non-secret** values belong here (Phase 3 `deployment-and-operations.md` §3).
  Privileged keys (service-role, AI, messaging) never go into the app.
* Commit only `*.example.json`; real files are git-ignored.

| Key | Phase | Meaning |
|---|---|---|
| `ENV_NAME` | 4 | `dev`, `staging` or `prod`. Non-prod builds show an environment ribbon. Defaults to `dev`. |
| `SAMPLE_DATA` | 4 | `true` enables clearly labelled sample data for design review. **Must be `false` in prod**; the app refuses to start with `ENV_NAME=prod` and `SAMPLE_DATA=true`. Defaults to `true` in dev and `false` elsewhere. |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | 5 | Public client values (added when the backend is connected). |
| `SENTRY_DSN` | 5+ | Public DSN (added with crash reporting). |
