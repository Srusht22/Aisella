// The shared provider-adapter interface (Phase 9 L §3). One module per provider implements it.
//
// Inbound: since the security review (O6) an adapter neither verifies nor parses webhooks. The
// Edge Function hands the RAW bytes and the headers listed here to the database
// (api.channel_ingest_raw), which verifies the provider signature with secrets only it can read and
// normalises the body itself (app.channel_normalize_<format>). A leaked ingest credential therefore
// cannot forge events. Outbound: an adapter submits the exact authorized text and maps the result.

export interface OutboundText {
  /** The exact text the seller authorized. Adapters must submit it unmodified. */
  text: string;
  textSha256: string;
  recipient: string;
  accountId: string;
  /** The connection's display name, for providers that require a sender name (Viber). */
  senderName?: string | null;
  /**
   * An approved WhatsApp template (outside the customer-service window). `text` is then the template
   * rendered with these parameters; the adapter submits the template, not free-form text.
   */
  template?: OutboundTemplate | null;
}

export interface OutboundTemplate {
  name: string;
  language: string;
  params: string[];
}

export type SendResult =
  | { kind: "sent"; providerMessageId: string }
  | { kind: "retriable"; code: string; retryAfterMs?: number } // nothing was accepted (429, 5xx before send)
  | { kind: "permanent"; code: string } // window closed, blocked, invalid recipient
  | { kind: "unknown"; code: string }; // timeout or reset after the request left: never resent automatically

export interface ProviderAdapter {
  /** Registry id (app.providers.id). */
  readonly provider: string;
  /** Lower-case request headers the database needs to verify a webhook; nothing else is forwarded. */
  readonly webhookHeaders: readonly string[];
  /** Per-bot providers: the webhook URL names the connection, whose own secret verifies it. */
  readonly perConnectionWebhook: boolean;
  /** Providers that confirm a webhook subscription with a GET verify-token handshake (Meta). */
  readonly handshake?: "meta";
  /** Providers that can submit message templates (WhatsApp). Others refuse a template send. */
  readonly supportsTemplates?: boolean;
  /** Submits exactly `msg.text`. Must never throw for provider errors: map them to a SendResult. */
  send(msg: OutboundText, credential: string | null, opts: { timeoutMs: number }): Promise<SendResult>;
  /** Token-based connection (per-bot providers); OAuth providers have none. */
  readonly connect?: BotConnect;
}

export type Identity = { ok: true; accountId: string; displayName: string } | { ok: false; code: string };

export interface BotConnect {
  /** Asks the PROVIDER which account the token belongs to (never trusts the seller's word). */
  identify(token: string, opts: { timeoutMs: number }): Promise<Identity>;
  /** Registers our webhook URL (and secret, where the provider echoes one) for the bot. */
  setWebhook(
    token: string,
    url: string,
    secret: string,
    opts: { timeoutMs: number },
  ): Promise<{ ok: boolean; code?: string }>;
}

/** Fetch with a deadline; a timeout or reset after the request may have left is `unknown`. */
export async function postJson(
  url: string,
  body: unknown,
  opts: { timeoutMs: number; headers?: Record<string, string>; fetchFn?: typeof fetch },
): Promise<{ status: number; headers: Headers; json: Record<string, unknown> } | SendResult> {
  let res: Response;
  try {
    res = await (opts.fetchFn ?? fetch)(url, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=utf-8", ...(opts.headers ?? {}) },
      // The text goes out exactly as authorized: JSON.stringify keeps every code point.
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(opts.timeoutMs),
    });
  } catch (error) {
    if (
      error instanceof TypeError &&
      /connection refused|dns error|failed to lookup/i.test(String(error.message))
    ) {
      return { kind: "retriable", code: "connection_refused" }; // nothing left our side
    }
    return { kind: "unknown", code: (error as Error)?.name === "TimeoutError" ? "timeout" : "transport" };
  }
  let json: Record<string, unknown> = {};
  try {
    json = await res.json() as Record<string, unknown>;
  } catch {
    json = {};
  }
  return { status: res.status, headers: res.headers, json };
}

export const isSendResult = (x: unknown): x is SendResult =>
  typeof x === "object" && x !== null && "kind" in x;

/** A stored code: lowercase, short, never provider prose (it may echo customer content). */
export const safeCode = (prefix: string, value: unknown): string => {
  const v = String(value ?? "").toLowerCase().replace(/[^a-z0-9_]/g, "_").slice(0, 40);
  return v ? `${prefix}_${v}` : prefix;
};

export const retryAfterMs = (headers: Headers, fallbackSeconds = 1): number => {
  const s = Number(headers.get("retry-after"));
  return (Number.isFinite(s) && s > 0 ? Math.min(s, 3600) : fallbackSeconds) * 1000;
};
