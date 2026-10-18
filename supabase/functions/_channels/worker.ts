// The background send worker (Edge Function channel-worker): one short cycle per call. The database
// picks the due sends fairly (api.channel_due_sends: order per conversation, per-recipient pacing,
// a cap per connection); each is then submitted through the same pipeline as an immediate send
// (claim → re-hash → adapter → report), so retry limits, backoff and "unknown is never resent" hold.
// A cycle stops starting new sends when its time budget is spent; the rest wait for the next cycle.
import type { ProviderAdapter } from "./adapter.ts";
import type { WorkerDb } from "./db.ts";
import type { Logger } from "./ingest.ts";
import { runSend } from "./send.ts";
import { timingSafeEqual } from "./text.ts";

export interface CycleResult {
  due: number;
  attempted: number;
  states: Record<string, number>;
  stoppedForTime: boolean;
}

export async function runWorkerCycle(deps: {
  db: WorkerDb;
  adapters: Record<string, ProviderAdapter>;
  log: Logger;
  limit?: number;
  budgetMs?: number;
  sendTimeoutMs?: number;
  now?: () => number;
}): Promise<CycleResult> {
  const now = deps.now ?? (() => Date.now());
  const started = now();
  const budget = deps.budgetMs ?? 40000;
  const sendTimeout = deps.sendTimeoutMs ?? 15000;
  const due = await deps.db.dueSends(deps.limit ?? 50);
  const ids = due.ok ? due.data?.ids ?? [] : [];
  const result: CycleResult = { due: ids.length, attempted: 0, states: {}, stoppedForTime: false };
  for (const id of ids) {
    // Never start a send that might outlive the cycle: the claim would expire into "unknown".
    if (now() - started + sendTimeout > budget) {
      result.stoppedForTime = true;
      break;
    }
    const out = await runSend(id, {
      db: deps.db,
      adapters: deps.adapters,
      log: deps.log,
      timeoutMs: sendTimeout,
    });
    result.attempted++;
    result.states[out.state] = (result.states[out.state] ?? 0) + 1;
  }
  deps.log({ event: "worker_cycle", ...result, ms: now() - started });
  return result;
}

/** The endpoint: POST with "Authorization: Bearer <CHANNEL_WORKER_SECRET>" from the scheduler. */
export async function handleWorkerRequest(
  req: Request,
  deps: { secret: string; cycle: () => Promise<CycleResult> },
): Promise<Response> {
  if (req.method !== "POST") return new Response(null, { status: 405 });
  const given = (req.headers.get("authorization") ?? "").replace(/^Bearer /, "");
  if (deps.secret.length < 32 || !timingSafeEqual(given, deps.secret)) {
    return new Response(null, { status: 401 });
  }
  const result = await deps.cycle();
  return Response.json({ ok: true, data: result });
}
