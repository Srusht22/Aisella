// FIXTURE-ONLY provider used by tests (Phase 9 MC-2). It imitates the shape of a real messaging
// API (HMAC-signed webhooks, a JSON send endpoint) so the shared pipeline can be proven without
// any real provider. It refuses any non-loopback URL, so it can never reach the internet.
import type { OutboundText, ProviderAdapter, SendResult } from "./adapter.ts";
import { hmacSha256Hex } from "./text.ts";

export const STUB_SIGNATURE_HEADER = "x-stub-signature";

/**
 * Webhook body (normalised in the database by app.channel_normalize_aisellia_stub):
 * {"event_id": "…", "entries": [{"type": "message"|"echo"|"delivery"|"read"|"failed", "account": "…",
 *   "from"|"to": "…", "id": "…", "at": "…", "text": "…", "name": "…", "sent_by_app": true}]}
 * signed with x-stub-signature: sha256=<hex HMAC of the raw body with the app secret>.
 */
export class StubProvider implements ProviderAdapter {
  readonly provider: string;
  readonly webhookHeaders = [STUB_SIGNATURE_HEADER] as const;
  readonly perConnectionWebhook = false;
  readonly #base: URL;

  constructor(opts: { provider: string; baseURL: string }) {
    const base = new URL(opts.baseURL);
    if (!["127.0.0.1", "localhost", "[::1]"].includes(base.hostname)) {
      throw new Error("the stub provider only talks to loopback addresses");
    }
    this.provider = opts.provider;
    this.#base = base;
  }

  async send(msg: OutboundText, credential: string | null, opts: { timeoutMs: number }): Promise<SendResult> {
    let res: Response;
    try {
      res = await fetch(new URL("/send", this.#base), {
        method: "POST",
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          ...(credential ? { Authorization: `Bearer ${credential}` } : {}),
        },
        // The text goes out exactly as authorized.
        body: JSON.stringify({ account: msg.accountId, to: msg.recipient, text: msg.text }),
        signal: AbortSignal.timeout(opts.timeoutMs),
      });
    } catch (error) {
      if (error instanceof TypeError && /connection refused/i.test(String(error.message))) {
        return { kind: "retriable", code: "connection_refused" }; // nothing left our side
      }
      return { kind: "unknown", code: (error as Error)?.name === "TimeoutError" ? "timeout" : "transport" };
    }
    const body = await res.json().catch(() => ({})) as { id?: string; error?: string };
    if (res.ok && body.id) return { kind: "sent", providerMessageId: body.id };
    if (res.status === 429) {
      return {
        kind: "retriable",
        code: "http_429",
        retryAfterMs: Number(res.headers.get("retry-after") ?? "1") * 1000,
      };
    }
    if (res.status >= 500) return { kind: "retriable", code: `http_${res.status}` };
    if (res.ok) return { kind: "unknown", code: "no_message_id" };
    return {
      kind: "permanent",
      code: /^[a-z0-9_]{1,64}$/.test(body.error ?? "") ? body.error! : `http_${res.status}`,
    };
  }
}

/** Builds a signed stub webhook request body (tests only). */
export async function signStub(appSecret: string, raw: Uint8Array): Promise<Headers> {
  return new Headers({
    "content-type": "application/json",
    [STUB_SIGNATURE_HEADER]: `sha256=${await hmacSha256Hex(appSecret, raw)}`,
  });
}
