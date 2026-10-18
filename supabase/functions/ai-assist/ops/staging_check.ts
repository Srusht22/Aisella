// Read-only preflight of a hosted (staging) environment for the ai-assist function. It checks the
// function's configuration, the worker role's privileges and the migrations it needs, and
// optionally that the provider key is accepted (a free model lookup, no tokens) and that the
// deployed endpoint refuses calls without a session. It never prints a secret or a connection
// string: only check names, pass / fail / skip and short codes.
//
//   SUPABASE_URL=... SUPABASE_ANON_KEY=... AISELLIA_AI_WORKER_DB_URL=... GEMINI_API_KEY=... \
//   deno run --allow-net --allow-env ops/staging_check.ts [--check-provider] [--check-endpoint]
//
// Run it from a trusted operator machine with the same values as the function's secrets.
import Anthropic from "@anthropic-ai/sdk";
import postgres from "postgres";
import { ConfigError, readConfig } from "../config.ts";

export interface Check {
  check: string;
  status: "pass" | "fail" | "skip";
  detail?: string;
}

const WORKER_FUNCTIONS = ["ai_claim_run", "ai_complete_run", "ai_fail_run", "ai_run_state"];
const REQUIRED_APP_FUNCTIONS = ["reply_number_check", "redact_contact_text", "reply_guard", "ai_record_meta"];

function isLocal(host: string): boolean {
  return host === "127.0.0.1" || host === "localhost" || host === "::1";
}

