// Supabase Edge Function `ai-assist`: the AI sales assistant's server side (Phase 8).
// Secrets (ANTHROPIC_API_KEY, AISELLIA_AI_WORKER_DB_URL) live only in the function's environment.
import { AnthropicProvider } from "./anthropic_provider.ts";
import { readConfig } from "./config.ts";
import { createHandler } from "./handler.ts";
import { PostgrestSellerApi } from "./seller_api.ts";
import { PostgresWorkerDb } from "./worker_db.ts";

const config = readConfig((k) => Deno.env.get(k));

Deno.serve(createHandler({
  sellerApi: new PostgrestSellerApi(config.supabaseUrl, config.supabaseAnonKey),
  db: new PostgresWorkerDb(config.workerDbUrl),
  provider: new AnthropicProvider({ apiKey: config.anthropicApiKey }),
  settings: {
    model: config.model,
    effort: config.effort,
    maxTokens: config.maxTokens,
    providerTimeoutMs: config.providerTimeoutMs,
    budgetMs: config.budgetMs,
  },
  allowedOrigins: config.allowedOrigins,
  // Operational metadata only: never message text, prompts, outputs or keys.
  log: (event) => console.log(JSON.stringify({ fn: "ai-assist", ts: new Date().toISOString(), ...event })),
}));
