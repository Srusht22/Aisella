// HTTP entry point: authentication, input validation, error mapping, replays and CORS.
import { assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import { createHandler } from "../handler.ts";
import type { AssistRequest, SellerApi } from "../seller_api.ts";
import type { ApiResult } from "../worker_db.ts";
import { MemoryWorkerDb, response, ScriptedProvider, settings, validOutput } from "./fixtures.ts";

const IDS = {
  store_id: "33333333-3333-4333-8333-333333333333",
  conversation_id: "44444444-4444-4444-8444-444444444444",
  idempotency_key: "55555555-5555-4555-8555-555555555555",
};

class FakeSellerApi implements SellerApi {
  calls: { jwt: string; body: AssistRequest }[] = [];
  constructor(private readonly result: ApiResult<{ run_id: string; status: string; replayed: boolean }>) {}
  requestAssist(jwt: string, body: AssistRequest) {
    this.calls.push({ jwt, body });
    return Promise.resolve(this.result);
  }
}

function setup(result: ApiResult<{ run_id: string; status: string; replayed: boolean }>) {
  const sellerApi = new FakeSellerApi(result);
  const provider = new ScriptedProvider([response(JSON.stringify(validOutput()))]);
  const db = new MemoryWorkerDb();
  const handler = createHandler({
    sellerApi,
    db,
    provider,
    settings,
    allowedOrigins: ["https://app.example"],
    log: () => {},
  });
  return { handler, sellerApi, provider, db };
}

const post = (body: unknown, headers: Record<string, string> = { Authorization: "Bearer jwt.of.seller" }) =>
  new Request("http://localhost/ai-assist", { method: "POST", headers, body: JSON.stringify(body) });

const queued = { ok: true, data: { run_id: "run", status: "queued", replayed: false } };

Deno.test("no token, no run", async () => {
  const { handler, sellerApi } = setup(queued);
  const res = await handler(post(IDS, {}));
  assertEquals(res.status, 401);
  assertEquals(sellerApi.calls.length, 0);
});

Deno.test("invalid input is refused before anything is called", async () => {
  const { handler, sellerApi } = setup(queued);
  const res = await handler(post({ ...IDS, store_id: "not-a-uuid", mode: "approve" }));
  assertEquals(res.status, 422);
  assertEquals((await res.json()).error.details.fields, { store_id: "invalid", mode: "invalid" });
  assertEquals(sellerApi.calls.length, 0);
});

Deno.test("only POST", async () => {
  const { handler } = setup(queued);
  assertEquals((await handler(new Request("http://localhost/ai-assist"))).status, 405);
});

Deno.test("the seller's JWT is forwarded as is; a queued run is processed", async () => {
  const { handler, sellerApi, provider } = setup(queued);
  const res = await handler(post({ ...IDS, mode: "draft" }));
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.data.status, "succeeded");
  assertEquals(sellerApi.calls[0].jwt, "jwt.of.seller");
  assertEquals(sellerApi.calls[0].body.mode, "draft");
  assertEquals(provider.requests.length, 1);
});

for (
  const [code, status] of [["AI_DISABLED", 409], ["NOT_FOUND", 404], ["RATE_LIMITED", 429], [
    "UNAUTHENTICATED",
    401,
  ]] as const
) {
  Deno.test(`database refusal ${code} is HTTP ${status} and no model is called`, async () => {
    const { handler, provider } = setup({
      ok: false,
      error: { code, details: code === "RATE_LIMITED" ? { retry_after_seconds: 600 } : {} },
    });
    const res = await handler(post(IDS));
    assertEquals(res.status, status);
    assertEquals((await res.json()).error.code, code);
    if (code === "RATE_LIMITED") assertEquals(res.headers.get("Retry-After"), "600");
    assertEquals(provider.requests.length, 0);
  });
}

Deno.test("a replay of a finished run calls nothing", async () => {
  const { handler, provider, db } = setup({
    ok: true,
    data: { run_id: "run", status: "succeeded", replayed: true },
  });
  const res = await handler(post(IDS));
  assertEquals((await res.json()).data, { run_id: "run", status: "succeeded", replayed: true });
  assertEquals(provider.requests.length, 0);
  assertEquals(db.calls.length, 0);
});

Deno.test("CORS only for configured origins", async () => {
  const { handler } = setup(queued);
  const ok = await handler(
    new Request("http://x", { method: "OPTIONS", headers: { Origin: "https://app.example" } }),
  );
  assertEquals(ok.headers.get("Access-Control-Allow-Origin"), "https://app.example");
  const no = await handler(
    new Request("http://x", { method: "OPTIONS", headers: { Origin: "https://evil.example" } }),
  );
  assertFalse(no.headers.has("Access-Control-Allow-Origin"));
});

Deno.test("an oversized body is refused", async () => {
  const { handler } = setup(queued);
  const res = await handler(post({ ...IDS, padding: "x".repeat(5000) }));
  assertEquals(res.status, 413);
});
