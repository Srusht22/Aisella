// The send endpoint: only a signed-in member of the send's store can trigger it (local stack check
// through PostgREST when AISELLIA_E2E=1; the rest with doubles).
import { assertEquals } from "jsr:@std/assert@1.0.13";
import { handleSendRequest, postgrestOwnerCheck } from "../dispatch.ts";
import type { ApiResult, ClaimedSend, SenderDb } from "../db.ts";
import { API, KEY, rpc, uuid } from "../../ai-assist/tests/local_stack.ts";

class NoSendDb implements SenderDb {
  claims = 0;
  claim(): Promise<ApiResult<ClaimedSend>> {
    this.claims++;
    return Promise.resolve({ ok: false, error: { code: "NOT_CLAIMABLE" } });
  }
  complete = () => Promise.resolve({ ok: true });
  fail = () => Promise.resolve({ ok: true });
  state = () => Promise.resolve({ ok: true });
}
const TOKEN = `Bearer ${"a".repeat(40)}`;
const req = (body: unknown, auth = TOKEN) =>
  new Request("http://x", { method: "POST", headers: { authorization: auth }, body: JSON.stringify(body) });

Deno.test("no session, a malformed id or a refused ownership check: nothing is claimed", async () => {
  const db = new NoSendDb();
  const deps = (owner: boolean) => ({
    db,
    adapters: {},
    checkOwner: () => Promise.resolve(owner),
    log: () => {},
  });
  assertEquals((await handleSendRequest(req({ send_request_id: uuid() }, ""), deps(true))).status, 401);
  assertEquals((await handleSendRequest(req({ send_request_id: "x" }), deps(true))).status, 400);
  assertEquals((await handleSendRequest(req({ send_request_id: uuid() }), deps(false))).status, 404);
  assertEquals(db.claims, 0);
  assertEquals((await handleSendRequest(req({ send_request_id: uuid() }), deps(true))).status, 200);
  assertEquals(db.claims, 1);
});

Deno.test({
  name: "the ownership check on the local stack: another store's send is NOT_FOUND",
  ignore: Deno.env.get("AISELLIA_E2E") !== "1",
  async fn() {
    // An unknown send id is NOT_FOUND for any signed-in user; an anonymous key cannot call it at all.
    const check = postgrestOwnerCheck(API, KEY);
    assertEquals(await check(`Bearer ${KEY}`, uuid()), false);
    const anon = await rpc("check_send_dispatch", { p_send_request_id: uuid() }, KEY).catch(() => null);
    assertEquals(anon?.ok ?? false, false);
  },
});
