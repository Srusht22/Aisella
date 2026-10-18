// Server-side configuration of the AI worker. Every value comes from the Edge Function's
// environment (secrets are set with `supabase secrets set`, never committed, never sent to the app).

export interface AssistConfig {
  /** Supabase API URL and publishable (anon) key: used only to forward the seller's own JWT. */
  supabaseUrl: string;
  supabaseAnonKey: string;
  /** Connection string of the `aisellia_ai_worker` database role (its password is a secret). */
  workerDbUrl: string;
  /** Which model provider runs the assistant (AI_PROVIDER); Gemini is the primary one. */
  provider: AiProviderName;
  /** Gemini API key; null when not configured (runs then fail as provider_error). */
  geminiApiKey: string | null;
  /** How Gemini is asked for structured output (see gemini_provider.ts). */
  geminiStructuredOutput: "json_schema" | "json_only";
  /** Anthropic API key, used only when AI_PROVIDER=anthropic. */
  anthropicApiKey: string | null;
  /** Model id for the chosen provider (AI_MODEL); its price must be in app.ai_model_prices. */
  model: string;
  effort: "low" | "medium" | "high";
  maxTokens: number;
  /** Where inference runs (Anthropic `inference_geo` only); null leaves the provider's default. */
  inferenceGeo: "global" | "us" | null;
  /** Provider request timeout and the whole request's budget, in milliseconds. */
  providerTimeoutMs: number;
  budgetMs: number;
  /** Browser origins allowed by CORS (the mobile app sends no Origin). */
  allowedOrigins: string[];
}

export type AiProviderName = "gemini" | "anthropic";

/** Default model per provider; any other is chosen with AI_MODEL without a code change. */
export const DEFAULT_MODELS: Record<AiProviderName, string> = {
  // gemini-2.5-pro is closed to new projects since 2026-09-18; 3.8 Flash is listed Stable (2026-10-18).
  gemini: "gemini-3.8-flash",
  anthropic: "claude-opus-5-5",
};

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
  const provider = (env("AI_PROVIDER") ?? "gemini").trim() || "gemini";
  if (provider !== "gemini" && provider !== "anthropic") throw new ConfigError("invalid AI_PROVIDER");
  const model = (env("AI_MODEL") ?? "").trim() || DEFAULT_MODELS[provider];
  if (!/^[a-z0-9.-]{3,80}$/.test(model)) throw new ConfigError("invalid AI_MODEL");
  // A model from the other provider would be sent to the wrong API (and priced wrongly).
  if ((provider === "gemini") !== model.startsWith("gemini-")) {
    throw new ConfigError("AI_MODEL does not match AI_PROVIDER");
  }
  const geo = (env("AI_INFERENCE_GEO") ?? "").trim();
  if (geo !== "" && geo !== "global" && geo !== "us") throw new ConfigError("invalid AI_INFERENCE_GEO");
  if (geo !== "" && provider !== "anthropic") {
    throw new ConfigError("AI_INFERENCE_GEO applies to anthropic only");
  }
  const structured = (env("GEMINI_STRUCTURED_OUTPUT") ?? "json_schema").trim();
  if (structured !== "json_schema" && structured !== "json_only") {
    throw new ConfigError("invalid GEMINI_STRUCTURED_OUTPUT");
  }
  return {
    supabaseUrl: required(env, "SUPABASE_URL").replace(/\/+$/, ""),
    supabaseAnonKey: required(env, "SUPABASE_ANON_KEY"),
    workerDbUrl: required(env, "AISELLIA_AI_WORKER_DB_URL"),
    provider,
    geminiApiKey: env("GEMINI_API_KEY")?.trim() || null,
    geminiStructuredOutput: structured,
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
