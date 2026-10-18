// Webhook ingestion (Phase 9 C §4, D §1; security review O6): read the raw bytes once and hand them,
// with only the signature headers, to the database. The database verifies and normalises; this
// layer only bounds the request and maps the answer to an HTTP status. It never parses the body.
import type { ProviderAdapter } from "./adapter.ts";
import { DbUnavailable, type IngestDb } from "./db.ts";

export const MAX_WEBHOOK_BYTES = 256 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export type Logger = (event: Record<string, unknown>) => void;

export async function handleWebhook(
  req: Request,
  deps: { adapter: ProviderAdapter; db: IngestDb; log: Logger; connectionHint?: string | null },
): Promise<Response> {
  const { adapter, db, log } = deps;
  const hint = deps.connectionHint ?? null;
  if (hint !== null && !UUID.test(hint)) return new Response(null, { status: 404 });
  if (adapter.perConnectionWebhook && hint === null) return new Response(null, { status: 404 });
  if (req.method === "GET" && adapter.handshake === "meta") return await handshake(req, adapter, db, log);
  if (req.method !== "POST") return new Response(null, { status: 405 });
  if (!(req.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json")) {
    return new Response(null, { status: 415 });
  }
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_WEBHOOK_BYTES) return new Response(null, { status: 413 });
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_WEBHOOK_BYTES) return new Response(null, { status: 413 });

  const headers: Record<string, string> = {};
  for (const name of adapter.webhookHeaders) {
    const value = req.headers.get(name);
    if (value !== null) headers[name] = value.slice(0, 512);
  }
  let result;
  try {
    result = await db.ingestRaw(adapter.provider, hint, raw, headers);
  } catch (error) {
    if (!(error instanceof DbUnavailable)) throw error;
    log({ event: "webhook_store_failed", provider: adapter.provider, code: "db_unavailable" });
    return new Response(null, { status: 503 });
  }
  if (!result.ok) {
    const code = result.error?.code ?? "UNKNOWN";
    // Counted, never stored, no detail returned.
    log({
      event: code === "SIGNATURE_INVALID" ? "webhook_rejected" : "webhook_store_failed",
      provider: adapter.provider,
      code,
    });
    const status = code === "SIGNATURE_INVALID"
      ? 401
      : code === "VALIDATION_FAILED"
      ? 400
      : code === "UNKNOWN_PROVIDER"
      ? 404
      : 503; // NOT_CONFIGURED or a database error: the platform retries; the event id keeps it idempotent
    return new Response(null, { status });
  }
  log({
    event: "webhook_stored",
    provider: adapter.provider,
    duplicate: result.data?.duplicate === true,
    stored: result.data?.stored === true,
  });
  return new Response(null, { status: 200 });
}

/** Meta's subscription check: echo hub.challenge only for the provider's own verify token. */
async function handshake(
  req: Request,
  adapter: ProviderAdapter,
  db: IngestDb,
  log: Logger,
): Promise<Response> {
  const q = new URL(req.url).searchParams;
  const challenge = q.get("hub.challenge") ?? "";
  if (q.get("hub.mode") !== "subscribe" || !/^[A-Za-z0-9_-]{1,128}$/.test(challenge)) {
    return new Response(null, { status: 400 });
  }
  let ok = false;
  try {
    ok = (await db.challenge(adapter.provider, (q.get("hub.verify_token") ?? "").slice(0, 256))).ok;
  } catch (error) {
    if (!(error instanceof DbUnavailable)) throw error;
    return new Response(null, { status: 503 });
  }
  log({ event: ok ? "webhook_handshake_ok" : "webhook_handshake_refused", provider: adapter.provider });
  return ok
    ? new Response(challenge, { status: 200, headers: { "content-type": "text/plain" } })
    : new Response(null, { status: 403 });
}
