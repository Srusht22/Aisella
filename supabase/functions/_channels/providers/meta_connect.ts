// Connecting Meta accounts (Facebook Login for Business for Instagram and Messenger; Embedded Signup
// for WhatsApp). Server to server only: the app secret is sent in a POST body, never in a URL, and no
// token is ever logged or returned to the app.
//
// EVIDENCE (docs/implementation/phase-9/provider-verification.md): the code exchange at
// oauth/access_token (client_id, redirect_uri, client_secret, code), Page tokens from {user}/accounts,
// POST /{page-id}/subscribed_apps with subscribed_fields, and for WhatsApp the 30-second code,
// /{waba_id}/phone_numbers and /{waba_id}/subscribed_apps were confirmed through official-domain search
// results; the exact Instagram and delivery/read subscription field names are assumptions.
import { type GraphOptions, graphUrl } from "./meta_graph.ts";

export interface MetaApp {
  appId: string;
  appSecret: string;
  /** Facebook Login for Business configuration id (dashboard). */
  loginConfigId: string;
  /** Embedded Signup configuration id (dashboard). */
  signupConfigId: string;
}

export interface GrantedAccount {
  accountId: string;
  displayName: string;
  credential: string;
  meta: Record<string, string>;
}

export class MetaConnectError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

async function graph(
  opts: GraphOptions,
  path: string,
  init: { method?: string; token?: string; form?: Record<string, string> } = {},
): Promise<Record<string, unknown>> {
  const res = await (opts.fetchFn ?? fetch)(graphUrl(opts, path), {
    method: init.method ?? (init.form ? "POST" : "GET"),
    headers: {
      ...(init.token ? { Authorization: `Bearer ${init.token}` } : {}),
      ...(init.form ? { "Content-Type": "application/x-www-form-urlencoded" } : {}),
    },
    body: init.form ? new URLSearchParams(init.form) : undefined,
    signal: AbortSignal.timeout(15000),
  }).catch(() => {
    throw new MetaConnectError("provider_unreachable");
  });
  const json = await res.json().catch(() => ({})) as Record<string, unknown>;
  if (!res.ok) {
    const code = (json.error as { code?: number } | undefined)?.code;
    throw new MetaConnectError(code === 190 ? "token_rejected" : `graph_${res.status}`);
  }
  return json;
}

/** The Facebook Login dialog for a Business Login configuration (authorization-code grant). */
export function metaLoginUrl(app: MetaApp, opts: GraphOptions, redirectUri: string, state: string): string {
  const version = new URL(graphUrl(opts, "x")).pathname.split("/")[1];
  const u = new URL(`https://www.facebook.com/${version}/dialog/oauth`);
  u.search = new URLSearchParams({
    client_id: app.appId,
    redirect_uri: redirectUri,
    state,
    config_id: app.loginConfigId,
    response_type: "code",
    override_default_response_type: "true",
  }).toString();
  return u.toString();
}

/** Code → user token (server to server), then the long-lived user token. */
export async function exchangeLoginCode(
  app: MetaApp,
  opts: GraphOptions,
  code: string,
  redirectUri: string,
): Promise<string> {
  const short = await graph(opts, "oauth/access_token", {
    form: { client_id: app.appId, client_secret: app.appSecret, redirect_uri: redirectUri, code },
  });
  if (typeof short.access_token !== "string") throw new MetaConnectError("no_token");
  const long = await graph(opts, "oauth/access_token", {
    form: {
      grant_type: "fb_exchange_token",
      client_id: app.appId,
      client_secret: app.appSecret,
      fb_exchange_token: short.access_token,
    },
  });
  if (typeof long.access_token !== "string") throw new MetaConnectError("no_token");
  return long.access_token;
}

interface PageRow {
  id?: string;
  name?: string;
  access_token?: string;
  instagram_business_account?: { id?: string; username?: string };
}

/** The Pages the seller granted, with their (non-expiring) Page tokens and linked Instagram accounts. */
export async function grantedPages(opts: GraphOptions, userToken: string): Promise<PageRow[]> {
  const out = await graph(
    opts,
    "me/accounts?fields=id,name,access_token,instagram_business_account%7Bid,username%7D&limit=50",
    {
      token: userToken,
    },
  );
  return Array.isArray(out.data) ? (out.data as PageRow[]) : [];
}

/** Accounts for one provider from the granted Pages. */
export function accountsFor(provider: "instagram" | "messenger", pages: PageRow[]): GrantedAccount[] {
  const ok = (p: PageRow) =>
    typeof p.id === "string" && typeof p.access_token === "string" && p.access_token.length >= 20;
  if (provider === "messenger") {
    return pages.filter(ok).map((p) => ({
      accountId: p.id!,
      displayName: p.name ?? "Facebook Page",
      credential: p.access_token!,
      meta: { page_id: p.id! },
    }));
  }
  return pages.filter((p) => ok(p) && typeof p.instagram_business_account?.id === "string").map((p) => ({
    accountId: p.instagram_business_account!.id!,
    displayName: p.instagram_business_account!.username
      ? `@${p.instagram_business_account!.username}`
      : p.name ?? "Instagram",
    credential: p.access_token!,
    meta: { page_id: p.id!, username: p.instagram_business_account!.username ?? "" },
  }));
}

/** Subscribes our app to the Page's messaging webhooks. */
export async function subscribePage(
  opts: GraphOptions,
  pageId: string,
  pageToken: string,
  provider: string,
): Promise<void> {
  const fields = provider === "messenger"
    ? "messages,message_echoes,message_deliveries,message_reads"
    : "messages";
  const out = await graph(opts, `${pageId}/subscribed_apps`, {
    token: pageToken,
    form: { subscribed_fields: fields },
  });
  if (out.success !== true) throw new MetaConnectError("subscribe_failed");
}

/** WhatsApp Embedded Signup: code (30 s) → business token; the number must belong to the WABA. */
export async function completeWhatsAppSignup(
  app: MetaApp,
  opts: GraphOptions,
  code: string,
  wabaId: string,
  phoneNumberId: string,
): Promise<GrantedAccount> {
  if (!/^[0-9]{5,30}$/.test(wabaId) || !/^[0-9]{5,30}$/.test(phoneNumberId)) {
    throw new MetaConnectError("invalid_ids");
  }
  const tok = await graph(opts, "oauth/access_token", {
    form: { client_id: app.appId, client_secret: app.appSecret, code },
  });
  if (typeof tok.access_token !== "string") throw new MetaConnectError("no_token");
  const numbers = await graph(opts, `${wabaId}/phone_numbers?fields=id,display_phone_number,verified_name`, {
    token: tok.access_token,
  });
  const match =
    (Array.isArray(numbers.data)
      ? numbers.data as { id?: string; display_phone_number?: string; verified_name?: string }[]
      : [])
      .find((n) => n.id === phoneNumberId);
  if (!match) throw new MetaConnectError("number_not_in_account");
  const sub = await graph(opts, `${wabaId}/subscribed_apps`, { token: tok.access_token, method: "POST" });
  if (sub.success !== true) throw new MetaConnectError("subscribe_failed");
  return {
    accountId: phoneNumberId,
    displayName: match.verified_name ?? match.display_phone_number ?? "WhatsApp",
    credential: tok.access_token,
    meta: { waba_id: wabaId, display_phone_number: match.display_phone_number ?? "" },
  };
}
