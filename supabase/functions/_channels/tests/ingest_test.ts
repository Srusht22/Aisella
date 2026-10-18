// The webhook handler's request checks with an in-memory database double (local only). The
// database's own verification and normalisation are covered by pgTAP suite 20 and inbound_kit.ts.
import { assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import { handleWebhook, MAX_WEBHOOK_BYTES } from "../ingest.ts";
import { type ApiResult, DbUnavailable, type IngestDb } from "../db.ts";
import type { ProviderAdapter } from "../adapter.ts";
import { StubProvider } from "../stub_provider.ts";

class Db implements IngestDb {
  calls: { hint: string | null; raw: Uint8Array; headers: Record<string, string> }[] = [];
  answer: ApiResult | Error = { ok: true, data: { stored: true, duplicate: false } };
  ingestRaw(
    _p: string,
    hint: string | null,
    raw: Uint8Array,
    headers: Record<string, string>,
  ): Promise<ApiResult> {
    this.calls.push({ hint, raw, headers });
    return this.answer instanceof Error ? Promise.reject(this.answer) : Promise.resolve(this.answer);
  }
  challenge(_p: string, token: string): Promise<ApiResult> {
    return Promise.resolve(
      token === "right-token" ? { ok: true } : { ok: false, error: { code: "SIGNATURE_INVALID" } },
    );
  }
}

const adapter = new StubProvider({ provider: "stub", baseURL: "http://127.0.0.1:9" });
const perBot: ProviderAdapter = {
  ...adapter,
  provider: "bot",
  perConnectionWebhook: true,
  send: adapter.send,
};
const meta: ProviderAdapter = { ...adapter, provider: "meta", handshake: "meta", send: adapter.send };
const body = new TextEncoder().encode(
  '{"event_id":"e1","entries":[{"account":"a","from":"u","id":"m1","text":"hi"}]}',
);
const post = (headers: Record<string, string> = {}, b: Uint8Array = body) =>
  new Request("http://x", {
    method: "POST",
    body: b.slice(),
    headers: { "content-type": "application/json", ...headers },
  });
const CONN = "0b6e5a4e-6a53-4d36-9d0e-2f3f1d2a8f10";

Deno.test("only POST with JSON is accepted; nothing reaches the database otherwise", async () => {
  const db = new Db();
  assertEquals((await handleWebhook(new Request("http://x"), { adapter, db, log: () => {} })).status, 405);
  const res = await handleWebhook(
    new Request("http://x", { method: "POST", body, headers: { "content-type": "text/plain" } }),
    { adapter, db, log: () => {} },
  );
  assertEquals(res.status, 415);
  assertEquals(db.calls.length, 0);
});

Deno.test("oversized bodies are refused before the database", async () => {
  const db = new Db();
  const res = await handleWebhook(post({}, new Uint8Array(MAX_WEBHOOK_BYTES + 1).fill(32)), {
    adapter,
    db,
    log: () => {},
  });
  assertEquals(res.status, 413);
  assertEquals(db.calls.length, 0);
});

Deno.test("the exact raw bytes and ONLY the signature headers are handed to the database", async () => {
  const db = new Db();
  const res = await handleWebhook(
    post({
      "x-stub-signature": "sha256=ab",
      cookie: "c=1",
      authorization: "Bearer x",
      "x-forwarded-for": "1.2.3.4",
    }),
    { adapter, db, log: () => {} },
  );
  assertEquals(res.status, 200);
  assertEquals(db.calls[0].raw, body);
  assertEquals(db.calls[0].headers, { "x-stub-signature": "sha256=ab" });
});

Deno.test("database answers map to statuses; a refused signature is 401 and logged without detail", async () => {
  const logs: Record<string, unknown>[] = [];
  const cases: [ApiResult | Error, number][] = [
    [{ ok: false, error: { code: "SIGNATURE_INVALID" } }, 401],
    [{ ok: false, error: { code: "VALIDATION_FAILED" } }, 400],
    [{ ok: false, error: { code: "UNKNOWN_PROVIDER" } }, 404],
    [{ ok: false, error: { code: "NOT_CONFIGURED" } }, 503],
    [new DbUnavailable("down"), 503],
  ];
  for (const [answer, status] of cases) {
    const db = new Db();
    db.answer = answer;
    assertEquals((await handleWebhook(post(), { adapter, db, log: (e) => logs.push(e) })).status, status);
  }
  assertFalse(JSON.stringify(logs).includes("hi"), "no body content in logs");
});

Deno.test("per-bot providers need a well-formed connection id in the URL", async () => {
  const db = new Db();
  assertEquals((await handleWebhook(post(), { adapter: perBot, db, log: () => {} })).status, 404);
  assertEquals(
    (await handleWebhook(post(), { adapter: perBot, db, log: () => {}, connectionHint: "../x" })).status,
    404,
  );
  assertEquals(db.calls.length, 0);
  assertEquals(
    (await handleWebhook(post(), { adapter: perBot, db, log: () => {}, connectionHint: CONN })).status,
    200,
  );
  assertEquals(db.calls[0].hint, CONN);
});

Deno.test("the Meta handshake echoes the challenge only for the right token", async () => {
  const db = new Db();
  const get = (token: string, challenge = "1158201444") =>
    handleWebhook(
      new Request(`http://x/?hub.mode=subscribe&hub.verify_token=${token}&hub.challenge=${challenge}`),
      { adapter: meta, db, log: () => {} },
    );
  const ok = await get("right-token");
  assertEquals([ok.status, await ok.text()], [200, "1158201444"]);
  assertEquals((await get("wrong")).status, 403);
  assertEquals((await get("right-token", "<script>")).status, 400, "the echoed challenge is constrained");
  assertEquals(
    (await handleWebhook(new Request("http://x/?hub.mode=subscribe"), { adapter, db, log: () => {} })).status,
    405,
  );
});
