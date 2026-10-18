// Supabase Edge Function `channel-webhook`: receives provider webhooks at
//   /channel-webhook/<provider>                (app-signed providers: Instagram, Messenger, WhatsApp, TikTok)
//   /channel-webhook/<provider>/<connection>   (per-bot providers: Telegram, Viber)
// It hands the raw bytes and the signature headers to the database through the
// aisellia_channel_ingest login role; the database verifies, normalises and stores (review O6).
// No JWT: providers cannot send one (config.toml verify_jwt = false). NOT DEPLOYED.
import { PostgresIngestDb } from "../_channels/db.ts";
import { handleWebhook } from "../_channels/ingest.ts";
import { realAdapters } from "../_channels/providers/registry.ts";

const env = (k: string) => Deno.env.get(k);
const dbUrl = env("AISELLIA_CHANNEL_INGEST_DB_URL");
if (!dbUrl) throw new Error("missing AISELLIA_CHANNEL_INGEST_DB_URL");
const db = new PostgresIngestDb(dbUrl);
const adapters = realAdapters(env);
// Operational metadata only: never bodies, headers, secrets or message text.
const log = (event: Record<string, unknown>) =>
  console.log(JSON.stringify({ fn: "channel-webhook", ts: new Date().toISOString(), ...event }));

Deno.serve((req) => {
  const parts = new URL(req.url).pathname.split("/").filter(Boolean);
  const at = parts.indexOf("channel-webhook");
  const [provider, connection, extra] = parts.slice(at + 1);
  const adapter = provider ? adapters[provider] : undefined;
  if (!adapter || extra !== undefined) return new Response(null, { status: 404 });
  return handleWebhook(req, { adapter, db, log, connectionHint: connection ?? null });
});
