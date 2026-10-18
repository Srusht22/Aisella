// Supabase Edge Function `channel-send`: submits ONE send the seller already authorized with
// api.send_message (exact text, hash, audit). Body: {"send_request_id": "<uuid>"}. The caller must be
// a member of the send's store with messages.send (checked with their own JWT); the submission runs
// with the aisellia_channel_sender login role: claim → re-hash → adapter → report; an unknown outcome
// is never resent. Requires a signed-in user (config.toml verify_jwt = true). NOT DEPLOYED.
import { PostgresSenderDb } from "../_channels/db.ts";
import { handleSendRequest, postgrestOwnerCheck } from "../_channels/dispatch.ts";
import { realAdapters } from "../_channels/providers/registry.ts";

const env = (k: string) => Deno.env.get(k);
const required = (k: string) => {
  const v = env(k)?.trim();
  if (!v) throw new Error(`missing ${k}`);
  return v;
};
const db = new PostgresSenderDb(required("AISELLIA_CHANNEL_SENDER_DB_URL"));
const checkOwner = postgrestOwnerCheck(required("SUPABASE_URL"), required("SUPABASE_ANON_KEY"));
const adapters = realAdapters(env);
// Operational metadata only: never message text, tokens or credentials.
const log = (event: Record<string, unknown>) =>
  console.log(JSON.stringify({ fn: "channel-send", ts: new Date().toISOString(), ...event }));

Deno.serve((req) => handleSendRequest(req, { db, adapters, checkOwner, log }));
