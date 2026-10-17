// HTTP entry: POST { store_id, conversation_id, mode, idempotency_key } with the seller's JWT.
// Returns { ok, data: { run_id, status, ... } } or { ok: false, error: { code } }. The app then reloads
// the conversation; nothing in the response is a customer message.
import type { AiProvider } from "./provider.ts";
import { type Logger, type PipelineSettings, runAssist } from "./pipeline.ts";
import type { SellerApi } from "./seller_api.ts";
import type { WorkerDb } from "./worker_db.ts";

export interface HandlerDeps {
  sellerApi: SellerApi;
  db: WorkerDb;
  provider: AiProvider;
  settings: PipelineSettings;
  allowedOrigins: string[];
  log: Logger;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_BODY = 2048;

const STATUS_FOR: Record<string, number> = {
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  VALIDATION_FAILED: 422,
  IDEMPOTENCY_KEY_REUSED: 409,
  AI_DISABLED: 409,
  AI_PAUSED: 409,
  AI_BUSY: 409,
  NOTHING_TO_ANSWER: 409,
  RATE_LIMITED: 429,
};

export function createHandler(deps: HandlerDeps): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    const origin = req.headers.get("Origin");
    const cors: Record<string, string> = origin && deps.allowedOrigins.includes(origin)
      ? {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        Vary: "Origin",
      }
      : {};
    const json = (status: number, body: unknown, extra: Record<string, string> = {}) =>
      new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...cors, ...extra },
      });
    const fail = (status: number, code: string, details: Record<string, unknown> = {}) =>
      json(status, { ok: false, error: { code, details } });

    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (req.method !== "POST") return fail(405, "METHOD_NOT_ALLOWED");

    const auth = req.headers.get("Authorization") ?? "";
    const jwt = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
    if (!jwt || jwt.length > 4096) return fail(401, "UNAUTHENTICATED");

    const raw = await req.text();
    if (raw.length > MAX_BODY) return fail(413, "VALIDATION_FAILED", { fields: { body: "too_large" } });
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(raw);
    } catch {
      return fail(400, "VALIDATION_FAILED", { fields: { body: "invalid" } });
    }
    const fields: Record<string, string> = {};
    for (const k of ["store_id", "conversation_id", "idempotency_key"]) {
      if (typeof body?.[k] !== "string" || !UUID.test(body[k] as string)) fields[k] = "invalid";
    }
    const rawMode = body?.mode ?? "reply";
    if (rawMode !== "reply" && rawMode !== "draft") fields.mode = "invalid";
    const mode: "reply" | "draft" = rawMode === "draft" ? "draft" : "reply";
    if (Object.keys(fields).length > 0) return fail(422, "VALIDATION_FAILED", { fields });

    const correlationId = crypto.randomUUID();
    const queued = await deps.sellerApi.requestAssist(jwt, {
      store_id: body.store_id as string,
      conversation_id: body.conversation_id as string,
      mode,
      idempotency_key: body.idempotency_key as string,
    });
    if (!queued.ok) {
      const code = queued.error?.code ?? "INTERNAL";
      const retryAfter = queued.error?.details?.retry_after_seconds;
      return json(STATUS_FOR[code] ?? 500, {
        ok: false,
        error: { code, details: queued.error?.details ?? {} },
      }, typeof retryAfter === "number" ? { "Retry-After": String(retryAfter) } : {});
    }
    const run = queued.data!;
    // A replay of a run that already finished: report it, call nothing.
    if (run.replayed && run.status !== "queued") {
      return json(200, { ok: true, data: { run_id: run.run_id, status: run.status, replayed: true } });
    }
    try {
      const outcome = await runAssist(run.run_id, {
        db: deps.db,
        provider: deps.provider,
        settings: deps.settings,
        log: deps.log,
        correlationId,
      });
      return json(200, { ok: true, data: { ...outcome, correlation_id: correlationId } });
    } catch (_error) {
      deps.log({ event: "run_crashed", run_id: run.run_id, correlation_id: correlationId });
      return fail(503, "AI_UNAVAILABLE", { run_id: run.run_id, correlation_id: correlationId });
    }
  };
}
