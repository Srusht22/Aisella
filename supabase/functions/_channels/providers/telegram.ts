// Telegram through the Bot API with the connection's bot token.
// Inbound webhooks: one URL per bot (/channel-webhook/telegram/<connection id>), verified in the
// database against that connection's secret token (telegram_token / telegram_bot).
// Outbound: POST https://api.telegram.org/bot<token>/sendMessage {"chat_id", "text"} →
// {"ok": true, "result": {"message_id", "chat": {"id"}}}; errors {"ok": false, "error_code",
// "description", "parameters": {"retry_after"}}. The Bot API takes the token in the URL path, so this
// adapter never logs or returns URLs or provider descriptions. No parse_mode: the text is sent as
// plain text, exactly as authorized. EVIDENCE: assumption until the official page is read.
import { isSendResult, postJson, type ProviderAdapter, safeCode, type SendResult } from "../adapter.ts";
import type { BotConnect, Identity, OutboundText } from "../adapter.ts";

export interface TelegramOptions {
  /** Default https://api.telegram.org (tests point it at a local imitation). */
  baseURL?: string;
  provider?: string;
  fetchFn?: typeof fetch;
}

/** Bot tokens look like 123456789:AA… ; anything else is refused before a request. */
export const TELEGRAM_TOKEN = /^[0-9]{5,15}:[A-Za-z0-9_-]{30,64}$/;

export class TelegramAdapter implements ProviderAdapter {
  readonly provider: string;
  readonly webhookHeaders = ["x-telegram-bot-api-secret-token"] as const;
  readonly perConnectionWebhook = true;
  readonly #base: string;
  readonly #fetch?: typeof fetch;

  constructor(opts: TelegramOptions = {}) {
    this.provider = opts.provider ?? "telegram";
    this.#base = (opts.baseURL ?? "https://api.telegram.org").replace(/\/+$/, "");
    this.#fetch = opts.fetchFn;
  }

  /** getMe tells which bot the token belongs to; setWebhook registers our URL and secret token. */
  readonly connect: BotConnect = {
    identify: async (token: string, opts: { timeoutMs: number }): Promise<Identity> => {
      if (!TELEGRAM_TOKEN.test(token)) return { ok: false, code: "token_invalid" };
      const res = await postJson(`${this.#base}/bot${token}/getMe`, {}, {
        timeoutMs: opts.timeoutMs,
        fetchFn: this.#fetch,
      });
      if (isSendResult(res)) return { ok: false, code: "provider_unreachable" };
      const r = res.json as {
        ok?: boolean;
        result?: { id?: number; is_bot?: boolean; first_name?: string; username?: string };
      };
      if (
        res.status !== 200 || r.ok !== true || typeof r.result?.id !== "number" || r.result.is_bot !== true
      ) {
        return { ok: false, code: "token_rejected" };
      }
      return {
        ok: true,
        accountId: String(r.result.id),
        displayName: r.result.first_name ?? r.result.username ?? "Telegram bot",
      };
    },
    setWebhook: async (token: string, url: string, secret: string, opts: { timeoutMs: number }) => {
      const res = await postJson(
        `${this.#base}/bot${token}/setWebhook`,
        // Only messages: no group, channel, edit or inline traffic is ever delivered to us.
        { url, secret_token: secret, allowed_updates: ["message"], max_connections: 40 },
        { timeoutMs: opts.timeoutMs, fetchFn: this.#fetch },
      );
      if (isSendResult(res)) return { ok: false, code: "provider_unreachable" };
      return (res.json as { ok?: boolean }).ok === true && res.status === 200
        ? { ok: true }
        : { ok: false, code: safeCode("set_webhook", res.status) };
    },
  };

  async send(msg: OutboundText, credential: string | null, opts: { timeoutMs: number }): Promise<SendResult> {
    if (!credential) return { kind: "permanent", code: "no_credential" };
    if (!TELEGRAM_TOKEN.test(credential)) return { kind: "permanent", code: "token_invalid" };
    if (!/^-?[0-9]{1,20}$/.test(msg.recipient)) return { kind: "permanent", code: "invalid_recipient" };
    const res = await postJson(
      `${this.#base}/bot${credential}/sendMessage`,
      { chat_id: msg.recipient, text: msg.text },
      { timeoutMs: opts.timeoutMs, fetchFn: this.#fetch },
    );
    if (isSendResult(res)) return res;
    const body = res.json as {
      ok?: boolean;
      result?: { message_id?: number; chat?: { id?: number } };
      error_code?: number;
      parameters?: { retry_after?: number };
    };
    if (res.status === 200 && body.ok === true) {
      const id = body.result?.message_id;
      // Message ids are unique per chat: stored as "<chat id>:<message id>", like inbound ones.
      return typeof id === "number" ? { kind: "sent", providerMessageId: `${msg.recipient}:${id}` } : {
        kind: "unknown",
        code: "no_message_id",
      };
    }
    const code = typeof body.error_code === "number" ? body.error_code : res.status;
    if (code === 429) {
      const s = Number(body.parameters?.retry_after);
      return {
        kind: "retriable",
        code: "rate_limited",
        retryAfterMs: (Number.isFinite(s) && s > 0 ? Math.min(s, 3600) : 1) * 1000,
      };
    }
    if (code >= 500) return { kind: "retriable", code: safeCode("provider_unavailable", code) };
    if (code === 401 || code === 404) return { kind: "permanent", code: "token_invalid" }; // unknown or revoked token
    // Bot blocked by the user, user deactivated, or chat not found.
    if (code === 403) return { kind: "permanent", code: "recipient_unavailable" };
    return { kind: "permanent", code: safeCode("bot_api_error", code) };
  }
}
