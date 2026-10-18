// Webhook ingestion (Phase 9 C §4, D §1): read the raw bytes once, verify them BEFORE parsing,
// store the normalised events, answer quickly. The database resolves the store later from the
// verified account id; the URL's connection hint is only a hint.
import type { ProviderAdapter } from "./adapter.ts";
import type { IngestDb } from "./db.ts";
import { sha256Hex } from "./text.ts";

export const MAX_WEBHOOK_BYTES = 256 * 1024;

export type Logger = (event: Record<string, unknown>) => void;

export async function handleWebhook(
  req: Request,
  deps: { adapter: ProviderAdapter; db: IngestDb; log: Logger; connectionHint?: string | null },
): Promise<Response> {
  const { adapter, db, log } = deps;
  if (req.method !== "POST") return new Response(null, { status: 405 });
  if (!(req.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json")) {
    return new Response(null, { status: 415 });
  }
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_WEBHOOK_BYTES) return new Response(null, { status: 413 });
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_WEBHOOK_BYTES) return new Response(null, { status: 413 });

  const verified = await adapter.verify(raw, req.headers);
  if (!verified.ok) {
    // Counted, never stored, no detail returned.
    log({ event: "webhook_rejected", provider: adapter.provider, reason: verified.reason ?? "signature" });
    return new Response(null, { status: 401 });
  }
  let parsed;
  try {
    parsed = await adapter.parse(raw);
  } catch {
    log({ event: "webhook_unparseable", provider: adapter.provider });
    return new Response(null, { status: 400 });
  }
  if (parsed.events.length === 0) return new Response(null, { status: 200 });
  const result = await db.ingest(
    adapter.provider,
    parsed.externalEventId,
    deps.connectionHint ?? null,
    parsed.events,
    await sha256Hex(raw),
  );
  if (!result.ok) {
    log({ event: "webhook_store_failed", provider: adapter.provider, code: result.error?.code });
    // A 5xx asks the platform to retry later; the event id makes the retry idempotent.
    return new Response(null, { status: result.error?.code === "VALIDATION_FAILED" ? 400 : 503 });
  }
  log({
    event: "webhook_stored",
    provider: adapter.provider,
    duplicate: result.data?.duplicate === true,
    items: parsed.events.length,
  });
  return new Response(null, { status: 200 });
}
