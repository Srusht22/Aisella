// The staging preflight: it reports problems by name and never prints a secret. The database part
// runs against the LOCAL stack (AISELLIA_E2E=1) with a temporary worker password.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import { runChecks } from "../ops/staging_check.ts";
import { API, KEY, withWorker } from "./local_stack.ts";

const status = (checks: { check: string; status: string }[], name: string) =>
  checks.find((c) => c.check === name)?.status;

Deno.test("an empty environment fails by name and touches nothing", async () => {
  const checks = await runChecks(() => undefined);
  assertEquals(status(checks, "config.valid"), "fail");
  assertEquals(status(checks, "secret.anthropic_api_key"), "fail");
  assertEquals(status(checks, "secret.worker_db_url"), "fail");
  assertEquals(status(checks, "worker_db.connect"), "skip");
  assertEquals(status(checks, "provider.key_and_model"), "skip");
});

Deno.test("a remote worker URL must use TLS and the worker role; values are never echoed", async () => {
  const secret = "s3cret-Pa55word";
  const checks = await runChecks((k) =>
    ({
      ANTHROPIC_API_KEY: "not-a-key",
      AISELLIA_AI_WORKER_DB_URL: `postgresql://postgres:${secret}@db.example.invalid:6543/postgres`,
    })[k]
  );
  assertEquals(status(checks, "secret.worker_db_url"), "fail");
  assertEquals(status(checks, "worker_db.tls"), "fail");
  assertEquals(status(checks, "secret.anthropic_api_key"), "fail");
  const text = JSON.stringify(checks);
  assertFalse(text.includes(secret));
  assertFalse(text.includes("not-a-key"));
});

Deno.test({
  name: "against the local stack: the worker role passes every privilege check",
  ignore: Deno.env.get("AISELLIA_E2E") !== "1",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    await withWorker(async (_admin, workerUrl) => {
      const password = decodeURIComponent(new URL(workerUrl).password);
      let probed = "";
      const checks = await runChecks(
        (k) =>
          ({
            SUPABASE_URL: API,
            SUPABASE_ANON_KEY: KEY,
            AISELLIA_AI_WORKER_DB_URL: workerUrl,
            ANTHROPIC_API_KEY: "sk-ant-test-not-a-real-key",
          })[k],
        {
          checkEndpoint: true,
          fetchFn: (input) => {
            probed = String(input);
            return Promise.resolve(new Response(null, { status: 401 }));
          },
        },
      );
      for (
        const name of [
          "config.valid",
          "secret.worker_db_url",
          "worker_db.login",
          "worker_db.no_attributes",
          "worker_db.functions",
          "worker_db.no_tables",
          "migrations.phase_8_5",
          "worker_db.call",
          "endpoint.requires_session",
        ]
      ) {
        assertEquals(
          status(checks, name),
          "pass",
          `${name}: ${JSON.stringify(checks.find((c) => c.check === name))}`,
        );
      }
      assertEquals(status(checks, "worker_db.tls"), "skip");
      assert(probed.endsWith("/functions/v1/ai-assist"));
      assertFalse(JSON.stringify(checks).includes(password));
    });
  },
});