export async function runChecks(
  env: (k: string) => string | undefined,
  options: { checkProvider?: boolean; checkEndpoint?: boolean; fetchFn?: typeof fetch } = {},
): Promise<Check[]> {
  const out: Check[] = [];
  const add = (check: string, status: Check["status"], detail?: string) =>
    out.push(detail === undefined ? { check, status } : { check, status, detail });

  let config;
  try {
    config = readConfig(env);
    add("config.valid", "pass");
  } catch (e) {
    add("config.valid", "fail", e instanceof ConfigError ? e.message : "unreadable");
  }

  // The key of the configured provider (AI_PROVIDER, gemini by default). Only its shape is checked.
  const anthropic = (env("AI_PROVIDER") ?? "").trim() === "anthropic";
  const key = env(anthropic ? "ANTHROPIC_API_KEY" : "GEMINI_API_KEY")?.trim() ?? "";
  const shapeOk = anthropic ? key.startsWith("sk-ant-") : /^[A-Za-z0-9_-]{30,60}$/.test(key);
  add(
    anthropic ? "secret.anthropic_api_key" : "secret.gemini_api_key",
    key !== "" && shapeOk ? "pass" : "fail",
    key === "" ? "missing" : shapeOk ? undefined : "unexpected format",
  );

  const dbUrl = env("AISELLIA_AI_WORKER_DB_URL")?.trim() ?? "";
  let parsed: URL | null = null;
  try {
    parsed = dbUrl ? new URL(dbUrl) : null;
  } catch {
    parsed = null;
  }
  if (!parsed) {
    add("secret.worker_db_url", "fail", dbUrl ? "not a URL" : "missing");
  } else {
    const user = decodeURIComponent(parsed.username);
    // The hosted pooler names the role "aisellia_ai_worker.<project-ref>".
    const userOk = user === "aisellia_ai_worker" || user.startsWith("aisellia_ai_worker.");
    add(
      "secret.worker_db_url",
      userOk && parsed.password !== "" ? "pass" : "fail",
      !userOk ? "not the aisellia_ai_worker role" : parsed.password === "" ? "no password" : undefined,
    );
    const local = isLocal(parsed.hostname);
    const ssl = parsed.searchParams.get("sslmode");
    add(
      "worker_db.tls",
      local ? "skip" : ssl === "require" || ssl === "verify-full" ? "pass" : "fail",
      local ? "local database" : ssl ? undefined : "add sslmode=require",
    );
  }

  if (parsed && config) {
    const sql = postgres(dbUrl, {
      max: 1,
      prepare: false,
      connect_timeout: 10,
      idle_timeout: 1,
      onnotice: () => {},
    });
    try {
      const [me] =
        await sql`select current_user as role, r.rolsuper, r.rolcreaterole, r.rolcreatedb, r.rolbypassrls,
                                    r.rolinherit, r.rolreplication
                               from pg_roles r where r.rolname = current_user`;
      add(
        "worker_db.login",
        me.role === "aisellia_ai_worker" ? "pass" : "fail",
        me.role === "aisellia_ai_worker" ? undefined : "wrong role",
      );
      const attrs = [
        "rolsuper",
        "rolcreaterole",
        "rolcreatedb",
        "rolbypassrls",
        "rolinherit",
        "rolreplication",
      ]
        .filter((a) => me[a] === true);
      add(
        "worker_db.no_attributes",
        attrs.length === 0 ? "pass" : "fail",
        attrs.length ? attrs.join(",") : undefined,
      );
      const fns = await sql`select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                             where n.nspname not in ('pg_catalog', 'information_schema', 'extensions')
                               and has_schema_privilege(n.oid, 'usage') and has_function_privilege(p.oid, 'execute')
                             order by 1`;
      const names = fns.map((f) => f.proname as string);
      const apiOk = WORKER_FUNCTIONS.every((f) => names.includes(f)) &&
        names.length === WORKER_FUNCTIONS.length;
      add("worker_db.functions", apiOk ? "pass" : "fail", apiOk ? undefined : `executable: ${names.length}`);
      const [tables] =
        await sql`select count(*)::int as n from pg_class c join pg_namespace n on n.oid = c.relnamespace
                                  where c.relkind in ('r', 'v', 'm', 'p', 'f')
                                    and n.nspname not in ('pg_catalog', 'information_schema')
                                    and has_schema_privilege(n.oid, 'usage')
                                    and (has_table_privilege(c.oid, 'select') or has_table_privilege(c.oid, 'insert')
                                         or has_table_privilege(c.oid, 'update') or has_table_privilege(c.oid, 'delete'))`;
      add(
        "worker_db.no_tables",
        tables.n === 0 ? "pass" : "fail",
        tables.n === 0 ? undefined : `reachable: ${tables.n}`,
      );
      const present = await sql`select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                 where n.nspname = 'app' and p.proname = any (${REQUIRED_APP_FUNCTIONS})`;
      const missing = REQUIRED_APP_FUNCTIONS.filter((f) => !present.some((p) => p.proname === f));
      add(
        "migrations.phase_8_5",
        missing.length === 0 ? "pass" : "fail",
        missing.length ? `missing ${missing.join(",")}` : undefined,
      );
      const [state] = await sql`select api.ai_run_state(gen_random_uuid()) as r`;
      add("worker_db.call", state.r?.ok === false ? "pass" : "fail", state.r?.error?.code);
    } catch (e) {
      add("worker_db.connect", "fail", (e as { code?: string }).code ?? "connection failed");
    } finally {
      await sql.end({ timeout: 2 }).catch(() => {});
    }
  } else {
    add("worker_db.connect", "skip", "configuration incomplete");
  }

  if (options.checkProvider && key && config) {
    try {
      if (anthropic) {
        const client = new Anthropic({ apiKey: key, baseURL: "https://api.anthropic.com", maxRetries: 0 });
        const model = await client.models.retrieve(config.model);
        add("provider.key_and_model", model.id ? "pass" : "fail");
      } else {
        // Model lookup: free, no tokens. The key goes in a header, never in the URL.
        const res = await (options.fetchFn ?? fetch)(
          `https://generativelanguage.googleapis.com/v1beta/models/${config.model}`,
          { headers: { "x-goog-api-key": key } },
        );
        await res.body?.cancel();
        add("provider.key_and_model", res.ok ? "pass" : "fail", res.ok ? undefined : `http_${res.status}`);
      }
    } catch (e) {
      const status = (e as { status?: number }).status;
      add("provider.key_and_model", "fail", status ? `http_${status}` : "unreachable");
    }
  } else {
    add(
      "provider.key_and_model",
      "skip",
      options.checkProvider ? "configuration incomplete" : "not requested",
    );
  }

  if (options.checkEndpoint && config) {
    try {
      const res = await (options.fetchFn ?? fetch)(`${config.supabaseUrl}/functions/v1/ai-assist`, {
        method: "POST",
        headers: { "Content-Type": "application/json", apikey: config.supabaseAnonKey },
        body: "{}",
      });
      await res.body?.cancel();
      add("endpoint.requires_session", res.status === 401 ? "pass" : "fail", `http_${res.status}`);
    } catch {
      add("endpoint.requires_session", "fail", "unreachable");
    }
  } else {
    add(
      "endpoint.requires_session",
      "skip",
      options.checkEndpoint ? "configuration incomplete" : "not requested",
    );
  }
  return out;
}

if (import.meta.main) {
  const checks = await runChecks((k) => Deno.env.get(k), {
    checkProvider: Deno.args.includes("--check-provider"),
    checkEndpoint: Deno.args.includes("--check-endpoint"),
  });
  console.log(JSON.stringify(checks, null, 2));
  Deno.exit(checks.some((c) => c.status === "fail") ? 1 : 0);
}
