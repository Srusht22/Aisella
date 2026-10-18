// The all-stores daily spending cap under concurrency (local stack, AISELLIA_E2E=1). Two sellers of
// different stores ask for the assistant at the same moment while the total cap has room for only
// one more run: exactly one may be accepted. Each store's own cap was already serialised by its
// store row; the total cap needs one lock shared by every store (Phase 10 finding).
import { assert, assertEquals } from "jsr:@std/assert@1.0.13";
import postgres from "postgres";
import { ADMIN_DB, assertLocal, createConversation, createSeller, type Seller, uuid } from "./local_stack.ts";

const claims = (s: Seller) => JSON.stringify({ sub: s.user, role: "authenticated", amr: [] });

async function requestAs(sql: postgres.Sql | postgres.TransactionSql, s: Seller, conv: string) {
  await sql`select set_config('request.jwt.claims', ${claims(s)}, true)`;
  await sql.unsafe("set local role authenticated");
  const [row] = await sql`select api.request_ai_assist(${s.store}, ${conv}, 'reply', ${uuid()}) as r`;
  return row.r as {
    ok: boolean;
    data?: { run_id: string };
    error?: { code: string; details?: { scope?: string } };
  };
}

Deno.test({
  name: "two stores at once cannot together exceed the all-stores daily cap",
  ignore: Deno.env.get("AISELLIA_E2E") !== "1",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    assertLocal();
    const admin = postgres(ADMIN_DB, { max: 1, onnotice: () => {} });
    const a = postgres(ADMIN_DB, { max: 1, onnotice: () => {} });
    const b = postgres(ADMIN_DB, { max: 1, onnotice: () => {} });
    const [{ value: oldCap }] =
      await admin`select value from app.ai_limits where name = 'assist_daily_cost_micro_usd_total'`;
    const runIds: string[] = [];
    try {
      const spec = { zones: [], products: [] };
      const sa = await createSeller(admin, { tag: "race-a", storeName: "Race A", ...spec });
      const sb = await createSeller(admin, { tag: "race-b", storeName: "Race B", ...spec });
      const ca = await createConversation(sa, [{ direction: "in", body: "Do you have the abaya?" }]);
      const cb = await createConversation(sb, [{ direction: "in", body: "Do you have the abaya?" }]);
      // Room for exactly one more reserve across all stores.
      const [{ spent, reserve }] = await admin`select app.ai_spent(null) as spent,
                                                     app.ai_limit('assist_run_reserve_micro_usd') as reserve`;
      await admin`update app.ai_limits set value = ${Number(spent) + Number(reserve) * 1.5}
                   where name = 'assist_daily_cost_micro_usd_total'`;

      let releaseA!: () => void;
      const holdA = new Promise<void>((r) => (releaseA = r));
      let aAccepted!: (v: Awaited<ReturnType<typeof requestAs>>) => void;
      const aResult = new Promise<Awaited<ReturnType<typeof requestAs>>>((r) => (aAccepted = r));
      // Seller A's request is accepted but its transaction has not committed yet.
      const txA = a.begin(async (sql) => {
        aAccepted(await requestAs(sql, sa, ca));
        await holdA;
      });
      const ra = await aResult;
      assert(ra.ok, "the first request fits the cap");
      runIds.push(ra.data!.run_id);

      let bSettled = false;
      const txB = b.begin(async (sql) => {
        await sql`set local lock_timeout = '20s'`;
        return await requestAs(sql, sb, cb);
      }).finally(() => (bSettled = true));
      await new Promise((r) => setTimeout(r, 700));
      const bWaited = !bSettled;
      releaseA();
      await txA;
      const rb = await txB;
      if (rb.ok) runIds.push(rb.data!.run_id);

      assert(bWaited, "the second store's request waits for the first to be counted");
      assertEquals(rb.ok, false, "together they would exceed the cap: the second is refused");
      assertEquals(rb.error?.code, "RATE_LIMITED");
      assertEquals(rb.error?.details?.scope, "budget_total");
    } finally {
      await admin`update app.ai_limits set value = ${oldCap} where name = 'assist_daily_cost_micro_usd_total'`;
      // Never leave in-flight runs behind: they would count at the reserve for 24 hours.
      if (runIds.length) {
        await admin`update app.ai_runs set status = 'expired', error_code = 'not_claimed', finished_at = now()
                     where id = any(${runIds}::uuid[])`;
      }
      await Promise.all([admin.end(), a.end(), b.end()]);
    }
  },
});
