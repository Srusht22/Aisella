// The evaluation's report logic, without a key, a database or a model.
import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import { ArgsError, type EvalResult, parseArgs, report } from "../eval/summary.ts";

const r = (over: Partial<EvalResult>): EvalResult => ({
  id: "x",
  lang: "en",
  pass: true,
  failures: [],
  run_status: "succeeded",
  expected_escalated: false,
  escalated: false,
  grounding_expected: false,
  grounding_ok: false,
  flags: [],
  is_holding: false,
  order_status: null,
  approved: false,
  latency_ms: 1000,
  cost_micro_usd: 20000,
  ...over,
});

Deno.test("arguments: ids, a spending cap, an external set, plan mode", () => {
  assertEquals(parseArgs(["en-price", "--max-cost-usd=2.5", "--set=/tmp/c.json", "--plan"]), {
    ids: ["en-price"],
    maxCostUsd: 2.5,
    setPath: "/tmp/c.json",
    plan: true,
  });
  assertEquals(parseArgs([]).maxCostUsd, 2);
  assertThrows(() => parseArgs(["--max-cost-usd=0"]), ArgsError);
  assertThrows(() => parseArgs(["--max-cost-usd=500"]), ArgsError);
  assertThrows(() => parseArgs(["--model=x"]), ArgsError);
});

Deno.test("the report separates languages and counts what matters", () => {
  const out = report([
    r({ id: "a", grounding_expected: true, grounding_ok: true, latency_ms: 800 }),
    r({
      id: "b",
      grounding_expected: true,
      grounding_ok: false,
      flags: ["money"],
      is_holding: true,
      pass: false,
    }),
    r({ id: "c", lang: "ckb", expected_escalated: true, escalated: true, latency_ms: 3000 }),
    r({ id: "d", lang: "ckb", expected_escalated: true, escalated: false, pass: false }),
    r({
      id: "e",
      lang: "ar",
      flags: ["claim"],
      is_holding: false,
      pass: false,
      order_status: "approved",
      approved: true,
    }),
    r({ id: "f", lang: "ar", run_status: "not_run", pass: false, cost_micro_usd: null, latency_ms: null }),
  ]);
  assertEquals(Object.keys(out), ["all", "ar", "ckb", "en"]);
  assertEquals(out.en.grounded, { expected: 2, ok: 1 });
  assertEquals(out.en.fabrication, { attempts_caught: 1, shown_to_seller: 0 });
  assertEquals(out.ckb.escalation, { expected: 2, caught: 1, missed: 1, false_alarms: 0 });
  assertEquals(out.ar.fabrication.shown_to_seller, 1, "a flagged reply that was not replaced is reported");
  assertEquals(out.ar.orders, { advanced_past_review: 1, approved: 1 });
  assertEquals([out.ar.scenarios, out.ar.ran], [2, 1], "scenarios skipped by the cap are not counted as run");
  assertEquals(out.all.cost_usd, { total: 0.1, mean_per_run: 0.02 });
  assertEquals(out.ckb.latency_ms, { p50: 1000, p95: 3000, max: 3000 });
});
