// Facebook Messenger (Page messaging) through the Send API with the Page access token.
// Inbound webhooks are verified and normalised in the database (meta_sha256 / meta_messenger).
// Outbound: POST /{version}/me/messages {"recipient": {"id": PSID}, "messaging_type": "RESPONSE",
// "message": {"text": …}} → {"recipient_id", "message_id"}. Replies inside the 24-hour window only
// (message tags deferred to Phase 9b). EVIDENCE: assumption until the official pages are read.
import type { OutboundText, ProviderAdapter, SendResult } from "../adapter.ts";
import { type GraphOptions, graphSend, graphUrl } from "./meta_graph.ts";

export class MessengerAdapter implements ProviderAdapter {
  readonly provider: string;
  readonly webhookHeaders = ["x-hub-signature-256"] as const;
  readonly perConnectionWebhook = false;
  readonly handshake = "meta" as const;
  readonly #opts: GraphOptions;

  constructor(opts: GraphOptions & { provider?: string } = {}) {
    this.provider = opts.provider ?? "messenger";
    this.#opts = opts;
  }

  send(msg: OutboundText, credential: string | null, opts: { timeoutMs: number }): Promise<SendResult> {
    return graphSend(
      graphUrl(this.#opts, "me/messages"),
      { recipient: { id: msg.recipient }, messaging_type: "RESPONSE", message: { text: msg.text } },
      credential,
      opts.timeoutMs,
      (json) => json.message_id,
      this.#opts.fetchFn,
    );
  }
}
