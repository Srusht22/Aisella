// Server-side configuration: required secrets, bounded numbers, the provider and the region.
import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import { ConfigError, readConfig } from "../config.ts";
import { createProvider } from "../provider_factory.ts";

const base: Record<string, string> = {
  SUPABASE_URL: "http://127.0.0.1:54321/",
  SUPABASE_ANON_KEY: "anon",
  AISELLIA_AI_WORKER_DB_URL: "postgresql://aisellia_ai_worker:x@127.0.0.1:54322/postgres",
};
const read = (extra: Record<string, string> = {}) => readConfig((k) => ({ ...base, ...extra })[k]);

Deno.test("defaults: Gemini (primary provider), its default model, low effort, no key", () => {
  const c = read();
  assertEquals([c.provider, c.model, c.effort, c.maxTokens, c.geminiApiKey, c.inferenceGeo], [
    "gemini",
    "gemini-3.8-flash",
    "low",
    8000,
    null,
    null,
  ]);
  assertEquals(c.geminiStructuredOutput, "json_schema");
  assertEquals(c.supabaseUrl, "http://127.0.0.1:54321");
  assertEquals(createProvider(c).name, "gemini");
});

Deno.test("the model is configurable without a code change, but must match the provider", () => {
  assertEquals(read({ AI_MODEL: "gemini-2.5-flash" }).model, "gemini-2.5-flash");
  assertThrows(() => read({ AI_MODEL: "claude-opus-5-5" }), ConfigError, "does not match");
  const a = read({ AI_PROVIDER: "anthropic" });
  assertEquals([a.model, createProvider(a).name], ["claude-opus-5-5", "anthropic"]);
  assertThrows(
    () => read({ AI_PROVIDER: "anthropic", AI_MODEL: "gemini-3.8-flash" }),
    ConfigError,
    "does not match",
  );
  assertThrows(() => read({ AI_PROVIDER: "openai" }), ConfigError, "invalid AI_PROVIDER");
  assertThrows(() => read({ GEMINI_STRUCTURED_OUTPUT: "xml" }), ConfigError, "GEMINI_STRUCTURED_OUTPUT");
});

Deno.test("AI_INFERENCE_GEO accepts global or us only, and only for anthropic", () => {
  assertEquals(read({ AI_PROVIDER: "anthropic", AI_INFERENCE_GEO: "us" }).inferenceGeo, "us");
  assertEquals(read({ AI_PROVIDER: "anthropic", AI_INFERENCE_GEO: "global" }).inferenceGeo, "global");
  assertThrows(
    () => read({ AI_PROVIDER: "anthropic", AI_INFERENCE_GEO: "eu" }),
    ConfigError,
    "AI_INFERENCE_GEO",
  );
  assertThrows(() => read({ AI_INFERENCE_GEO: "us" }), ConfigError, "anthropic only");
});

Deno.test("a missing secret or an out-of-range number is refused, without echoing values", () => {
  const e = assertThrows(
    () => readConfig((k) => (k === "AISELLIA_AI_WORKER_DB_URL" ? undefined : base[k])),
    ConfigError,
  );
  assertEquals(e.message, "missing AISELLIA_AI_WORKER_DB_URL");
  assertThrows(() => read({ AI_MAX_TOKENS: "64000" }), ConfigError, "invalid AI_MAX_TOKENS");
  assertThrows(() => read({ AI_MODEL: "Gemini Pro!" }), ConfigError, "invalid AI_MODEL");
});
