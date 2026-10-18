// The Gemini provider against a LOCAL HTTP stub that imitates `models/{model}:generateContent` (no
// real model, no network). It checks the request we send and how responses and errors are mapped.
// The real API is exercised only by eval/run_eval.ts and the staging preflight, with a key.
import { assert, assertEquals, assertFalse, assertRejects } from "jsr:@std/assert@1.0.13";
import { GeminiProvider } from "../gemini_provider.ts";
import { ProviderError, type ProviderRequest } from "../provider.ts";
import { OUTPUT_SCHEMA } from "../output_schema.ts";

const KEY = "test-not-a-real-gemini-key-0000000000";

function stub(handler: (req: Request, body: Record<string, unknown>) => Response | Promise<Response>) {
  const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen: () => {} }, async (req) => {
    const body = await req.json().catch(() => ({}));
    return handler(req, body);
  });
  return { server, url: `http://127.0.0.1:${server.addr.port}` };
}

const request = (timeoutMs = 5000, model = "gemini-2.5-pro"): ProviderRequest => ({
  system: [{ text: "rules", cache: true }, { text: "store", cache: true }],
  user: "conversation",
  schema: OUTPUT_SCHEMA,
  model,
  effort: "low",
  maxTokens: 8000,
  timeoutMs,
});

export const geminiAnswer = (text: string, finishReason = "STOP") => ({
  candidates: [{
    content: { role: "model", parts: [{ text: "thinking…", thought: true }, { text }] },
    finishReason,
  }],
  usageMetadata: {
    promptTokenCount: 1200,
    candidatesTokenCount: 300,
    thoughtsTokenCount: 200,
    cachedContentTokenCount: 900,
  },
  modelVersion: "gemini-2.5-pro",
  responseId: "resp_abc",
});

Deno.test("the request: key in a header (not the URL), system rules, JSON schema, thinking from effort", async () => {
  let seen: { url: string; headers: Headers; body: Record<string, unknown> } | null = null;
  const { server, url } = stub((req, body) => {
    seen = { url: req.url, headers: req.headers, body };
    return Response.json(geminiAnswer('{"ok":true}'));
  });
  try {
    const out = await new GeminiProvider({ apiKey: KEY, baseURL: url, maxRetries: 0 }).generate(request());
    assertEquals(out.text, '{"ok":true}', "thought parts are never taken as the answer");
    assertEquals([out.servedModel, out.requestId, out.stopReason], [
      "gemini-2.5-pro",
      "resp_abc",
      "end_turn",
    ]);
    assertEquals(out.usage, {
      input_tokens: 300,
      output_tokens: 500,
      cache_read_input_tokens: 900,
      cache_creation_input_tokens: 0,
    });
    const s = seen!;
    assertEquals(new URL(s.url).pathname, "/v1beta/models/gemini-2.5-pro:generateContent");
    assertFalse(s.url.includes(KEY), "the key is never in the URL");
    assertEquals(s.headers.get("x-goog-api-key"), KEY);
    const system = s.body.systemInstruction as { parts: { text: string }[] };
    assertEquals(system.parts.map((p) => p.text), ["rules", "store"]);
    const cfg = s.body.generationConfig as Record<string, unknown>;
    assertEquals(cfg.responseMimeType, "application/json");
    assertEquals(cfg.responseJsonSchema, OUTPUT_SCHEMA);
    assertEquals(cfg.maxOutputTokens, 8000);
    assertEquals(cfg.thinkingConfig, { thinkingBudget: 1024 });
  } finally {
    await server.shutdown();
  }
});

Deno.test("later model families get a thinking level; json_only omits the schema", async () => {
  const bodies: Record<string, unknown>[] = [];
  const { server, url } = stub((_req, body) => {
    bodies.push(body);
    return Response.json(geminiAnswer("{}"));
  });
  try {
    await new GeminiProvider({ apiKey: KEY, baseURL: url, maxRetries: 0 }).generate(
      request(5000, "gemini-3-pro"),
    );
    await new GeminiProvider({ apiKey: KEY, baseURL: url, maxRetries: 0, structuredOutput: "json_only" })
      .generate(request());
    const c0 = bodies[0].generationConfig as Record<string, unknown>;
    const c1 = bodies[1].generationConfig as Record<string, unknown>;
    assertEquals(c0.thinkingConfig, { thinkingLevel: "low" });
    assertFalse("responseJsonSchema" in c1);
    assertEquals(c1.responseMimeType, "application/json");
  } finally {
    await server.shutdown();
  }
});

