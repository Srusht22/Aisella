// Supabase Edge Function `channel-oauth`: connects Instagram and Messenger (Facebook Login for
// Business), WhatsApp (Embedded Signup) and TikTok business accounts. The seller first gets a nonce
// from api.begin_channel_connect (their JWT); that nonce is the OAuth state. Codes are exchanged here,
// server to server; tokens go to Vault through the aisellia_channel_connector role. No JWT on this
// function (the provider redirects the browser here; the single-use state is the check).
// NOT DEPLOYED. Secrets: META_APP_SECRET, TIKTOK_CLIENT_SECRET, AISELLIA_CHANNEL_CONNECTOR_DB_URL.
import { PostgresConnectorDb } from "../_channels/db.ts";
import { handleOAuth } from "../_channels/oauth.ts";
import { DEFAULT_GRAPH_VERSION } from "../_channels/providers/meta_graph.ts";

const env = (k: string) => Deno.env.get(k)?.trim() || undefined;
const required = (k: string) => {
  const v = env(k);
  if (!v) throw new Error(`missing ${k}`);
  return v;
};
const baseUrl = required("CHANNEL_OAUTH_BASE_URL");
if (!baseUrl.startsWith("https://")) throw new Error("CHANNEL_OAUTH_BASE_URL must be https");
const meta = env("META_APP_ID") && env("META_APP_SECRET")
  ? {
    appId: env("META_APP_ID")!,
    appSecret: env("META_APP_SECRET")!,
    loginConfigId: env("META_LOGIN_CONFIG_ID") ?? "",
    signupConfigId: env("META_SIGNUP_CONFIG_ID") ?? "",
  }
  : null;
const tiktok = env("TIKTOK_CLIENT_ID") && env("TIKTOK_CLIENT_SECRET")
  ? {
    clientId: env("TIKTOK_CLIENT_ID")!,
    clientSecret: env("TIKTOK_CLIENT_SECRET")!,
    authorizeUrl: env("TIKTOK_AUTHORIZE_URL") ?? null,
  }
  : null;
const db = new PostgresConnectorDb(required("AISELLIA_CHANNEL_CONNECTOR_DB_URL"));
// Operational metadata only: never codes, states, tokens or secrets.
const log = (event: Record<string, unknown>) =>
  console.log(JSON.stringify({ fn: "channel-oauth", ts: new Date().toISOString(), ...event }));

Deno.serve((req) =>
  handleOAuth(req, {
    db,
    baseUrl,
    meta,
    graph: { version: env("META_GRAPH_VERSION") ?? DEFAULT_GRAPH_VERSION },
    tiktok,
    appReturnUrl: env("APP_RETURN_URL") ?? null,
    log,
  })
);
