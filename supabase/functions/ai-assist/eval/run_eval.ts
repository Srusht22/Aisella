// deno-lint-ignore-file no-explicit-any -- untyped API JSON inspected by an evaluation script
// Evaluation against the REAL model provider (Phase 3 AI §11). It costs money, so it runs only on
// request: never in CI and never without an explicit key. It drives the real handler, the real
// database rules and the real AnthropicProvider on the LOCAL stack, then checks what the database
// stored (deterministic checks; no model grading).
//
//   ANTHROPIC_API_KEY=... AISELLIA_EVAL=1 SUPABASE_TEST_URL=http://127.0.0.1:54321 \
//   SUPABASE_TEST_PUBLISHABLE_KEY=... SUPABASE_TEST_JWT_SECRET=... \
//   deno run --allow-net --allow-env --allow-read --allow-write=./eval/out eval/run_eval.ts [scenario-id ...]
import { AnthropicProvider } from "../anthropic_provider.ts";
import { createHandler } from "../handler.ts";
import { PostgrestSellerApi } from "../seller_api.ts";
import { PostgresWorkerDb } from "../worker_db.ts";
import {
  API,
  assertLocal,
  createConversation,
  createSeller,
  KEY,
  type ProductSpec,
  rpc,
  type Seller,
  uuid,
  withWorker,
} from "../tests/local_stack.ts";

interface Expect {
  intent_any?: string[];
  escalated?: boolean;
  escalation_any?: string[];
  facts_include?: string[];
  facts_exclude?: string[];
  reply_language?: string;
  no_flags?: boolean;
  order?: "none" | "draft" | "pending" | "draft_or_pending" | "any";
  line_resolutions?: string[];
  line_variant?: string;
  line_quantity?: number;
  missing_any?: string[];
  phone?: string;
  phone_not?: string;
  text_includes_any?: string[];
  text_excludes?: string[];
  clarification_or_conflict?: boolean;
  never_approved?: boolean;
}
interface Scenario {
  id: string;
  lang: string;
  messages: { direction: "in" | "out"; body: string }[];
  expect: Expect;
}

const apiKey = Deno.env.get("ANTHROPIC_API_KEY")?.trim();
if (Deno.env.get("AISELLIA_EVAL") !== "1" || !apiKey) {
  console.error("Not run: set AISELLIA_EVAL=1 and ANTHROPIC_API_KEY (this evaluation calls the paid API).");
  Deno.exit(2);
}
assertLocal();

const spec = JSON.parse(await Deno.readTextFile(new URL("./scenarios.json", import.meta.url)));
const only = new Set(Deno.args);
const scenarios = (spec.scenarios as Scenario[]).filter((s) => only.size === 0 || only.has(s.id));
const model = Deno.env.get("AI_MODEL") ?? "claude-opus-5-5";
const effort = (Deno.env.get("AI_EFFORT") ?? "low") as "low" | "medium" | "high";

const results = await withWorker(async (admin, workerUrl) => {
  const seller: Seller = await createSeller(admin, { tag: "eval", ...spec.store });
  await createSeller(admin, { tag: "eval-other", ...spec.other_store } as {
    tag: string;
    storeName: string;
    zones: { name: string; fee: number; time_text: string | null }[];
    products: ProductSpec[];
  });
  const handler = createHandler({
    sellerApi: new PostgrestSellerApi(API, KEY),
    db: new PostgresWorkerDb(workerUrl),
    provider: new AnthropicProvider({ apiKey }),
    settings: { model, effort, maxTokens: 8000, providerTimeoutMs: 60000, budgetMs: 110000 },
    allowedOrigins: [],
    log: () => {},
  });

  const out = [];
  for (const s of scenarios) {
    const conv = await createConversation(seller, s.messages);
    const started = Date.now();
    const res = await handler(
      new Request("http://local/ai-assist", {
        method: "POST",
        headers: { Authorization: `Bearer ${seller.token}` },
        body: JSON.stringify({
          store_id: seller.store,
          conversation_id: conv,
          mode: "reply",
          idempotency_key: uuid(),
        }),
      }),
    );
    const call = await res.json();
    const c =
      (await rpc("get_conversation", { p_store_id: seller.store, p_conversation_id: conv }, seller.token))
        .data;
    const order = c.order
      ? (await rpc("get_order", { p_store_id: seller.store, p_order_id: c.order.id }, seller.token)).data
      : null;
    const [run] =
      await admin`select status, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                                     cost_micro_usd, latency_ms, attempts, served_model, output_json ->> 'intent' as intent,
                                     output_json ->> 'reply_language' as lang, output_json #> '{extraction,conflicts}' as conflicts,
                                     output_json -> 'clarification' as clarification
                                from app.ai_runs where conversation_id = ${conv} order by created_at desc limit 1`;
    const failures = check(s.expect, { c, order, run, seller });
    out.push({
      id: s.id,
      lang: s.lang,
      pass: call.ok && run?.status === "succeeded" && failures.length === 0,
      failures: run?.status === "succeeded" ? failures : [`run ${run?.status ?? call.error?.code}`],
      run_status: run?.status,
      intent: run?.intent,
      escalation: c.escalation_reasons,
      reply: c.suggestion?.text ?? null,
      flags: c.suggestion?.flags ?? [],
      order_status: order?.status ?? null,
      latency_ms: Date.now() - started,
      tokens: run
        ? { in: run.input_tokens, out: run.output_tokens, cache_read: run.cache_read_tokens }
        : null,
      cost_micro_usd: run?.cost_micro_usd ?? null,
      served_model: run?.served_model ?? null,
    });
    console.log(`${out.at(-1)!.pass ? "PASS" : "FAIL"} ${s.id} ${out.at(-1)!.failures.join("; ")}`);
  }
  return out;
});