Deno.test("blocked prompts and safety stops are refusals; MAX_TOKENS is truncation", async () => {
  const replies = [
    { promptFeedback: { blockReason: "SAFETY" }, usageMetadata: { promptTokenCount: 10 } },
    geminiAnswer("", "SAFETY"),
    geminiAnswer('{"partial', "MAX_TOKENS"),
  ];
  let i = 0;
  const { server, url } = stub(() => Response.json(replies[i++]));
  try {
    const p = new GeminiProvider({ apiKey: KEY, baseURL: url, maxRetries: 0 });
    const blocked = await p.generate(request());
    assertEquals([blocked.stopReason, blocked.text], ["refusal", null]);
    assertEquals((await p.generate(request())).stopReason, "refusal");
    assertEquals((await p.generate(request())).stopReason, "max_tokens");
  } finally {
    await server.shutdown();
  }
});

for (
  const [status, kind, code] of [
    [429, "rate_limited", "provider_rate_limited"],
    [500, "provider_error", "server_error"],
    [503, "provider_error", "overloaded"],
    [401, "provider_error", "auth"],
    [403, "provider_error", "auth"],
    [400, "provider_error", "bad_request"],
    [404, "provider_error", "model_not_found"],
  ] as const
) {
  Deno.test(`HTTP ${status} becomes ${kind}/${code}, without the API's message or the key`, async () => {
    const { server, url } = stub(() =>
      Response.json({ error: { code: status, message: `secret detail ${KEY}`, status: "X" } }, { status })
    );
    try {
      const error = await assertRejects(
        () => new GeminiProvider({ apiKey: KEY, baseURL: url, maxRetries: 0 }).generate(request()),
        ProviderError,
      );
      assertEquals([error.kind, error.code, error.status], [kind, code, status]);
      assertFalse(error.message.includes(KEY));
      assertFalse(error.message.includes("secret detail"));
    } finally {
      await server.shutdown();
    }
  });
}

Deno.test("one retry on a 503, then success; a 400 is never retried", async () => {
  let calls = 0;
  const { server, url } = stub(() => {
    calls++;
    return calls === 1 ? new Response("busy", { status: 503 }) : Response.json(geminiAnswer('{"ok":true}'));
  });
  try {
    const out = await new GeminiProvider({ apiKey: KEY, baseURL: url, maxRetries: 1 }).generate(request());
    assertEquals([out.text, calls], ['{"ok":true}', 2]);
  } finally {
    await server.shutdown();
  }
  let bad = 0;
  const s2 = stub(() => {
    bad++;
    return new Response("{}", { status: 400 });
  });
  try {
    await assertRejects(
      () => new GeminiProvider({ apiKey: KEY, baseURL: s2.url, maxRetries: 1 }).generate(request()),
      ProviderError,
    );
    assertEquals(bad, 1);
  } finally {
    await s2.server.shutdown();
  }
});

Deno.test("a slow provider times out within the request's budget", async () => {
  const { server, url } = stub(async () => {
    await new Promise((r) => setTimeout(r, 1500));
    return Response.json(geminiAnswer("{}"));
  });
  try {
    const started = Date.now();
    const error = await assertRejects(
      () => new GeminiProvider({ apiKey: KEY, baseURL: url, maxRetries: 1 }).generate(request(300)),
      ProviderError,
    );
    assertEquals(error.kind, "timeout");
    assert(Date.now() - started < 1400, "no retry after the budget is spent");
  } finally {
    await server.shutdown();
  }
});

Deno.test("without a configured key nothing is sent; a malformed model id is refused", async () => {
  const error = await assertRejects(
    () => new GeminiProvider({ apiKey: null }).generate(request()),
    ProviderError,
  );
  assertEquals(error.kind, "not_configured");
  let called = false;
  const p = new GeminiProvider({
    apiKey: KEY,
    fetchFn: () => {
      called = true;
      return Promise.resolve(new Response("{}"));
    },
  });
  await assertRejects(() => p.generate(request(5000, "../models/x?key=1")), ProviderError);
  assertFalse(called);
});
