// Supabase Edge Function `channel-connect`: connects a Telegram or Viber bot to a store. Body:
// {"provider", "nonce" (from api.begin_channel_connect), "token" (the bot token the seller pasted)}.
// The provider confirms the token's bot; the aisellia_channel_connector login role redeems the nonce
// and stores the token and a webhook secret in Vault; the webhook is registered; the connection is
// activated. Requires a signed-in user (config.toml verify_jwt = true). NOT DEPLOYED.
import { PostgresConnectorDb } from "../_channels/db.ts";
import { handleConnect } from "../_channels/connect.ts";
import { realAdapters } from "../_channels/providers/registry.ts";

const env = (k: string) => Deno.env.get(k);
const required = (k: string) => {
  const v = env(k)?.trim();
  if (!v) throw new Error(`missing ${k}`);
  return v;
};
const webhookBase = required("CHANNEL_WEBHOOK_BASE_URL");
if (!webhookBase.startsWith("https://")) throw new Error("CHANNEL_WEBHOOK_BASE_URL must be https");
const db = new PostgresConnectorDb(required("AISELLIA_CHANNEL_CONNECTOR_DB_URL"));
const adapters = realAdapters(env);
// Operational metadata only: never tokens, nonces or secrets.
const log = (event: Record<string, unknown>) =>
  console.log(JSON.stringify({ fn: "channel-connect", ts: new Date().toISOString(), ...event }));

Deno.serve((req) => handleConnect(req, { db, adapters, webhookBase, log }));
