// WhatsApp Business through the Cloud API, with the connection's system-user token.
// Inbound webhooks are verified and normalised in the database (meta_sha256 / whatsapp_cloud).
// Outbound: POST /{version}/{phone-number-id}/messages {"messaging_product": "whatsapp",
// "recipient_type": "individual", "to": wa_id, "type": "text", "text": {"preview_url": false, "body": …}}
// → {"messages": [{"id": "wamid…"}]}. Free-form text only inside the 24-hour customer-service window;
// templates (needed outside it) are not implemented. EVIDENCE: assumption until the official pages
// are read (see meta_graph.ts).
import type { OutboundText, ProviderAdapter, SendResult } from "../adapter.ts";
import { type GraphOptions, graphSend, graphUrl } from "./meta_graph.ts";

export class WhatsAppAdapter implements ProviderAdapter {
  readonly provider: string;
  readonly webhookHeaders = ["x-hub-signature-256"] as const;
  readonly perConnectionWebhook = false;
  readonly handshake = "meta" as const;
  readonly #opts: GraphOptions;

  constructor(opts: GraphOptions & { provider?: string } = {}) {
    this.provider = opts.provider ?? "whatsapp";
    this.#opts = opts;
  }

  send(msg: OutboundText, credential: string | null, opts: { timeoutMs: number }): Promise<SendResult> {
    // Both go into the request: they must be plain ids (no path or parameter injection).
    if (!/^[0-9]{5,30}$/.test(msg.accountId)) {
      return Promise.resolve({ kind: "permanent", code: "invalid_account" });
    }
    if (!/^[0-9]{5,20}$/.test(msg.recipient)) {
      return Promise.resolve({ kind: "permanent", code: "invalid_recipient" });
    }
    return graphSend(
      graphUrl(this.#opts, `${msg.accountId}/messages`),
      {
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: msg.recipient,
        type: "text",
        // No link previews: the customer sees exactly the authorized text.
        text: { preview_url: false, body: msg.text },
      },
      credential,
      opts.timeoutMs,
      (json) => (json.messages as { id?: unknown }[] | undefined)?.[0]?.id,
      this.#opts.fetchFn,
    );
  }
}
