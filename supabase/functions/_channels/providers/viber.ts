// Viber through the REST Bot API with the connection's bot auth token.
// Inbound webhooks: one URL per bot (/channel-webhook/viber/<connection id>), verified in the
// database with that bot's token (viber_sha256 / viber_bot).
// Outbound: POST https://chatapi.viber.com/pa/send_message, header X-Viber-Auth-Token, body
// {"receiver", "min_api_version": 1, "sender": {"name"}, "type": "text", "text"} → HTTP 200 with
// {"status": 0, "message_token": <64-bit integer>} or {"status": <code>, "status_message"}.
// message_token exceeds JavaScript's exact integers, so it is read from the raw response text.
// EVIDENCE: assumption until the official pages are read (also Viber's chatbot fees).
import type { OutboundText, ProviderAdapter, SendResult } from "../adapter.ts";
import { retryAfterMs, safeCode } from "../adapter.ts";

export interface ViberOptions {
  /** Default https://chatapi.viber.com (tests point it at a local imitation). */
  baseURL?: string;
  provider?: string;
  fetchFn?: typeof fetch;
}

/** Viber bot auth tokens are three hex groups separated by dashes. */
export const VIBER_TOKEN = /^[0-9a-f]{12,20}-[0-9a-f]{12,20}-[0-9a-f]{12,20}$/;

export class ViberAdapter implements ProviderAdapter {
  readonly provider: string;
  readonly webhookHeaders = ["x-viber-content-signature"] as const;
  readonly perConnectionWebhook = true;
  readonly #base: string;
  readonly #fetch: typeof fetch;

  constructor(opts: ViberOptions = {}) {
    this.provider = opts.provider ?? "viber";
    this.#base = (opts.baseURL ?? "https://chatapi.viber.com").replace(/\/+$/, "");
    this.#fetch = opts.fetchFn ?? fetch;
  }

  async send(msg: OutboundText, credential: string | null, opts: { timeoutMs: number }): Promise<SendResult> {
    if (!credential) return { kind: "permanent", code: "no_credential" };
    if (!VIBER_TOKEN.test(credential)) return { kind: "permanent", code: "token_invalid" };
    // Viber requires a sender name (max 28 characters): the store's connection name.
    const name = (msg.senderName ?? "").trim().slice(0, 28);
    if (!name) return { kind: "permanent", code: "sender_name_missing" };
    let res: Response;
    let raw: string;
    try {
      res = await this.#fetch(`${this.#base}/pa/send_message`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=utf-8", "X-Viber-Auth-Token": credential },
        body: JSON.stringify({
          receiver: msg.recipient,
          min_api_version: 1,
          sender: { name },
          type: "text",
          text: msg.text,
        }),
        signal: AbortSignal.timeout(opts.timeoutMs),
      });
      raw = await res.text();
    } catch (error) {
      if (
        error instanceof TypeError &&
        /connection refused|dns error|failed to lookup/i.test(String(error.message))
      ) {
        return { kind: "retriable", code: "connection_refused" };
      }
      return { kind: "unknown", code: (error as Error)?.name === "TimeoutError" ? "timeout" : "transport" };
    }
    if (res.status === 429) {
      return { kind: "retriable", code: "rate_limited", retryAfterMs: retryAfterMs(res.headers, 5) };
    }
    if (res.status >= 500) return { kind: "retriable", code: safeCode("provider_unavailable", res.status) };
    const status = Number(raw.match(/"status"\s*:\s*(-?[0-9]+)/)?.[1] ?? NaN);
    if (res.status !== 200 || Number.isNaN(status)) {
      return res.status === 200
        ? { kind: "unknown", code: "unreadable_answer" }
        : { kind: "permanent", code: safeCode("http", res.status) };
    }
    if (status === 0) {
      const token = raw.match(/"message_token"\s*:\s*"?([0-9]{1,25})"?/)?.[1];
      return token ? { kind: "sent", providerMessageId: token } : { kind: "unknown", code: "no_message_id" };
    }
    return mapViberStatus(status);
  }
}

/** Viber's status codes (HTTP 200 for all of them). */
export function mapViberStatus(status: number): SendResult {
  if (status === 12) return { kind: "retriable", code: "rate_limited", retryAfterMs: 5000 };
  if (status === 2) return { kind: "permanent", code: "token_invalid" };
  if (status === 5 || status === 6 || status === 11) {
    return { kind: "permanent", code: "recipient_unavailable" };
  }
  if (status === 7 || status === 8 || status === 9 || status === 15) {
    return { kind: "permanent", code: "account_restricted" };
  }
  if (status === 22 || status === 23 || status === 24) return { kind: "permanent", code: "payment_required" };
  if (status === 21) return { kind: "permanent", code: "unsupported_country" };
  return { kind: "permanent", code: safeCode("viber_status", status) };
}
