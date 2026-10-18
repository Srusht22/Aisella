// Sending one seller-authorized message (Phase 9 F §4, E §4):
//   claim (the database returns the EXACT authorized text and its hash) → re-hash the text about to
//   be submitted; on any mismatch submit nothing (TEXT_INTEGRITY) → adapter.send → report.
// A timeout or reset after submission is `unknown` and is never retried here or anywhere else.
import type { ProviderAdapter } from "./adapter.ts";
import { type ApiResult, DbUnavailable, type SenderDb } from "./db.ts";
import type { Logger } from "./ingest.ts";
import { sha256Hex } from "./text.ts";

export interface SendOutcome {
  send_request_id: string;
  state: string;
  code?: string;
}

export async function runSend(
  sendRequestId: string,
  deps: { db: SenderDb; adapters: Record<string, ProviderAdapter>; log: Logger; timeoutMs?: number },
): Promise<SendOutcome> {
  const { db, adapters, log } = deps;
  const claim = await db.claim(sendRequestId);
  if (!claim.ok || !claim.data) {
    log({ event: "send_not_claimed", send_request_id: sendRequestId, code: claim.error?.code });
    return { send_request_id: sendRequestId, state: "not_claimed", code: claim.error?.code };
  }
  const c = claim.data;
  const adapter = adapters[c.provider];
  if (!adapter) {
    await report(db.fail(sendRequestId, "permanent", "no_adapter", null), db, sendRequestId, log);
    return { send_request_id: sendRequestId, state: "failed", code: "no_adapter" };
  }
  // The exact-text guarantee: what we submit must hash to what the seller authorized.
  const textToSubmit = c.text;
  if ((await sha256Hex(textToSubmit)) !== c.text_sha256) {
    log({ event: "send_integrity_refused", send_request_id: sendRequestId });
    await report(db.fail(sendRequestId, "integrity", "text_integrity", null), db, sendRequestId, log);
    return { send_request_id: sendRequestId, state: "failed", code: "text_integrity" };
  }
  let result;
  try {
    result = await adapter.send(
      {
        text: textToSubmit,
        textSha256: c.text_sha256,
        recipient: c.recipient,
        accountId: c.account_id,
        senderName: c.sender_name ?? null,
      },
      c.credential,
      { timeoutMs: deps.timeoutMs ?? 15000 },
    );
  } catch {
    // An adapter that throws after it may have sent cannot prove otherwise: unknown.
    result = { kind: "unknown" as const, code: "adapter_error" };
  }
  log({
    event: "send_attempted",
    send_request_id: sendRequestId,
    provider: c.provider,
    outcome: result.kind,
    attempt: c.attempt,
  });
  const stored = result.kind === "sent"
    ? await report(
      db.complete(sendRequestId, result.providerMessageId, c.text_sha256),
      db,
      sendRequestId,
      log,
    )
    : await report(
      db.fail(
        sendRequestId,
        result.kind,
        result.code,
        result.kind === "retriable" ? result.retryAfterMs ?? null : null,
      ),
      db,
      sendRequestId,
      log,
    );
  return {
    send_request_id: sendRequestId,
    state: stored,
    code: result.kind === "sent" ? undefined : result.code,
  };
}

/** Writes the outcome; if the database connection is lost, reads the state back instead of retrying blindly. */
async function report(write: Promise<ApiResult>, db: SenderDb, id: string, log: Logger): Promise<string> {
  try {
    const r = await write;
    return (r.data?.state as string) ?? r.error?.code ?? "error";
  } catch (error) {
    if (!(error instanceof DbUnavailable)) throw error;
    log({ event: "send_report_lost", send_request_id: id });
    try {
      const s = await db.state(id);
      return (s.data?.state as string) ?? "unknown";
    } catch {
      // The claim will expire into `unknown` (internal.channel_expire_send_claims): never resent.
      return "unknown";
    }
  }
}
