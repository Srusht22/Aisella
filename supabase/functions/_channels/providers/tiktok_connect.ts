// Connecting a TikTok business account (TikTok API for Business, account authorization).
// CONFIRMED (official search results, see provider-verification.md): POST
// /open_api/v1.3/tt_user/oauth2/token/ with client_id, client_secret, grant_type=authorization_code,
// auth_code, redirect_uri → access_token (1 day), refresh_token (1 year), open_id, expires_in;
// refresh at /tt_user/oauth2/refresh_token/. ASSUMPTION: the response is wrapped in TikTok's usual
// {"code": 0, "data": {…}} envelope; the authorization page URL comes from the developer portal
// (TIKTOK_AUTHORIZE_URL), because its format was not found.
import type { GrantedAccount } from "./meta_connect.ts";

export interface TikTokApp {
  clientId: string;
  clientSecret: string;
  /** The authorization page URL from the developer portal; without it TikTok cannot be connected. */
  authorizeUrl: string | null;
  baseURL?: string;
  fetchFn?: typeof fetch;
}

export class TikTokConnectError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

export function tiktokAuthorizeUrl(app: TikTokApp, redirectUri: string, state: string): string {
  if (!app.authorizeUrl || !app.authorizeUrl.startsWith("https://")) {
    throw new TikTokConnectError("not_configured");
  }
  const u = new URL(app.authorizeUrl);
  u.searchParams.set("redirect_uri", redirectUri);
  u.searchParams.set("state", state);
  return u.toString();
}

interface TokenData {
  access_token?: string;
  refresh_token?: string;
  open_id?: string;
  expires_in?: number;
}

async function tokenCall(app: TikTokApp, path: string, body: Record<string, string>): Promise<TokenData> {
  const base = (app.baseURL ?? "https://business-api.tiktok.com").replace(/\/+$/, "");
  const res = await (app.fetchFn ?? fetch)(`${base}/open_api/v1.3/tt_user/oauth2/${path}/`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ client_id: app.clientId, client_secret: app.clientSecret, ...body }),
    signal: AbortSignal.timeout(15000),
  }).catch(() => {
    throw new TikTokConnectError("provider_unreachable");
  });
  const json = await res.json().catch(() => ({})) as { code?: number; data?: TokenData } & TokenData;
  const data = json.data ?? json;
  if (!res.ok || (json.code !== undefined && json.code !== 0) || typeof data.access_token !== "string") {
    throw new TikTokConnectError("token_rejected");
  }
  return data;
}

export async function exchangeTikTokCode(
  app: TikTokApp,
  code: string,
  redirectUri: string,
): Promise<
  GrantedAccount & {
    refreshToken: string | null;
    expiresAt: string;
  }
> {
  const d = await tokenCall(app, "token", {
    grant_type: "authorization_code",
    auth_code: code,
    redirect_uri: redirectUri,
  });
  if (typeof d.open_id !== "string" || d.open_id === "") throw new TikTokConnectError("no_account");
  return {
    accountId: d.open_id,
    displayName: "TikTok",
    credential: d.access_token!,
    meta: {},
    refreshToken: d.refresh_token ?? null,
    expiresAt: new Date(Date.now() + Math.max(60, Number(d.expires_in ?? 86400)) * 1000).toISOString(),
  };
}

export async function refreshTikTokToken(app: TikTokApp, refreshToken: string): Promise<{
  accessToken: string;
  refreshToken: string | null;
  expiresAt: string;
}> {
  const d = await tokenCall(app, "refresh_token", {
    grant_type: "refresh_token",
    refresh_token: refreshToken,
  });
  return {
    accessToken: d.access_token!,
    refreshToken: d.refresh_token ?? null,
    expiresAt: new Date(Date.now() + Math.max(60, Number(d.expires_in ?? 86400)) * 1000).toISOString(),
  };
}
