// Server-side configuration: required secrets, bounded numbers, and the inference region.
import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import { ConfigError, readConfig } from "../config.ts";

const base: Record<string, string> = {
  SUPABASE_URL: "http://127.0.0.1:54321/",
  SUPABASE_ANON_KEY: "anon",
  AISELLIA_AI_WORKER_DB_URL: "postgresql://aisellia_ai_worker:x@127.0.0.1:54322/postgres",
};
const read = (extra: Record<string, string> = {}) => readConfig((k) => ({ ...base, ...extra })[k]);

Deno.test("defaults: Opus 5.5, low effort, no key, provider's default region", () => {
  const c = read();
  assertEquals([c.model, c.effort, c.maxTokens, c.anthropicApiKey, c.inferenceGeo], [
    "claude-opus-5-5",
    "low",
    8000,
    null,
    null,
  ]);
  assertEquals(c.supabaseUrl, "http://127.0.0.1:54321");
});

Deno.test("AI_INFERENCE_GEO accepts global or us only", () => {
  assertEquals(read({ AI_INFERENCE_GEO: "us" }).inferenceGeo, "us");
  assertEquals(read({ AI_INFERENCE_GEO: "global" }).inferenceGeo, "global");
  assertThrows(() => read({ AI_INFERENCE_GEO: "eu" }), ConfigError, "AI_INFERENCE_GEO");
});

Deno.test("a missing secret or an out-of-range number is refused, without echoing values", () => {
  const e = assertThrows(
    () => readConfig((k) => (k === "AISELLIA_AI_WORKER_DB_URL" ? undefined : base[k])),
    ConfigError,
  );
  assertEquals(e.message, "missing AISELLIA_AI_WORKER_DB_URL");
  assertThrows(() => read({ AI_MAX_TOKENS: "64000" }), ConfigError, "invalid AI_MAX_TOKENS");
  assertThrows(() => read({ AI_MODEL: "Claude Opus!" }), ConfigError, "invalid AI_MODEL");
});
