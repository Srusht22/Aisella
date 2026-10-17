// Shared test fixtures. Test doubles here are labelled as such: ScriptedProvider plays a model,
// MemoryWorkerDb plays the database. Production code never imports this file.
import type { AiProvider, ProviderRequest, ProviderResponse } from "../provider.ts";
import { ProviderError } from "../provider.ts";
import type { ApiResult, WorkerDb } from "../worker_db.ts";
import { DbUnavailable } from "../worker_db.ts";

export const VARIANT = "11111111-1111-4111-8111-111111111111";
export const ZONE = "22222222-2222-4222-8222-222222222222";

export function validOutput(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    intent: "price_inquiry",
    reply_language: "en",
    reply: [{ text: "The price is " }, { fact: "variant_price", ref: VARIANT }, { text: "." }],
    clarification: [],
    extraction: null,
    missing_fields: [],
    escalation: { required: false, reasons: [] },
    ...overrides,
  };
}

export const orderExtraction = () => ({
  customer_name: { value: "Nzar", basis: "stated" },
  phone: { token: "PHONE_1" },
  phone2: null,
  zone_id: ZONE,
  city_text: null,
  area: "Ankawa",
  landmark: null,
  address_details: null,
  payment_method: "cod",
  customer_note: null,
  lines: [{
    candidate_variant_ids: [VARIANT],
    customer_text: "beige M",
    quantity: 2,
    quantity_basis: "stated",
  }],
  conflicts: [],
});

export const sampleContext = () => ({
  store: { name: "Shop", currency: "IQD", default_reply_language: "ckb", payment_methods: ["cod"] },
  policies: [],
  zones: [{ zone_id: ZONE, name: "Erbil", has_time_text: true }],
  catalog: [{
    product_id: "p",
    name: "Beige Abaya",
    variants: [{ variant_id: VARIANT, availability: "in_stock" }],
  }],
  catalog_is_partial: false,
  conversation: {
    source: "instagram",
    is_sandbox: false,
    messages: [{ id: "m1", from: "customer", text: "How much is the beige abaya? [PHONE_1]" }],
  },
  draft: null,
  state: { intent: null, missing_fields: [] },
});

type Step = ProviderResponse | ProviderError | ((req: ProviderRequest) => Promise<ProviderResponse>);

/** Test double for a model: returns the scripted responses in order and records every request. */
export class ScriptedProvider implements AiProvider {
  readonly name = "scripted";
  readonly requests: ProviderRequest[] = [];
  constructor(private readonly steps: Step[]) {}
  async generate(req: ProviderRequest): Promise<ProviderResponse> {
    this.requests.push(req);
    const step = this.steps.shift();
    if (step === undefined) throw new Error("no scripted response left");
    if (step instanceof ProviderError) throw step;
    if (typeof step === "function") return await step(req);
    return step;
  }
}

export const response = (text: string | null, stopReason = "end_turn"): ProviderResponse => ({
  text,
  stopReason,
  servedModel: "claude-opus-5-5",
  requestId: "req_test",
  usage: { input_tokens: 100, output_tokens: 50, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
});

/** Test double for the worker database: records calls; can simulate a lost connection. */
export class MemoryWorkerDb implements WorkerDb {
  readonly calls: { fn: string; args: unknown[] }[] = [];
  claim: ApiResult = { ok: true, data: { run_id: "run", mode: "reply", context: sampleContext() } };
  completeResults: (ApiResult | "lost")[] = [{ ok: true, data: { suggestion_id: "s", escalated: false } }];
  state: ApiResult = { ok: true, data: { run_id: "run", status: "succeeded" } };

  claimRun(runId: string) {
    this.calls.push({ fn: "claim", args: [runId] });
    return Promise.resolve(this.claim);
  }
  completeRun(runId: string, output: unknown, meta: Record<string, unknown>) {
    this.calls.push({ fn: "complete", args: [runId, output, meta] });
    const next = this.completeResults.shift() ?? { ok: true, data: {} };
    if (next === "lost") return Promise.reject(new DbUnavailable("lost"));
    return Promise.resolve(next);
  }
  failRun(runId: string, status: string, code: string, meta: Record<string, unknown>) {
    this.calls.push({ fn: "fail", args: [runId, status, code, meta] });
    return Promise.resolve({ ok: true, data: { status } });
  }
  runState(runId: string) {
    this.calls.push({ fn: "state", args: [runId] });
    return Promise.resolve(this.state);
  }
}

export const settings = {
  model: "claude-opus-5-5",
  effort: "low" as const,
  maxTokens: 8000,
  providerTimeoutMs: 30000,
  budgetMs: 45000,
};
