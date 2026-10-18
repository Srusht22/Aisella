// FIXTURE-ONLY provider used by tests (Phase 9 MC-2). It imitates the shape of a real messaging
// API (HMAC-signed webhooks, a JSON send endpoint) so the shared pipeline can be proven without
// any real provider. It refuses any non-loopback URL, so it can never reach the internet.
import type {
  NormalizedEvent,
  OutboundText,
  ParsedEvent,
  ProviderAdapter,
  SendResult,
  VerifyResult,
} from "./adapter.ts";
import { hmacSha256Hex, sha256Hex, timingSafeEqual } from "./text.ts";

export const STUB_SIGNATURE_HEADER = "x-stub-signature";

export interface StubEntry {
  type?: "message" | "echo" | "delivery" | "read" | "failed";
  account: string;
  from?: string;
  to?: string;
  id: string;
  at?: string;
  text?: string;
  name?: string;
  attachments?: { kind: string; ref?: string; mime_type?: string; size_bytes?: number }[];
}

export class StubProvider implements ProviderAdapter {
  readonly provider: string;
  readonly #secret: string;
  readonly #base: URL;

  constructor(opts: { provider: string; appSecret: string; baseURL: string }) {
    const base = new URL(opts.baseURL);
    if (!["127.0.0.1", "localhost", "[::1]"].includes(base.hostname)) {
      throw new Error("the stub provider only talks to loopback addresses");
    }
    if (opts.appSecret.length < 16) throw new Error("stub app secret too short");
    this.provider = opts.provider;
    this.#secret = opts.appSecret;
    this.#base = base;
  }

  async verify(raw: Uint8Array, headers: Headers): Promise<VerifyResult> {
    const header = headers.get(STUB_SIGNATURE_HEADER) ?? "";
    if (!header.startsWith("sha256=")) return { ok: false, reason: "missing_signature" };
    const expected = await hmacSha256Hex(this.#secret, raw);
    return timingSafeEqual(header.slice(7), expected) ? { ok: true } : { ok: false, reason: "bad_signature" };
  }

  async parse(raw: Uint8Array): Promise<ParsedEvent> {
    const body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)) as {
      event_id?: string;
      entries: StubEntry[];
    };
    const events: NormalizedEvent[] = body.entries.map((e) => {
      const type = e.type ?? "message";
      if (type === "message" || type === "echo") {
        return {
          kind: type,
          account_id: e.account,
          external_user_id: (type === "echo" ? e.to : e.from) ?? "",
          external_message_id: e.id,
          occurred_at: e.at ?? new Date().toISOString(),
          ...(e.text !== undefined ? { text: e.text } : {}),
          ...(e.name !== undefined ? { display_name: e.name } : {}),
          ...(e.attachments ? { attachments: e.attachments } : {}),
        };
      }
      return {
        kind: type,
        account_id: e.account,
        provider_message_id: e.id,
        provider_event_key: `${type}:${e.id}`,
      };
    });
    return { externalEventId: body.event_id ?? await sha256Hex(raw), events };
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
