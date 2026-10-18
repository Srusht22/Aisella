// The send pipeline with an in-memory database double and the stub provider (local only).
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import { runSend } from "../send.ts";
import { type ApiResult, type ClaimedSend, DbUnavailable, type SenderDb } from "../db.ts";
import { StubProvider } from "../stub_provider.ts";
import { sha256Hex } from "../text.ts";
import { SAMPLE_TEXTS } from "../conformance.ts";
import { startStubServer } from "./stub_server.ts";

class MemorySenderDb implements SenderDb {
  calls: { fn: string; args: unknown[] }[] = [];
  claimed: ClaimedSend;
  lostOnReport = false;
  constructor(text: string, hash: string, credential: string | null = null) {
    this.claimed = {
      send_request_id: "s1",
      provider: "stub",
      account_id: "acct",
      recipient: "cust",
      text,
      text_sha256: hash,
      credential,
      attempt: 1,
    };
  }
  claim(id: string): Promise<ApiResult<ClaimedSend>> {
    this.calls.push({ fn: "claim", args: [id] });
    return Promise.resolve({ ok: true, data: this.claimed });
  }
  complete(id: string, pmid: string, hash: string): Promise<ApiResult> {
    this.calls.push({ fn: "complete", args: [id, pmid, hash] });
    if (this.lostOnReport) return Promise.reject(new DbUnavailable("lost"));
    return Promise.resolve({ ok: true, data: { state: "sent" } });
  }
  fail(id: string, outcome: string, code: string, retry: number | null): Promise<ApiResult> {
    this.calls.push({ fn: "fail", args: [id, outcome, code, retry] });
    return Promise.resolve({
      ok: true,
      data: { state: outcome === "retriable" ? "queued" : outcome === "unknown" ? "unknown" : "failed" },
    });
  }
  state(id: string): Promise<ApiResult> {
    this.calls.push({ fn: "state", args: [id] });
    return Promise.resolve({ ok: true, data: { state: "sending" } });
  }
}

async function setup(text: string, hashOf = text, credential: string | null = null) {
  const server = startStubServer();
  const adapter = new StubProvider({ provider: "stub", baseURL: server.url });
  const db = new MemorySenderDb(text, await sha256Hex(hashOf), credential);
  const logs: Record<string, unknown>[] = [];
  return {
    server,
    db,
    logs,
    run: () => runSend("s1", { db, adapters: { stub: adapter }, log: (e) => logs.push(e), timeoutMs: 400 }),
  };
}

for (const [lang, text] of Object.entries(SAMPLE_TEXTS)) {
  Deno.test(`${lang}: the exact authorized text is submitted and the authorized hash is attested`, async () => {
    const s = await setup(text);
    try {
      const out = await s.run();
      assertEquals(out.state, "sent");
      assertEquals(s.server.textBytes(0), new TextEncoder().encode(text));
      const complete = s.db.calls.find((c) => c.fn === "complete")!;
      assertEquals(complete.args[2], await sha256Hex(text));
    } finally {
      await s.server.close();
    }
  });
}

Deno.test("a text whose hash does not match the authorization is never submitted (TEXT_INTEGRITY)", async () => {
  const s = await setup("tampered text", "the authorized text");
  try {
    const out = await s.run();
    assertEquals([out.state, out.code], ["failed", "text_integrity"]);
    assertEquals(s.server.received.length, 0, "nothing reached the provider");
    assertEquals(s.db.calls.at(-1)!.args.slice(1, 3), ["integrity", "text_integrity"]);
  } finally {
    await s.server.close();
  }
});

Deno.test("a timeout after submission is reported unknown and not retried", async () => {
  const s = await setup("hello");
  s.server.setMode("timeout");
  try {
    const out = await s.run();
    assertEquals(out.state, "unknown");
    assertEquals(s.db.calls.filter((c) => c.fn === "claim").length, 1, "no second claim");
    assertEquals(s.server.received.length, 1, "submitted exactly once");
  } finally {
    await s.server.close();
  }
});

Deno.test("a 429 is retriable with the provider's retry-after; a rejection is permanent", async () => {
  const s = await setup("hello");
  try {
    s.server.setMode("429");
    assertEquals((await s.run()).state, "queued");
    assertEquals(s.db.calls.at(-1)!.args.slice(1), ["retriable", "http_429", 2000]);
    s.server.setMode("window_closed");
    assertEquals((await s.run()).state, "failed");
    assertEquals(s.db.calls.at(-1)!.args.slice(1, 3), ["permanent", "window_closed"]);
  } finally {
    await s.server.close();
  }
});

Deno.test("if the completion report is lost, the state is read back instead of sending again", async () => {
  const s = await setup("hello");
  s.db.lostOnReport = true;
  try {
    const out = await s.run();
    assertEquals(out.state, "sending");
    assertEquals(s.db.calls.map((c) => c.fn), ["claim", "complete", "state"]);
    assertEquals(s.server.received.length, 1);
  } finally {
    await s.server.close();
  }
});

Deno.test("credentials and text never appear in logs", async () => {
  const credential = `cred-${crypto.randomUUID()}`;
  const s = await setup(SAMPLE_TEXTS.ckb, SAMPLE_TEXTS.ckb, credential);
  try {
    await s.run();
    assertEquals(
      s.server.received[0].auth,
      `Bearer ${credential}`,
      "the credential is used for the provider call",
    );
    const logText = JSON.stringify(s.logs);
    assertFalse(logText.includes(credential));
    assertFalse(logText.includes(SAMPLE_TEXTS.ckb.slice(0, 6)));
    assert(logText.includes("send_attempted"));
  } finally {
    await s.server.close();
  }
});

Deno.test("the stub provider refuses any non-loopback address", () => {
  let threw = false;
  try {
    new StubProvider({ provider: "stub", baseURL: "https://api.example.com" });
  } catch {
    threw = true;
  }
  assert(threw);
});
