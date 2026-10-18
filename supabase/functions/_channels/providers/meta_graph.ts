// Sending through Meta's Graph API (Instagram, Messenger, WhatsApp Cloud API share the transport and
// the error envelope {"error": {"code", "error_subcode", "type", "message", "fbtrace_id"}}).
//
// EVIDENCE: endpoint shapes and error codes follow Meta's public references as known on 2026-10-18;
// the official pages could not be read from this environment. Unknown codes fall back to the HTTP
// status, so an unexpected answer is never mapped to "sent" and never retried blindly.
import { isSendResult, postJson, retryAfterMs, safeCode, type SendResult } from "../adapter.ts";

export interface GraphOptions {
  /** Default https://graph.facebook.com (tests point it at a local imitation). */
  baseURL?: string;
  /** Graph API version, e.g. v21.0 (META_GRAPH_VERSION). */
  version?: string;
  fetchFn?: typeof fetch;
}

export const DEFAULT_GRAPH_VERSION = "v21.0";

export function graphUrl(opts: GraphOptions, path: string): string {
  const base = (opts.baseURL ?? "https://graph.facebook.com").replace(/\/+$/, "");
  const version = opts.version ?? DEFAULT_GRAPH_VERSION;
  if (!/^v[0-9]{1,2}\.[0-9]$/.test(version)) throw new Error("invalid Graph API version");
  return `${base}/${version}/${path}`;
}

/** Rate-limit codes (application, user, page, account and pair limits). */
const RATE_LIMITED = new Set([4, 17, 32, 613, 80001, 80002, 80006, 130429, 131048, 131056]);
/** Codes that mean "temporarily unavailable, nothing was sent". */
const TRANSIENT = new Set([1, 2, 131000, 131016]);

export function mapGraphError(status: number, headers: Headers, body: Record<string, unknown>): SendResult {
  const err = (body.error ?? {}) as { code?: number; error_subcode?: number };
  const code = typeof err.code === "number" ? err.code : null;
  const sub = typeof err.error_subcode === "number" ? err.error_subcode : null;
  if (status === 429 || (code !== null && RATE_LIMITED.has(code))) {
    return {
      kind: "retriable",
      code: safeCode("rate_limited", code ?? status),
      retryAfterMs: retryAfterMs(headers, 60),
    };
  }
  if (status >= 500 || (code !== null && TRANSIENT.has(code))) {
    return { kind: "retriable", code: safeCode("provider_unavailable", code ?? status) };
  }
  // Messenger Platform: outside the 24-hour window (10 / 2018278); WhatsApp: re-engagement (131047).
  if ((code === 10 && sub === 2018278) || code === 131047) {
    return { kind: "permanent", code: "window_closed" };
  }
  if (code === 190 || status === 401) return { kind: "permanent", code: "token_invalid" };
  // The person cannot be reached (blocked the page, deleted the account, not a WhatsApp user…).
  if (code === 551 || sub === 1545041 || code === 131026 || code === 131030 || status === 403) {
    return { kind: "permanent", code: "recipient_unavailable" };
  }
  if (code === 10 || code === 200 || code === 230 || code === 3 || code === 131005) {
    return { kind: "permanent", code: "permission_missing" };
  }
  // The business account is restricted or locked (policy enforcement): nothing will go through.
  if (code === 368 || code === 131031) return { kind: "permanent", code: "account_restricted" };
  if (code === 100) return { kind: "permanent", code: safeCode("invalid_request", sub ?? code) };
  return { kind: "permanent", code: safeCode("graph_error", code ?? status) };
}

/** POST a JSON send request with the access token as a Bearer header (never in the URL). */
export async function graphSend(
  url: string,
  body: unknown,
  token: string | null,
  timeoutMs: number,
  pickId: (json: Record<string, unknown>) => unknown,
  fetchFn?: typeof fetch,
): Promise<SendResult> {
  if (!token) return { kind: "permanent", code: "no_credential" };
  const res = await postJson(url, body, {
    timeoutMs,
    headers: { Authorization: `Bearer ${token}` },
    fetchFn,
  });
  if (isSendResult(res)) return res;
  if (res.status >= 200 && res.status < 300) {
    const id = pickId(res.json);
    // Accepted without an id: we cannot prove what happened, so it is unknown (never resent).
    return typeof id === "string" && id.length > 0 && id.length <= 200
      ? { kind: "sent", providerMessageId: id }
      : { kind: "unknown", code: "no_message_id" };
  }
  return mapGraphError(res.status, res.headers, res.json);
}
