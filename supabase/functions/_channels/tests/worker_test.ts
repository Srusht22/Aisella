// The background send worker: the endpoint's secret, the time budget, and a local end to end
// (AISELLIA_E2E=1): fair selection from the database, retries after backoff, order kept per
// conversation, unknown never resent.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import postgres from "postgres";
import type { ApiResult, ClaimedSend, WorkerDb } from "../db.ts";
import { PostgresSenderDb } from "../db.ts";
import { StubProvider } from "../stub_provider.ts";
import { handleWorkerRequest, runWorkerCycle } from "../worker.ts";
import { startStubServer } from "./stub_server.ts";
import { ADMIN_DB, assertLocal, b64, createSeller, rpc, uuid } from "../../ai-assist/tests/local_stack.ts";

const SECRET = "worker-secret-0123456789-0123456789";

Deno.test("the worker endpoint runs a cycle only for the scheduler's secret", async () => {
  let cycles = 0;
  const cycle = () => {
    cycles++;
    return Promise.resolve({ due: 0, attempted: 0, states: {}, stoppedForTime: false });
  };
  const call = (auth?: string, method = "POST") =>
    handleWorkerRequest(new Request("http://x", { method, headers: auth ? { authorization: auth } : {} }), {
      secret: SECRET,
      cycle,
    });
  assertEquals((await call()).status, 401);
  assertEquals((await call("Bearer wrong")).status, 401);
  assertEquals((await call(`Bearer ${SECRET}`, "GET")).status, 405);
  assertEquals(cycles, 0);
  assertEquals((await call(`Bearer ${SECRET}`)).status, 200);
  assertEquals(cycles, 1);
  const weak = await handleWorkerRequest(
    new Request("http://x", { method: "POST", headers: { authorization: "Bearer short" } }),
    {
      secret: "short",
      cycle,
    },
  );
  assertEquals(weak.status, 401, "a short secret is never accepted");
});

class FakeDb implements WorkerDb {
  claims: string[] = [];
  constructor(private ids: string[]) {}
  dueSends(): Promise<ApiResult<{ ids: string[] }>> {
    return Promise.resolve({ ok: true, data: { ids: this.ids } });
  }
  claim(id: string): Promise<ApiResult<ClaimedSend>> {
    this.claims.push(id);
    return Promise.resolve({ ok: false, error: { code: "SEND_NOT_CLAIMABLE" } });
  }
  complete = () => Promise.resolve({ ok: true });
  fail = () => Promise.resolve({ ok: true });
  state = () => Promise.resolve({ ok: true });
}

Deno.test("a cycle never starts a send that could outlive its time budget", async () => {
  let t = 0;
  const db = new FakeDb(["a", "b", "c"]);
  const out = await runWorkerCycle({
    db,
    adapters: {},
    log: () => {},
    budgetMs: 20000,
    sendTimeoutMs: 15000,
    now: () => (t += 3000),
  });
  assert(out.stoppedForTime);
  assert(
    db.claims.length < 3,
    "the remaining sends wait for the next cycle (their claims would expire into unknown)",
  );
});

Deno.test({
  name:
    "worker end to end on the local stack: retry after backoff, order per conversation, unknown never resent",
  ignore: Deno.env.get("AISELLIA_E2E") !== "1",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    assertLocal();
    const admin = postgres(ADMIN_DB, { max: 1, onnotice: () => {} });
    const pw = b64(crypto.getRandomValues(new Uint8Array(24)));
    const provider = `t_worker_${uuid().slice(0, 6)}`;
    const server = startStubServer();
    try {
      await admin.unsafe(`alter role aisellia_channel_sender password '${pw}'`);
      const db = new PostgresSenderDb(
        `postgresql://aisellia_channel_sender:${encodeURIComponent(pw)}@127.0.0.1:54322/postgres`,
      );
      const adapters = { [provider]: new StubProvider({ provider, baseURL: server.url }) };
      await admin`insert into app.providers (id, display_name, status, webhook_scheme, payload_format)
                  values (${provider}, 'Worker e2e', 'pilot', 'stub_sha256', 'aisellia_stub')`;
      await admin`insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
                  (${provider}, 'outbound_text', 'true', 'verified', 'https://fixture.invalid', current_date),
                  (${provider}, 'reply_window_hours', 'null', 'verified', 'https://fixture.invalid', current_date)`;
      const seller = await createSeller(admin, {
        tag: "worker",
        storeName: "Worker Shop",
        zones: [],
        products: [],
      });
      const [conn] =
        await admin`insert into app.connections (store_id, provider_id, external_account_id, display_name, state, connected_at)
                                 values (${seller.store}, ${provider}, ${
          "acct-" + uuid()
        }, 'Shop', 'connected', now()) returning *`;
      const events = admin.json([
        {
          kind: "message",
          account_id: conn.external_account_id,
          external_user_id: "u-1",
          external_message_id: uuid(),
          text: "hi",
        },
      ]);
      await admin`select internal.channel_store_events(${provider}, ${
        "ev-" + uuid()
      }, null, ${events}, repeat('a', 64))`;
      await admin`select internal.channel_process_batch()`;
      const [conv] = await admin`select id from app.conversations where connection_id = ${conn.id}`;
      const send = async (text: string) =>
        (await rpc("send_message", {
          p_store_id: seller.store,
          p_conversation_id: conv.id,
          p_text: text,
          p_suggestion_id: null,
          p_kind: "reply",
          p_order_id: null,
          p_idempotency_key: uuid(),
        }, seller.token)).data.send_request_id as string;
      const first = await send("first reply");
      const second = await send("second reply");
      const cycle = () =>
        runWorkerCycle({ db, adapters, log: () => {}, sendTimeoutMs: 400, budgetMs: 10000 });
      const state = async (id: string) =>
        (await admin`select state from app.send_requests where id = ${id}`)[0].state;

      server.setMode("429");
      await cycle();
      assertEquals(
        [await state(first), await state(second)],
        ["queued", "queued"],
        "rate limited: back to the queue; the second waits",
      );
      assertEquals(server.received.length, 1, "only the first was attempted");
      await admin`update app.send_requests set next_attempt_at = now() - interval '1 second' where id = ${first}`;
      server.setMode("ok");
      await cycle();
      await cycle();
      assertEquals([await state(first), await state(second)], ["sent", "sent"]);
      const texts = server.received.slice(1).map((_, i) => new TextDecoder().decode(server.textBytes(i + 1)));
      assertEquals(texts, ["first reply", "second reply"], "delivered in order");

      const third = await send("third reply");
      server.setMode("timeout");
      await cycle();
      assertEquals(await state(third), "unknown");
      server.setMode("ok");
      const before = server.received.length;
      await cycle();
      assertEquals(server.received.length, before, "an unknown outcome is never resent");
      assertFalse((await cycle()).due > 0);
    } finally {
      await admin.unsafe("alter role aisellia_channel_sender password null").catch(() => {});
      await admin`update app.providers set status = 'suspended' where id = ${provider}`.catch(() => {});
      await admin.end();
      await server.close();
    }
  },
});
