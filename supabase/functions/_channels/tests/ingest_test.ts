// The webhook handler's request checks (local only, in-memory database double).
import { assertEquals } from "jsr:@std/assert@1.0.13";
import { handleWebhook, MAX_WEBHOOK_BYTES } from "../ingest.ts";
import type { ApiResult, IngestDb } from "../db.ts";
import type { NormalizedEvent } from "../adapter.ts";
import { signStub, StubProvider } from "../stub_provider.ts";
import { randomSecret } from "./stub_fixture.ts";

class Db implements IngestDb {
  calls: { hint: string | null; events: NormalizedEvent[]; sha: string }[] = [];
  ingest(
    _p: string,
    _id: string,
    hint: string | null,
    events: NormalizedEvent[],
    sha: string,
  ): Promise<ApiResult> {
    this.calls.push({ hint, events, sha });
    return Promise.resolve({ ok: true, data: { stored: true, duplicate: false } });
  }
}

const secret = randomSecret();
const adapter = new StubProvider({ provider: "stub", appSecret: secret, baseURL: "http://127.0.0.1:9" });
const body = new TextEncoder().encode(
  '{"event_id":"e1","entries":[{"account":"a","from":"u","id":"m1","text":"hi"}]}',
);

Deno.test("only POST with JSON is accepted", async () => {
  const db = new Db();
  assertEquals(
    (await handleWebhook(new Request("http://x", { method: "GET" }), { adapter, db, log: () => {} })).status,
    405,
  );
  const res = await handleWebhook(
    new Request("http://x", { method: "POST", body, headers: { "content-type": "text/plain" } }),
    { adapter, db, log: () => {} },
  );
  assertEquals(res.status, 415);
  assertEquals(db.calls.length, 0);
});

Deno.test("oversized bodies are refused before verification", async () => {
  const db = new Db();
  const big = new Uint8Array(MAX_WEBHOOK_BYTES + 1).fill(32);
  const res = await handleWebhook(
    new Request("http://x", { method: "POST", body: big, headers: await signStub(secret, big) }),
    { adapter, db, log: () => {} },
  );
  assertEquals(res.status, 413);
  assertEquals(db.calls.length, 0);
});

Deno.test("a verified event is stored with the URL hint (only a hint) and the raw body's hash", async () => {
  const db = new Db();
  const res = await handleWebhook(
    new Request("http://x", { method: "POST", body, headers: await signStub(secret, body) }),
    { adapter, db, log: () => {}, connectionHint: "conn-1" },
  );
  assertEquals(res.status, 200);
  assertEquals(db.calls[0].hint, "conn-1");
  assertEquals(db.calls[0].events[0].kind, "message");
  assertEquals(db.calls[0].sha.length, 64);
});
