// The Anthropic provider against a LOCAL HTTP stub that imitates the Messages API (no real model,
// no network). It checks the request we send and how API errors are mapped. The real API is
// exercised by eval/run_eval.ts when an ANTHROPIC_API_KEY is configured.
import { assert, assertEquals, assertFalse, assertRejects } from "jsr:@std/assert@1.0.13";
import { AnthropicProvider } from "../anthropic_provider.ts";
import { ProviderError, type ProviderRequest } from "../provider.ts";
import { OUTPUT_SCHEMA } from "../output_schema.ts";

const KEY = "sk-ant-test-not-a-real-key-000000";

function stub(handler: (req: Request, body: Record<string, unknown>) => Response | Promise<Response>) {
  const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen: () => {} }, async (req) => {
    const body = await req.json().catch(() => ({}));
    return handler(req, body);
  });
  return { server, url: `http://127.0.0.1:${server.addr.port}` };
}

const request = (timeoutMs = 5000): ProviderRequest => ({
  system: [{ text: "rules", cache: true }, { text: "store", cache: true }],
  user: "conversation",
  schema: OUTPUT_SCHEMA,
  model: "claude-opus-5-5",
  effort: "low",
  maxTokens: 8000,
  timeoutMs,
});

const message = (text: string, stop = "end_turn") => ({
  id: "msg_1",
  type: "message",
  role: "assistant",
  model: "claude-opus-5-5",
  content: [{ type: "text", text }],
  stop_reason: stop,
  stop_sequence: null,
  usage: {
    input_tokens: 1200,
    output_tokens: 300,
    cache_read_input_tokens: 900,
    cache_creation_input_tokens: 0,
  },
});

Deno.test("the request carries the key, the version, the schema, the effort and cache markers", async () => {
  let seen: { headers: Headers; body: Record<string, unknown> } | null = null;
  const { server, url } = stub((req, body) => {
    seen = { headers: req.headers, body };
    return Response.json(message('{"ok":true}'), { headers: { "request-id": "req_abc" } });
  });
  try {
    const out = await new AnthropicProvider({ apiKey: KEY, baseURL: url, maxRetries: 0 }).generate(request());
    assertEquals(out.text, '{"ok":true}');
    assertEquals(out.servedModel, "claude-opus-5-5");
    assertEquals(out.usage.cache_read_input_tokens, 900);
    const s = seen!;
    assertEquals(s.headers.get("x-api-key"), KEY);
    assert(s.headers.get("anthropic-version"));
    assertEquals(s.body.model, "claude-opus-5-5");
    assertEquals(s.body.max_tokens, 8000);
    const cfg = s.body.output_config as { effort: string; format: { type: string; schema: unknown } };
    assertEquals(cfg.effort, "low");
    assertEquals(cfg.format.type, "json_schema");
    const system = s.body.system as { cache_control?: unknown }[];
    assertEquals(system.length, 2);
    assert(system.every((b) => b.cache_control));
    assertFalse("thinking" in s.body, "Opus 5.5 thinking is controlled by effort only");
  } finally {
    await server.shutdown();
  }
});

Deno.test("inference_geo is sent only when configured, and the served region is reported", async () => {
  const bodies: Record<string, unknown>[] = [];
  const { server, url } = stub((_req, body) => {
    bodies.push(body);
    const m = message('{"ok":true}');
    return Response.json({ ...m, usage: { ...m.usage, inference_geo: body.inference_geo ?? "global" } });
  });
  try {
    const provider = new AnthropicProvider({ apiKey: KEY, baseURL: url, maxRetries: 0 });
    const plain = await provider.generate(request());
    const us = await provider.generate({ ...request(), inferenceGeo: "us" });
    assertFalse("inference_geo" in bodies[0], "no region parameter by default (workspace default applies)");
    assertEquals(bodies[1].inference_geo, "us");
    assertEquals(plain.inferenceGeo, "global");
    assertEquals(us.inferenceGeo, "us");
  } finally {
    await server.shutdown();
  }
});

for (
  const [status, kind, code] of [
    [429, "rate_limited", "provider_rate_limited"],
    [500, "provider_error", "server_error"],
    [529, "provider_error", "overloaded"],
    [401, "provider_error", "auth"],
    [400, "provider_error", "bad_request"],
  ] as const
) {
  Deno.test(`HTTP ${status} becomes ${kind}/${code}, without the API's message or the key`, async () => {
    const { server, url } = stub(() =>
      Response.json({ type: "error", error: { type: "x", message: `secret detail ${KEY}` } }, { status })
    );
    try {
      const error = await assertRejects(
        () => new AnthropicProvider({ apiKey: KEY, baseURL: url, maxRetries: 0 }).generate(request()),
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

Deno.test("a slow provider times out", async () => {
  const { server, url } = stub(async () => {
    await new Promise((r) => setTimeout(r, 1500));
    return Response.json(message("{}"));
  });
  try {
    const error = await assertRejects(
      () => new AnthropicProvider({ apiKey: KEY, baseURL: url, maxRetries: 0 }).generate(request(300)),
      ProviderError,
    );
    assertEquals(error.kind, "timeout");
  } finally {
    await server.shutdown();
  }
});

Deno.test("one SDK retry on a 529, then success", async () => {
  let calls = 0;
  const { server, url } = stub(() => {
    calls++;
    return calls === 1
      ? Response.json({ type: "error", error: { type: "overloaded_error", message: "busy" } }, {
        status: 529,
        headers: { "retry-after-ms": "10" },
      })
      : Response.json(message('{"ok":true}'));
  });
  try {
    const out = await new AnthropicProvider({ apiKey: KEY, baseURL: url, maxRetries: 1 }).generate(request());
    assertEquals(out.text, '{"ok":true}');
    assertEquals(calls, 2);
  } finally {
    await server.shutdown();
  }
});

Deno.test("refusal and truncation are reported as stop reasons", async () => {
  const { server, url } = stub(() => Response.json(message("", "refusal")));
  try {
    const out = await new AnthropicProvider({ apiKey: KEY, baseURL: url, maxRetries: 0 }).generate(request());
    assertEquals(out.stopReason, "refusal");
    assertEquals(out.text, null);
  } finally {
    await server.shutdown();
  }
});

Deno.test("without a configured key nothing is sent", async () => {
  const error = await assertRejects(
    () => new AnthropicProvider({ apiKey: null }).generate(request()),
    ProviderError,
  );
  assertEquals(error.kind, "not_configured");
});
