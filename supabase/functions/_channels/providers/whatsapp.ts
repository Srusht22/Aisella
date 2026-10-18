// WhatsApp Business through the Cloud API, with the connection's system-user token.
// Inbound webhooks are verified and normalised in the database (meta_sha256 / whatsapp_cloud).
// Outbound: POST /{version}/{phone-number-id}/messages {"messaging_product": "whatsapp",
// "recipient_type": "individual", "to": wa_id, "type": "text", "text": {"preview_url": false, "body": …}}
// → {"messages": [{"id": "wamid…"}]}. Free-form text only inside the 24-hour customer-service window;
// outside it an approved template: "type": "template", "template": {"name", "language": {"code"},
// "components": [{"type": "body", "parameters": [{"type": "text", "text": …}]}]}. Template lists are
// read from GET /{waba-id}/message_templates (fetchTemplates). EVIDENCE: official search snippets
// (provider-verification.md); the capability stays an assumption until the pages are read.
import type { OutboundTemplate, OutboundText, ProviderAdapter, SendResult } from "../adapter.ts";
import { type GraphOptions, graphSend, graphUrl } from "./meta_graph.ts";

export class WhatsAppAdapter implements ProviderAdapter {
  readonly provider: string;
  readonly webhookHeaders = ["x-hub-signature-256"] as const;
  readonly perConnectionWebhook = false;
  readonly handshake = "meta" as const;
  readonly supportsTemplates = true;
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
        ...(msg.template ? templateBody(msg.template) : {
          type: "text",
          // No link previews: the customer sees exactly the authorized text.
          text: { preview_url: false, body: msg.text },
        }),
      },
      credential,
      opts.timeoutMs,
      (json) => (json.messages as { id?: unknown }[] | undefined)?.[0]?.id,
      this.#opts.fetchFn,
    );
  }
}

function templateBody(t: OutboundTemplate): Record<string, unknown> {
  return {
    type: "template",
    template: {
      name: t.name,
      language: { code: t.language },
      components: t.params.length
        ? [{ type: "body", parameters: t.params.map((text) => ({ type: "text", text })) }]
        : [],
    },
  };
}

/**
 * Reads a WhatsApp Business Account's templates (name, language, status, category, components),
 * following the cursor up to 5 pages. Throws on any non-2xx answer (the sync is retried later).
 */
export async function fetchTemplates(
  opts: GraphOptions,
  wabaId: string,
  token: string,
  timeoutMs = 10000,
): Promise<unknown[]> {
  if (!/^[0-9]{5,30}$/.test(wabaId)) throw new Error("invalid_waba_id");
  const out: unknown[] = [];
  let url: string | null = graphUrl(opts, `${wabaId}/message_templates`) +
    "?fields=name,language,status,category,components&limit=100";
  const allowed = new URL(url).origin;
  for (let page = 0; url && page < 5; page++) {
    const res = await (opts.fetchFn ?? fetch)(url, {
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res.ok) {
      await res.body?.cancel();
      throw new Error(`templates_http_${res.status}`);
    }
    const json = await res.json() as { data?: unknown[]; paging?: { next?: string } };
    out.push(...(Array.isArray(json.data) ? json.data : []));
    const next = json.paging?.next;
    // Only follow cursors on the same host (the token is attached to the request).
    url = typeof next === "string" && next.startsWith(allowed + "/") ? next : null;
  }
  return out;
}
