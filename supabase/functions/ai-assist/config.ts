// Server-side configuration of the AI worker. Every value comes from the Edge Function's
// environment (secrets are set with `supabase secrets set`, never committed, never sent to the app).

export interface AssistConfig {
  /** Supabase API URL and publishable (anon) key: used only to forward the seller's own JWT. */
  supabaseUrl: string;
  supabaseAnonKey: string;
  /** Connection string of the `aisellia_ai_worker` database role (its password is a secret). */
  workerDbUrl: string;
  /** Anthropic API key; null when not configured (runs then fail as provider_error). */
  anthropicApiKey: string | null;
  model: string;
  effort: "low" | "medium" | "high";
  maxTokens: number;
  /** Where inference runs (Anthropic `inference_geo`); null leaves the workspace default. */
  inferenceGeo: "global" | "us" | null;
  /** Provider request timeout and the whole request's budget, in milliseconds. */
  providerTimeoutMs: number;
  budgetMs: number;
  /** Browser origins allowed by CORS (the mobile app sends no Origin). */
  allowedOrigins: string[];
}

export class ConfigError extends Error {}

function required(env: (k: string) => string | undefined, key: string): string {
  const value = env(key)?.trim();
  if (!value) throw new ConfigError(`missing ${key}`);
  return value;
}

function intIn(
  env: (k: string) => string | undefined,
  key: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const raw = env(key);
  if (raw === undefined || raw.trim() === "") return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < min || n > max) throw new ConfigError(`invalid ${key}`);
  return n;
}

export function readConfig(env: (k: string) => string | undefined): AssistConfig {
  const effort = (env("AI_EFFORT") ?? "low").trim();
  if (effort !== "low" && effort !== "medium" && effort !== "high") {
    throw new ConfigError("invalid AI_EFFORT");
  }
  const model = (env("AI_MODEL") ?? "claude-opus-5-5").trim();
  if (!/^[a-z0-9.-]{3,80}$/.test(model)) throw new ConfigError("invalid AI_MODEL");
  const geo = (env("AI_INFERENCE_GEO") ?? "").trim();
  if (geo !== "" && geo !== "global" && geo !== "us") throw new ConfigError("invalid AI_INFERENCE_GEO");
  return {
    supabaseUrl: required(env, "SUPABASE_URL").replace(/\/+$/, ""),
    supabaseAnonKey: required(env, "SUPABASE_ANON_KEY"),
    workerDbUrl: required(env, "AISELLIA_AI_WORKER_DB_URL"),
    anthropicApiKey: env("ANTHROPIC_API_KEY")?.trim() || null,
    model,
    effort,
    maxTokens: intIn(env, "AI_MAX_TOKENS", 8000, 1000, 32000),
    inferenceGeo: geo === "" ? null : geo,
    providerTimeoutMs: intIn(env, "AI_TIMEOUT_MS", 30000, 5000, 60000),
    budgetMs: intIn(env, "AI_BUDGET_MS", 45000, 10000, 110000),
    allowedOrigins: (env("AI_ALLOWED_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(Boolean),
  };
}
