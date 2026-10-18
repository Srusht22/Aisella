// TikTok Business Messaging. BLOCKED for real use: the API needs TikTok's partner approval and its
// direct-message endpoints could not be verified (see the migration's note). Webhooks are verified
// in the database (tiktok_sha256: "t.body" HMAC with the client secret, 5-minute window).
//
// Sending is refused unless an operator configures the endpoint path explicitly (TIKTOK_SEND_PATH,
// e.g. after reading the official reference), so a guessed URL is never called. When configured it
// posts {"business_id", "conversation_id", "message": {"type": "text", "text"}} with the
// connection's access token as a Bearer header, and expects {"code": 0, "data": {"message_id"}}
// (TikTok's usual envelope; UNRESOLVED). Error mapping follows that envelope and HTTP statuses.
import { isSendResult, postJson, retryAfterMs, safeCode } from "../adapter.ts";
import type { OutboundText, ProviderAdapter, SendResult } from "../adapter.ts";

export interface TikTokOptions {
  /** Default https://business-api.tiktok.com (UNRESOLVED; tests point it at a local imitation). */
  baseURL?: string;
  /** The send endpoint path; without it nothing is ever sent. */
  sendPath?: string | null;
  provider?: string;
  fetchFn?: typeof fetch;
}

export class TikTokAdapter implements ProviderAdapter {
  readonly provider: string;
  readonly webhookHeaders = ["tiktok-signature"] as const;
  readonly perConnectionWebhook = false;
  readonly #base: string;
  readonly #path: string | null;
  readonly #fetch?: typeof fetch;

  constructor(opts: TikTokOptions = {}) {
    this.provider = opts.provider ?? "tiktok";
    this.#base = (opts.baseURL ?? "https://business-api.tiktok.com").replace(/\/+$/, "");
    const path = opts.sendPath?.trim() ?? "";
    this.#path = /^\/[A-Za-z0-9_./-]{1,200}$/.test(path) && !path.includes("..") ? path : null;
    this.#fetch = opts.fetchFn;
  }

  async send(msg: OutboundText, credential: string | null, opts: { timeoutMs: number }): Promise<SendResult> {
    if (!this.#path) return { kind: "permanent", code: "provider_unresolved" };
    if (!credential) return { kind: "permanent", code: "no_credential" };
    const res = await postJson(
      `${this.#base}${this.#path}`,
      {
        business_id: msg.accountId,
        recipient_open_id: msg.recipient,
        message: { type: "text", text: msg.text },
      },
      { timeoutMs: opts.timeoutMs, headers: { Authorization: `Bearer ${credential}` }, fetchFn: this.#fetch },
    );
    if (isSendResult(res)) return res;
    const body = res.json as { code?: number; data?: { message_id?: unknown } };
    if (res.status === 429) {
      return { kind: "retriable", code: "rate_limited", retryAfterMs: retryAfterMs(res.headers, 10) };
    }
    if (res.status >= 500) return { kind: "retriable", code: safeCode("provider_unavailable", res.status) };
    if (res.status === 401) return { kind: "permanent", code: "token_invalid" };
    if (res.status === 200 && body.code === 0) {
      const id = body.data?.message_id;
      return typeof id === "string" && id.length > 0 && id.length <= 200
        ? { kind: "sent", providerMessageId: id }
        : { kind: "unknown", code: "no_message_id" };
    }
    if (res.status === 403) return { kind: "permanent", code: "recipient_unavailable" };
    return { kind: "permanent", code: safeCode("tiktok_error", body.code ?? res.status) };
  }
}
