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

/**
 * WhatsApp template lists: refreshed every 6 hours per connected number (the database decides which
 * are due). A failure leaves the stored list untouched; it is retried next cycle.
 */
export async function runTemplateSyncCycle(deps: {
  db: WorkerDb;
  fetchers: Record<string, (wabaId: string, token: string) => Promise<unknown[]>>;
  log: Logger;
}): Promise<{ synced: number; failed: number }> {
  const out = { synced: 0, failed: 0 };
  if (!deps.db.dueTemplateSyncs || !deps.db.storeTemplates) return out;
  const due = await deps.db.dueTemplateSyncs();
  for (const item of due.ok ? due.data?.items ?? [] : []) {
    const fetcher = deps.fetchers[item.provider];
    if (!fetcher || !item.credential) continue;
    try {
      const templates = await fetcher(item.waba_id, item.credential);
      const stored = await deps.db.storeTemplates(item.connection_id, templates);
      if (stored.ok) out.synced++;
      else out.failed++;
    } catch {
      out.failed++;
    }
  }
  if (out.synced || out.failed) deps.log({ event: "template_sync", ...out });
  return out;
}

/**
 * Token refresh (TikTok access tokens live one day): refresh what expires within two hours. A refusal
 * marks the connection "error" (needs_attention) so the seller reconnects; tokens are never logged.
 */
export async function runRefreshCycle(deps: {
  db: WorkerDb;
  refreshers: Record<
    string,
    (refreshToken: string) => Promise<{ accessToken: string; refreshToken: string | null; expiresAt: string }>
  >;
  log: Logger;
}): Promise<{ refreshed: number; failed: number }> {
  const out = { refreshed: 0, failed: 0 };
  if (!deps.db.dueRefreshes || !deps.db.storeRefresh) return out;
  const due = await deps.db.dueRefreshes();
  for (const item of due.ok ? due.data?.items ?? [] : []) {
    const refresh = deps.refreshers[item.provider];
    if (!refresh) continue;
    try {
      const t = await refresh(item.refresh_token);
      await deps.db.storeRefresh(item.connection_id, true, t.accessToken, t.refreshToken, t.expiresAt);
      out.refreshed++;
    } catch {
      await deps.db.storeRefresh(item.connection_id, false, null, null, null);
      out.failed++;
    }
  }
  if (out.refreshed || out.failed) deps.log({ event: "token_refresh", ...out });
  return out;
}