function check(
  e: Expect,
  x: { c: Record<string, any>; order: Record<string, any> | null; run: Record<string, any>; seller: Seller },
): string[] {
  const f: string[] = [];
  const s = x.c.suggestion ?? {};
  const facts: string[] = (s.facts_used ?? []).map((u: { fact: string }) => u.fact);
  const text: string = (s.text ?? "").toLowerCase();
  const escalated = (x.c.escalation_reasons ?? []).length > 0;
  if (e.intent_any && !e.intent_any.includes(x.run?.intent)) f.push(`intent ${x.run?.intent}`);
  if (e.escalated !== undefined && escalated !== e.escalated) f.push(`escalated=${escalated}`);
  if (e.escalation_any && !e.escalation_any.some((r) => x.c.escalation_reasons.includes(r))) {
    f.push(`reasons ${x.c.escalation_reasons}`);
  }
  for (const k of e.facts_include ?? []) if (!facts.includes(k)) f.push(`missing fact ${k}`);
  for (const k of e.facts_exclude ?? []) if (facts.includes(k)) f.push(`unexpected fact ${k}`);
  if (e.reply_language && x.run?.lang !== e.reply_language) f.push(`language ${x.run?.lang}`);
  if (e.no_flags && (s.flags ?? []).length > 0) f.push(`flags ${s.flags}`);
  for (const t of e.text_excludes ?? []) if (text.includes(t.toLowerCase())) f.push(`text has "${t}"`);
  if (e.text_includes_any && !e.text_includes_any.some((t) => text.includes(t.toLowerCase()))) {
    f.push("expected wording missing");
  }
  const st = x.order?.status ?? null;
  const ok = {
    none: st === null,
    draft: st === "draft",
    pending: st === "pending_approval",
    draft_or_pending: st === "draft" || st === "pending_approval",
    any: true,
  }[e.order ?? "any"];
  if (!ok) f.push(`order ${st}`);
  if (st && !["draft", "pending_approval"].includes(st)) f.push(`order advanced to ${st}`);
  if (e.never_approved && (x.order?.events ?? []).some((ev: { to: string }) => ev.to === "approved")) {
    f.push("approved");
  }
  const lines = x.order?.lines ?? [];
  if (
    e.line_resolutions &&
    !lines.some((l: { resolution: string }) => e.line_resolutions!.includes(l.resolution))
  ) {
    f.push(`resolutions ${lines.map((l: { resolution: string }) => l.resolution)}`);
  }
  if (
    e.line_variant &&
    !lines.some((l: { variant_id: string }) => l.variant_id === x.seller.variants[e.line_variant!])
  ) {
    f.push(`variant not ${e.line_variant}`);
  }
  if (e.line_quantity && !lines.some((l: { quantity: number }) => l.quantity === e.line_quantity)) {
    f.push(`quantity not ${e.line_quantity}`);
  }
  if (e.missing_any && !e.missing_any.some((m) => (s.missing_fields ?? []).includes(m))) {
    f.push("missing_fields");
  }
  if (e.phone && x.order?.customer?.phone !== e.phone) f.push(`phone ${x.order?.customer?.phone}`);
  if (e.phone_not && x.order?.customer?.phone === e.phone_not) f.push("kept the corrected phone");
  if (e.clarification_or_conflict) {
    const conflicts = (x.run?.conflicts ?? []).length;
    const clar = (x.run?.clarification ?? []).length;
    if (conflicts === 0 && clar === 0 && !escalated) f.push("no clarification or conflict");
  }
  return f;
}

const summary = {
  version: spec.version,
  model,
  effort,
  ran_at: new Date().toISOString(),
  passed: results.filter((r) => r.pass).length,
  total: results.length,
  auto_approved: 0,
  unsupported_claims_shown:
    results.filter((r) =>
      (r.flags as string[]).length > 0 && r.reply && !r.reply.startsWith("Thank you for your message")
    ).length,
  total_cost_micro_usd: results.reduce((a, r) => a + Number(r.cost_micro_usd ?? 0), 0),
  results,
};
await Deno.mkdir(new URL("./out/", import.meta.url), { recursive: true });
const file = new URL(`./out/eval-${summary.ran_at.replace(/[:.]/g, "-")}.json`, import.meta.url);
await Deno.writeTextFile(file, JSON.stringify(summary, null, 2));
console.log(`${summary.passed}/${summary.total} passed; report: ${file.pathname}`);
