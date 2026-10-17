# D. Staging readiness

## 1. Status: hosted validation is blocked

| Need | Available here? |
|---|---|
| A hosted Supabase staging project (project ref, database password) | **No:** `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD` and `STAGING_DB_URL` are not set, and no project is linked |
| Authorization to deploy | **No:** Phase 8.5 excludes deployment |
| An Anthropic key | **No** ([A](a-key-configuration.md)) |
| The Supabase edge runtime booting the function | **Not verified:** in this sandbox the edge-runtime container cannot download npm packages through the TLS-intercepting proxy (Phase 8 F §4) |

**Nothing hosted was validated.** The checks below ran only against the local stack.

## 2. Function secrets and configuration

| Name | Kind | Required | Notes |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | Secret | Yes | Staging workspace key ([A §2](a-key-configuration.md#2-how-to-configure-a-key-securely)) |
| `AISELLIA_AI_WORKER_DB_URL` | Secret | Yes | `postgresql://aisellia_ai_worker.<ref>:<password>@<pooler-host>:6543/postgres?sslmode=require` (transaction pooler). The password is set by an operator with `alter role aisellia_ai_worker password …`, never in a migration. |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | Platform | Yes | Provided by Supabase to functions |
| `AI_MODEL` | Setting | No | Default `claude-opus-5-5` |
| `AI_EFFORT` | Setting | No | Default `low` |
| `AI_INFERENCE_GEO` | Setting | No | **New:** `global` or `us`; unset uses the workspace default |
| `AI_MAX_TOKENS`, `AI_TIMEOUT_MS`, `AI_BUDGET_MS` | Settings | No | 8,000 / 30 s / 45 s |
| `AI_ALLOWED_ORIGINS` | Setting | No | Browser origins only; the mobile app sends none |

`supabase/config.toml` sets `[functions.ai-assist] verify_jwt = true`, so the platform refuses calls without a session before the code runs.

## 3. Preflight script (new): `supabase/functions/ai-assist/ops/staging_check.ts`

This is a **read-only** check, run by an operator with the same values as the function's secrets. It prints only check names, pass / fail / skip and short codes, **never a secret or connection string** (tested).

```bash
cd supabase/functions/ai-assist
set -a; . ~/.config/aisellia/staging.env; set +a     # outside the repository
deno run --allow-net --allow-env ops/staging_check.ts --check-provider --check-endpoint
```

| Check | Passes when |
|---|---|
| `config.valid` | The function's configuration parses (the same code as the function) |
| `secret.anthropic_api_key` | Present and shaped like an Anthropic key |
| `secret.worker_db_url` | The user is `aisellia_ai_worker` (or the pooler form `aisellia_ai_worker.<ref>`) and has a password |
| `worker_db.tls` | A remote URL uses `sslmode=require` or `verify-full` |
| `worker_db.login` | The login works and `current_user` is the worker role |
| `worker_db.no_attributes` | No superuser, create-role, create-database, bypass-RLS, inherit or replication attribute |
| `worker_db.functions` | Exactly the 4 worker functions are executable |
| `worker_db.no_tables` | No table or view is readable or writable |
| `migrations.phase_8_5` | The Phase 8.5 functions exist |
| `worker_db.call` | `api.ai_run_state` answers |
| `provider.key_and_model` (`--check-provider`) | A free model lookup accepts the key and knows the configured model. No tokens are used. |
| `endpoint.requires_session` (`--check-endpoint`) | The deployed function answers 401 without a session |

**Verified locally** (Deno test, `AISELLIA_E2E=1`): every database check passes against the local worker role with a temporary password, and the output does not contain it. **Not verified:** a hosted pooler login, TLS, the provider check against the real API, and a deployed endpoint.

## 4. Staging checklist (for when deployment is authorized)

1. Create a **separate** Supabase project for staging. Choose its region (see [C §2](c-provider-data-and-cost.md#2-proposed-ad-08-data-terms-and-geography-owner-decision)). Use no production data.
2. `supabase link --project-ref <staging-ref>`, then `supabase db push`. This applies all migrations, including both Phase 8.5 migrations.
3. Generate a strong password and set it: `alter role aisellia_ai_worker password '<generated>';`. Run this in the SQL editor, not from a file in the repository.
4. Set the function secrets from a file outside the repository ([A §2](a-key-configuration.md#2-how-to-configure-a-key-securely)).
5. `supabase functions deploy ai-assist`.
6. Run the preflight with `--check-provider --check-endpoint`. Every check must pass.
7. Repeat the end-to-end journey with a **test seller account and sandbox conversations only**:
   - suggestion;
   - draft;
   - seller approval;
   - AI switch off;
   - the budget brake (temporarily lower `assist_daily_cost_micro_usd_per_store`).
8. Look at the function logs: they should contain no message text, prompt or key.
9. Set the Console spend limit before step 7.

Steps 1–8 were **not performed**. They need staging credentials and the owner's authorization to deploy.
