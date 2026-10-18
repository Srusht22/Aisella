// Instagram messaging (Instagram API with Facebook Login, through the connected Page's token).
// Inbound webhooks are verified and normalised in the database (meta_sha256 / meta_instagram).
// Outbound: POST /{version}/me/messages {"recipient": {"id": IGSID}, "message": {"text": …}} →
// {"recipient_id", "message_id"}. Only text replies inside the 24-hour window (the Human Agent tag is
// deferred to Phase 9b). EVIDENCE: assumption until the official pages are read (see meta_graph.ts).
import type { OutboundText, ProviderAdapter, SendResult } from "../adapter.ts";
import { type GraphOptions, graphSend, graphUrl } from "./meta_graph.ts";

export class InstagramAdapter implements ProviderAdapter {
  readonly provider: string;
  readonly webhookHeaders = ["x-hub-signature-256"] as const;
  readonly perConnectionWebhook = false;
  readonly handshake = "meta" as const;
  readonly #opts: GraphOptions;

  constructor(opts: GraphOptions & { provider?: string } = {}) {
    this.provider = opts.provider ?? "instagram";
    this.#opts = opts;
  }

  send(msg: OutboundText, credential: string | null, opts: { timeoutMs: number }): Promise<SendResult> {
    return graphSend(
      graphUrl(this.#opts, "me/messages"),
      { recipient: { id: msg.recipient }, message: { text: msg.text } },
      credential,
      opts.timeoutMs,
      (json) => json.message_id,
      this.#opts.fetchFn,
    );
  }
}
