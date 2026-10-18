// The shared provider-adapter interface (Phase 9 L §3). One module per provider implements it;
// the core never contains provider names in business logic. MC-2 ships only a fixture stub.

/** What the database receives: normalised, provider-neutral items (C §3, L §3). */
export type NormalizedEvent =
  | {
    kind: "message" | "echo";
    account_id: string;
    external_user_id: string;
    external_message_id: string;
    occurred_at: string;
    text?: string;
    display_name?: string;
    attachments?: { kind: string; ref?: string; mime_type?: string; size_bytes?: number }[];
  }
  | {
    kind: "delivery" | "read" | "failed";
    account_id: string;
    provider_message_id: string;
    provider_event_key?: string;
    provider_status?: string;
    occurred_at?: string;
  }
  | { kind: "account"; account_id: string; status: string };

export interface VerifyResult {
  ok: boolean;
  /** Short reason code for logs and counters; never request content. */
  reason?: string;
}

export interface ParsedEvent {
  /** Provider event id, or the SHA-256 of the raw body when the provider has none. */
  externalEventId: string;
  events: NormalizedEvent[];
}

export interface OutboundText {
  /** The exact text the seller authorized. Adapters must submit it unmodified. */
  text: string;
  textSha256: string;
  recipient: string;
  accountId: string;
}

export type SendResult =
  | { kind: "sent"; providerMessageId: string }
  | { kind: "retriable"; code: string; retryAfterMs?: number } // nothing was accepted (429, 5xx before send)
  | { kind: "permanent"; code: string } // window closed, blocked, invalid recipient
  | { kind: "unknown"; code: string }; // timeout or reset after the request left: never resent automatically

export interface ProviderAdapter {
  /** Registry id (app.providers.id). */
  readonly provider: string;
  /** Verifies authenticity on the RAW bytes, before any parsing. */
  verify(raw: Uint8Array, headers: Headers): Promise<VerifyResult>;
  /** Parses an already-verified body into normalised events. */
  parse(raw: Uint8Array): Promise<ParsedEvent>;
  /** Submits exactly `msg.text`. Must never throw for provider errors: map them to a SendResult. */
  send(msg: OutboundText, credential: string | null, opts: { timeoutMs: number }): Promise<SendResult>;
}
