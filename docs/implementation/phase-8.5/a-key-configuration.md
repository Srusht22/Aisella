# A. Anthropic API key: availability and secure configuration

## 1. What was checked (2026-10-17)

| Check | Result |
|---|---|
| Environment variables `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_API_KEY`, `AISELLIA_ANTHROPIC_API_KEY` | **Not set** |
| Key files (`~/.anthropic`, `~/.config/anthropic`) | None |
| `api.anthropic.com` reachable from this environment | Yes: HTTP 401 without a key |
| Evaluation script without a key | Exits with code 2: "Not run: set AISELLIA_EVAL=1 and ANTHROPIC_API_KEY …". Nothing is sent. |

Only the *presence* of the variables was tested; no value was printed.

**Consequence:** the 24-scenario real-model evaluation was **not run**. No result in these documents is a measurement of the model's answers.

## 2. How to configure a key securely

**Use a key that serves only this evaluation and staging.** Create it in the Claude Console, in a workspace that holds nothing else. Do not use a personal or production key.

1. **Workspace and limits, in the Console:**
   - create a workspace, for example `aisellia-staging`;
   - set its **spend limit** (proposal: USD 50 per month; see [C §4](c-provider-data-and-cost.md#4-spending-limits));
   - if the owner decides on US-only processing (AD-08), set the workspace's allowed inference regions;
   - create an API key in that workspace.
2. **For the local evaluation**, give the key to the process only:
   - in the shell, without writing it to a file in the repository:
     ```bash
     read -rs ANTHROPIC_API_KEY && export ANTHROPIC_API_KEY   # typed or pasted, not echoed
     ```
   - or in a file **outside** the repository, readable only by you (`chmod 600 ~/.config/aisellia/eval.env`), loaded with `set -a; . ~/.config/aisellia/eval.env; set +a`.
   - **Never** put it in `.env` files inside the repository, in `supabase/config.toml`, in Flutter code or `--dart-define`, in a commit, in an issue, or in a chat message.
3. **For a staging Edge Function:**
   ```bash
   # staging.env lives outside the repository (chmod 600) and holds ANTHROPIC_API_KEY=… and AISELLIA_AI_WORKER_DB_URL=…
   supabase secrets set --env-file ~/.config/aisellia/staging.env --project-ref <staging-ref>
   ```
   Or use the dashboard's function secrets. Avoid `supabase secrets set NAME=value` on the command line, because it leaves the value in the shell history. The Flutter app never needs the key: it calls the function with the seller's session.
4. **Rotation:** revoke the key in the Console when the evaluation or staging is finished, or if it may have been exposed.

**What the code already guarantees:**
- the key is read only on the server (`config.ts`);
- the base URL is pinned to `https://api.anthropic.com`, so an ambient `ANTHROPIC_BASE_URL` cannot redirect customer data;
- provider errors are stored as codes, without the API's messages (tested);
- the logs carry event names, ids and token counts only.

## 3. Running the evaluation once a key is configured

From `supabase/functions/ai-assist`, on the **local** stack (the script refuses any other database):

```bash
# 1. See what would run, and the spending cap. Nothing is called.
deno run --allow-net --allow-env --allow-read --allow-write=./eval/out eval/run_eval.ts --plan

# 2. Run it (about USD 0.5–1 for the 24 scenarios; it stops at the cap).
AISELLIA_EVAL=1 SUPABASE_TEST_URL=http://127.0.0.1:54321 \
SUPABASE_TEST_PUBLISHABLE_KEY=… SUPABASE_TEST_JWT_SECRET=… \
deno run --allow-net --allow-env --allow-read --allow-write=./eval/out eval/run_eval.ts --max-cost-usd=3
```

**Optional settings:**
- `AI_MODEL=claude-sonnet-5-5` to compare model tiers (AD-07);
- `AI_INFERENCE_GEO=us` for US-only processing (billed at 1.1×);
- `--set=/path/outside/repo/consented.json` for consented conversations ([F](f-consented-samples.md)).

**The report** (`eval/out/eval-*.json`, ignored by git) and the console print, **separately for en, ckb and ar**:

| Measure | Meaning |
|---|---|
| Pass / ran / scenarios | Deterministic checks per scenario |
| Grounded | Scenarios that expect store facts (price, availability, delivery) and got them from the server, with no flag |
| Fabrication caught / shown | Replies where the model wrote a price, promise, discount, claim or unverified number. **Caught** means only the holding reply was offered; **shown** must be 0. |
| Escalation caught / missed / false alarms | Against each scenario's expectation |
| Approved / advanced past review | Must be 0 |
| Latency p50 / p95 / max | Whole request, including the database |
| Cost | Estimated by the database from `ai_model_prices` |

**The script does not judge language quality.** A Sorani or Arabic reply can pass every check and still read badly. The `reply` field of each result must be read by a native speaker before anyone claims the languages are validated.

**Size of the set:** 18 English, 3 Sorani and 3 Arabic scenarios. Phase 8 G said 17 / 4 / 3; the file says otherwise, and G is now corrected. This is far too small to estimate the Phase 1 §14.3 gates per language.
