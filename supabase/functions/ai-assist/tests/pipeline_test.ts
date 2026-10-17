// The run pipeline with a scripted model and an in-memory database (both test doubles).
import { assert, assertEquals } from "jsr:@std/assert@1.0.13";
import { runAssist } from "../pipeline.ts";
import { ProviderError } from "../provider.ts";
import { MemoryWorkerDb, response, ScriptedProvider, settings, validOutput } from "./fixtures.ts";

const run = (db: MemoryWorkerDb, provider: ScriptedProvider, now?: () => number) => {
  const events: Record<string, unknown>[] = [];
  return runAssist("run", { db, provider, settings, log: (e) => events.push(e), correlationId: "corr", now })
    .then((outcome) => ({ outcome, events }));
};

Deno.test("a valid answer is handed to the database once", async () => {
  const db = new MemoryWorkerDb();
  const provider = new ScriptedProvider([response(JSON.stringify(validOutput()))]);
  const { outcome } = await run(db, provider);
  assertEquals(outcome.status, "succeeded");
  assertEquals(db.calls.map((c) => c.fn), ["claim", "complete"]);
  const meta = db.calls[1].args[2] as Record<string, unknown>;
  assertEquals(meta.prompt_version, "p8.1");
  assertEquals(meta.attempts, 1);
  assertEquals((meta.usage as Record<string, number>).input_tokens, 100);
});

Deno.test("the inference region is requested and recorded for costing", async () => {
  const db = new MemoryWorkerDb();
  const provider = new ScriptedProvider([{ ...response(JSON.stringify(validOutput())), inferenceGeo: "us" }]);
  await runAssist("run", {
    db,
    provider,
    settings: { ...settings, inferenceGeo: "us" },
    log: () => {},
    correlationId: "corr",
  });
  assertEquals(provider.requests[0].inferenceGeo, "us");
  assertEquals((db.calls[1].args[2] as Record<string, unknown>).inference_geo, "us");
  const db2 = new MemoryWorkerDb();
  await run(db2, new ScriptedProvider([response(JSON.stringify(validOutput()))]));
  assertEquals(
    (db2.calls[1].args[2] as Record<string, unknown>).inference_geo,
    null,
    "unknown region is recorded as null",
  );
});

Deno.test("the provider receives the schema, the effort and the run's context only", async () => {
  const db = new MemoryWorkerDb();
  const provider = new ScriptedProvider([response(JSON.stringify(validOutput()))]);
  await run(db, provider);
  const req = provider.requests[0];
  assertEquals(req.effort, "low");
  assertEquals((req.schema as { type: string }).type, "object");
  assert(req.user.includes("[PHONE_1]"));
});

Deno.test("invalid output is retried once, then the second answer is used", async () => {
  const db = new MemoryWorkerDb();
  const provider = new ScriptedProvider([
    response('{"intent": "place_order", "status": "approved"}'),
    response(JSON.stringify(validOutput())),
  ]);
  const { outcome } = await run(db, provider);
  assertEquals(outcome.status, "succeeded");
  assertEquals(provider.requests.length, 2);
  assertEquals((db.calls[1].args[2] as Record<string, unknown>).attempts, 2);
  assertEquals(
    (db.calls[1].args[2] as { usage: { input_tokens: number } }).usage.input_tokens,
    200,
    "usage of both calls is recorded",
  );
});

Deno.test("two invalid answers fail the run as invalid_output (no third call)", async () => {
  const db = new MemoryWorkerDb();
  const provider = new ScriptedProvider([response("not json"), response("{}")]);
  const { outcome } = await run(db, provider);
  assertEquals(outcome.status, "invalid_output");
  assertEquals(provider.requests.length, 2);
  assertEquals(db.calls.map((c) => c.fn), ["claim", "fail"]);
  assertEquals(db.calls[1].args[1], "invalid_output");
});

Deno.test("a truncated answer (max_tokens) counts as invalid", async () => {
  const db = new MemoryWorkerDb();
  const provider = new ScriptedProvider([
    response('{"intent":', "max_tokens"),
    response(JSON.stringify(validOutput())),
  ]);
  const { outcome } = await run(db, provider);
  assertEquals(outcome.status, "succeeded");
  assertEquals(provider.requests.length, 2);
});

Deno.test("a refusal is recorded as refused, not retried", async () => {
  const db = new MemoryWorkerDb();
  const provider = new ScriptedProvider([response(null, "refusal")]);
  const { outcome } = await run(db, provider);
  assertEquals(outcome.status, "refused");
  assertEquals(provider.requests.length, 1);
  assertEquals(db.calls[1].args[1], "refused");
});

for (
  const [kind, status] of [["timeout", "timeout"], ["rate_limited", "rate_limited"], [
    "provider_error",
    "provider_error",
  ], ["not_configured", "provider_error"]] as const
) {
  Deno.test(`a provider ${kind} fails the run as ${status}`, async () => {
    const db = new MemoryWorkerDb();
    const provider = new ScriptedProvider([new ProviderError(kind, "x")]);
    const { outcome, events } = await run(db, provider);
    assertEquals(outcome.status, status);
    assertEquals(db.calls.map((c) => c.fn), ["claim", "fail"]);
    assert(events.every((e) => !JSON.stringify(e).includes("beige")), "no message text in logs");
  });
}

Deno.test("a run that cannot be claimed calls no model", async () => {
  const db = new MemoryWorkerDb();
  db.claim = { ok: false, error: { code: "RUN_NOT_CLAIMABLE" } };
  const provider = new ScriptedProvider([]);
  const { outcome } = await run(db, provider);
  assertEquals(outcome.status, "not_claimed");
  assertEquals(provider.requests.length, 0);
});

Deno.test("a lost connection after the write is reconciled, not written twice", async () => {
  const db = new MemoryWorkerDb();
  db.completeResults = ["lost"];
  db.state = { ok: true, data: { status: "succeeded" } };
  const { outcome } = await run(db, new ScriptedProvider([response(JSON.stringify(validOutput()))]));
  assertEquals(outcome.status, "succeeded");
  assertEquals(db.calls.map((c) => c.fn), ["claim", "complete", "state"]);
});

Deno.test("a lost connection before the write commits is retried once after reconciling", async () => {
  const db = new MemoryWorkerDb();
  db.completeResults = ["lost", { ok: true, data: { suggestion_id: "s" } }];
  db.state = { ok: true, data: { status: "running" } };
  const { outcome } = await run(db, new ScriptedProvider([response(JSON.stringify(validOutput()))]));
  assertEquals(outcome.status, "succeeded");
  assertEquals(db.calls.map((c) => c.fn), ["claim", "complete", "state", "complete"]);
});

Deno.test("no second model call when the time budget is spent", async () => {
  let t = 0;
  const db = new MemoryWorkerDb();
  const provider = new ScriptedProvider([
    () => {
      t += 40000;
      return Promise.resolve(response("not json"));
    },
  ]);
  const { outcome } = await run(db, provider, () => t);
  assertEquals(outcome.status, "invalid_output");
  assertEquals(provider.requests.length, 1);
});
