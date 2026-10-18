// Connecting a per-bot channel (Telegram, Viber) — Edge Function channel-connect. The seller first got
// a one-time nonce from api.begin_channel_connect (their JWT, settings.manage); here the bot token is
// checked WITH THE PROVIDER, which tells us the bot's account id; the connector role redeems the
// nonce; the webhook is registered with a fresh secret; the connection is then activated (or removed).
// Neither the token nor the nonce is ever logged or returned.
import type { ProviderAdapter } from "./adapter.ts";
import type { ConnectorDb } from "./db.ts";
import type { Logger } from "./ingest.ts";

const NONCE = /^[0-9a-f]{64}$/;

export function randomSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function handleConnect(
  req: Request,
  deps: {
    db: ConnectorDb;
    adapters: Record<string, ProviderAdapter>;
    /** e.g. https://<project>.supabase.co/functions/v1/channel-webhook */
    webhookBase: string;
    log: Logger;
    timeoutMs?: number;
  },
): Promise<Response> {
  if (req.method !== "POST") return new Response(null, { status: 405 });
  const body = await req.json().catch(() => null) as
    | { provider?: unknown; nonce?: unknown; token?: unknown }
    | null;
  const provider = typeof body?.provider === "string" ? body.provider : "";
  const nonce = typeof body?.nonce === "string" ? body.nonce : "";
  const token = typeof body?.token === "string" ? body.token.trim() : "";
  const adapter = deps.adapters[provider];
  const fail = (status: number, code: string) => Response.json({ ok: false, error: { code } }, { status });
  if (!adapter?.connect) return fail(404, "NOT_FOUND");
  if (!NONCE.test(nonce) || token.length < 20 || token.length > 500) return fail(400, "VALIDATION_FAILED");
  const timeoutMs = deps.timeoutMs ?? 10000;

  const who = await adapter.connect.identify(token, { timeoutMs });
  if (!who.ok) {
    deps.log({ event: "connect_token_refused", provider, code: who.code });
    return fail(400, "TOKEN_REJECTED");
  }
  const secret = randomSecret();
  const reg = await deps.db.register(
    nonce,
    provider,
    who.accountId,
    who.displayName.slice(0, 100),
    token,
    secret,
  );
  if (!reg.ok || !reg.data) {
    const code = reg.error?.code ?? "UNKNOWN";
    deps.log({ event: "connect_refused", provider, code });
    return fail(code === "ACCOUNT_IN_USE" ? 409 : code === "NOT_FOUND" ? 404 : 400, code);
  }
  const connectionId = reg.data.connection_id;
  const hook = await adapter.connect.setWebhook(
    token,
    `${deps.webhookBase.replace(/\/+$/, "")}/${provider}/${connectionId}`,
    secret,
    {
      timeoutMs,
    },
  );
  const done = await deps.db.finish(nonce, hook.ok);
  deps.log({ event: hook.ok ? "connect_completed" : "connect_webhook_failed", provider, code: hook.code });
  if (!hook.ok || !done.ok) return fail(502, "WEBHOOK_NOT_SET");
  return Response.json({
    ok: true,
    data: { connection_id: connectionId, provider, display_name: who.displayName },
  });
}
