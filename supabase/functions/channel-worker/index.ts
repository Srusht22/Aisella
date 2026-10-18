// Supabase Edge Function `channel-worker`: one fair cycle of due sends per call (retries after backoff,
// sends whose immediate dispatch failed). Called by an external scheduler with
// "Authorization: Bearer <CHANNEL_WORKER_SECRET>" (config.toml verify_jwt = false; the secret is the
// check). Runs with the aisellia_channel_sender login role. NOT DEPLOYED.
import { PostgresSenderDb } from "../_channels/db.ts";
import { realAdapters } from "../_channels/providers/registry.ts";
import { refreshTikTokToken } from "../_channels/providers/tiktok_connect.ts";
import { handleWorkerRequest, runRefreshCycle, runWorkerCycle } from "../_channels/worker.ts";

const env = (k: string) => Deno.env.get(k);
const required = (k: string) => {
  const v = env(k)?.trim();
  if (!v) throw new Error(`missing ${k}`);
  return v;
};
const secret = required("CHANNEL_WORKER_SECRET");
if (secret.length < 32) throw new Error("CHANNEL_WORKER_SECRET must be at least 32 characters");
const db = new PostgresSenderDb(required("AISELLIA_CHANNEL_SENDER_DB_URL"));
const adapters = realAdapters(env);
// Operational metadata only: never message text, tokens or credentials.
const log = (event: Record<string, unknown>) =>
  console.log(JSON.stringify({ fn: "channel-worker", ts: new Date().toISOString(), ...event }));

// TikTok tokens live one day: refreshed here when the app credentials are configured.
const tiktok = env("TIKTOK_CLIENT_ID") && env("TIKTOK_CLIENT_SECRET")
  ? { clientId: env("TIKTOK_CLIENT_ID")!, clientSecret: env("TIKTOK_CLIENT_SECRET")!, authorizeUrl: null }
  : null;
const refreshers: Parameters<typeof runRefreshCycle>[0]["refreshers"] = tiktok
  ? { tiktok: (t: string) => refreshTikTokToken(tiktok, t) }
  : {};

Deno.serve((req) =>
  handleWorkerRequest(req, {
    secret,
    cycle: async () => {
      const result = await runWorkerCycle({ db, adapters, log });
      await runRefreshCycle({ db, refreshers, log });
      return result;
    },
  })
);
