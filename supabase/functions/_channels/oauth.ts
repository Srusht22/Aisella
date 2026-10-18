// Account connection through OAuth (Edge Function channel-oauth), for providers whose connect method is
// meta_login (Instagram, Messenger), whatsapp_signup (WhatsApp Embedded Signup) or tiktok_oauth.
//   POST /start {provider, nonce}            → where to send the seller (nonce from api.begin_channel_connect)
//   GET  /callback/<provider>?code&state     → Meta / TikTok redirect: exchange, discover, register, subscribe
//   GET  /signup/whatsapp?state              → hosted page running Meta's Embedded Signup
//   POST /whatsapp/complete {state, code, waba_id, phone_number_id}
// The nonce is the OAuth state: single use, 10 minutes, bound to the seller's store in the database.
// Codes are exchanged server to server; tokens go only to Vault; nothing secret is logged or returned.
// Pages reflect no input and are sent with no-store and no-referrer (the code never leaks via Referer).
import type { ConnectorDb } from "./db.ts";
import type { Logger } from "./ingest.ts";
import type { GraphOptions } from "./providers/meta_graph.ts";
import {
  accountsFor,
  completeWhatsAppSignup,
  exchangeLoginCode,
  type GrantedAccount,
  grantedPages,
  type MetaApp,
  metaLoginUrl,
  subscribePage,
} from "./providers/meta_connect.ts";
import { exchangeTikTokCode, type TikTokApp, tiktokAuthorizeUrl } from "./providers/tiktok_connect.ts";

const NONCE = /^[0-9a-f]{64}$/;
export type ProviderKind = "instagram" | "messenger" | "whatsapp" | "tiktok";
const METHODS: Record<ProviderKind, "meta_login" | "whatsapp_signup" | "tiktok_oauth"> = {
  instagram: "meta_login",
  messenger: "meta_login",
  whatsapp: "whatsapp_signup",
  tiktok: "tiktok_oauth",
};

export interface OAuthDeps {
  db: ConnectorDb;
  /** e.g. https://<project>.supabase.co/functions/v1/channel-oauth */
  baseUrl: string;
  meta: MetaApp | null;
  graph: GraphOptions;
  tiktok: TikTokApp | null;
  /** Where the result page sends the seller back (app deep link), optional. */
  appReturnUrl?: string | null;
  log: Logger;
  /** Which provider a registry id is (tests map fixture providers configured like the real ones). */
  kindOf?: (provider: string) => ProviderKind | undefined;
}

const securityHeaders = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

function page(ok: boolean, appReturnUrl?: string | null): Response {
  const back = appReturnUrl && /^[a-z][a-z0-9+.-]*:\/\/[A-Za-z0-9/._-]*$/.test(appReturnUrl)
    ? `<p><a href="${appReturnUrl}">Return to Aisellia · گەڕانەوە بۆ ئەیسێلیا · العودة إلى أيسيليا</a></p>`
    : "";
  const msg = ok
    ? "Connected. You can return to Aisellia. · پەیوەست کرا. · تم الربط."
    : "The account could not be connected. Please try again from Aisellia. · پەیوەست نەکرا. · تعذّر الربط.";
  return new Response(
    `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<title>Aisellia</title></head><body style="font-family:sans-serif;padding:24px"><p>${msg}</p>${back}</body></html>`,
    {
      status: ok ? 200 : 400,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Content-Security-Policy": "default-src 'none'",
        ...securityHeaders,
      },
    },
  );
}

/** Registers every granted account under the nonce, all or nothing. */
async function registerAll(
  deps: OAuthDeps,
  nonce: string,
  provider: string,
  accounts: (GrantedAccount & { refreshToken?: string | null; expiresAt?: string | null })[],
  afterEach?: (a: GrantedAccount) => Promise<void>,
): Promise<boolean> {
  if (!deps.db.registerAccount || accounts.length === 0) {
    await deps.db.finish(nonce, false).catch(() => {});
    return false;
  }
  let registered = 0;
  let failed = false;
  for (const a of accounts) {
    const r = await deps.db.registerAccount(nonce, provider, {
      accountId: a.accountId,
      displayName: a.displayName,
      credential: a.credential,
      refreshToken: a.refreshToken ?? null,
      expiresAt: a.expiresAt ?? null,
      meta: a.meta,
    });
    if (!r.ok) {
      // ACCOUNT_IN_USE: another store holds it; the seller's other accounts can still connect.
      deps.log({ event: "oauth_account_refused", provider, code: r.error?.code });
      if (r.error?.code !== "ACCOUNT_IN_USE") failed = true;
      continue;
    }
    try {
      await afterEach?.(a);
      registered++;
    } catch (e) {
      deps.log({ event: "oauth_subscribe_failed", provider, code: (e as { code?: string }).code ?? "error" });
      failed = true;
    }
  }
  const ok = registered > 0 && !failed;
  await deps.db.finish(nonce, ok);
  return ok;
}

export async function handleOAuth(req: Request, deps: OAuthDeps): Promise<Response> {
  const url = new URL(req.url);
  const parts = url.pathname.split("/").filter(Boolean);
  const at = parts.indexOf("channel-oauth");
  const route = parts.slice(at + 1);
  const kindOf = deps.kindOf ?? ((p: string) => (p in METHODS ? p as ProviderKind : undefined));
  const methodOf = (p: string) => {
    const k = kindOf(p);
    return k ? METHODS[k] : undefined;
  };
  const base = deps.baseUrl.replace(/\/+$/, "");
  const fail = (status: number, code: string) =>
    Response.json({ ok: false, error: { code } }, { status, headers: securityHeaders });

  if (req.method === "POST" && route[0] === "start") {
    const body = await req.json().catch(() => null) as { provider?: unknown; nonce?: unknown } | null;
    const provider = typeof body?.provider === "string" ? body.provider : "";
    const nonce = typeof body?.nonce === "string" ? body.nonce : "";
    const method = methodOf(provider);
    if (!method || !NONCE.test(nonce)) return fail(400, "VALIDATION_FAILED");
    const redirect = `${base}/callback/${provider}`;
    if (method === "meta_login") {
      if (!deps.meta) return fail(503, "NOT_CONFIGURED");
      return Response.json(
        { ok: true, data: { url: metaLoginUrl(deps.meta, deps.graph, redirect, nonce) } },
        { headers: securityHeaders },
      );
    }
    if (method === "whatsapp_signup") {
      if (!deps.meta) return fail(503, "NOT_CONFIGURED");
      return Response.json({ ok: true, data: { url: `${base}/signup/whatsapp?state=${nonce}` } }, {
        headers: securityHeaders,
      });
    }
    if (!deps.tiktok?.authorizeUrl) return fail(503, "NOT_CONFIGURED");
    return Response.json({ ok: true, data: { url: tiktokAuthorizeUrl(deps.tiktok, redirect, nonce) } }, {
      headers: securityHeaders,
    });
  }

  if (req.method === "GET" && route[0] === "callback" && route.length === 2) {
    const provider = route[1];
    const method = methodOf(provider);
    const state = url.searchParams.get("state") ?? "";
    const code = url.searchParams.get("code") ?? url.searchParams.get("auth_code") ?? "";
    if (!method || method === "whatsapp_signup" || !NONCE.test(state)) return page(false, deps.appReturnUrl);
    if (!code || code.length > 2000) {
      // The seller declined or the provider failed: the request is closed.
      await deps.db.finish(state, false).catch(() => {});
      deps.log({ event: "oauth_declined", provider });
      return page(false, deps.appReturnUrl);
    }
    const redirect = `${base}/callback/${provider}`;
    try {
      let ok = false;
      if (method === "meta_login") {
        if (!deps.meta) throw new Error("not_configured");
        const userToken = await exchangeLoginCode(deps.meta, deps.graph, code, redirect);
        const accounts = accountsFor(
          kindOf(provider) === "instagram" ? "instagram" : "messenger",
          await grantedPages(deps.graph, userToken),
        );
        ok = await registerAll(
          deps,
          state,
          provider,
          accounts,
          (a) => subscribePage(deps.graph, a.meta.page_id, a.credential, kindOf(provider) ?? provider),
        );
      } else {
        if (!deps.tiktok) throw new Error("not_configured");
        const acc = await exchangeTikTokCode(deps.tiktok, code, redirect);
        ok = await registerAll(deps, state, provider, [acc]);
      }
      deps.log({ event: ok ? "oauth_connected" : "oauth_failed", provider });
      return page(ok, deps.appReturnUrl);
    } catch (e) {
      await deps.db.finish(state, false).catch(() => {});
      deps.log({ event: "oauth_failed", provider, code: (e as { code?: string }).code ?? "error" });
      return page(false, deps.appReturnUrl);
    }
  }

  if (req.method === "GET" && route[0] === "signup" && route[1] === "whatsapp") {
    const state = url.searchParams.get("state") ?? "";
    if (!deps.meta || !NONCE.test(state)) return page(false, deps.appReturnUrl);
    return signupPage(deps.meta, deps.graph, base);
  }

  if (req.method === "POST" && route[0] === "whatsapp" && route[1] === "complete") {
    const body = await req.json().catch(() => null) as Record<string, unknown> | null;
    const s = (k: string) => typeof body?.[k] === "string" ? body[k] as string : "";
    const state = s("state");
    if (!deps.meta || !NONCE.test(state) || !s("code") || s("code").length > 2000) {
      return fail(400, "VALIDATION_FAILED");
    }
    const provider = s("provider") && methodOf(s("provider")) === "whatsapp_signup"
      ? s("provider")
      : "whatsapp";
    try {
      const acc = await completeWhatsAppSignup(
        deps.meta,
        deps.graph,
        s("code"),
        s("waba_id"),
        s("phone_number_id"),
      );
      const ok = await registerAll(
        deps,
        state,
        provider,
        [acc],
      );
      deps.log({ event: ok ? "oauth_connected" : "oauth_failed", provider: "whatsapp" });
      return ok ? Response.json({ ok: true }, { headers: securityHeaders }) : fail(400, "CONNECT_FAILED");
    } catch (e) {
      await deps.db.finish(state, false).catch(() => {});
      deps.log({
        event: "oauth_failed",
        provider: "whatsapp",
        code: (e as { code?: string }).code ?? "error",
      });
      return fail(400, "CONNECT_FAILED");
    }
  }
  return new Response(null, { status: 404, headers: securityHeaders });
}

/** Meta's Embedded Signup in a hosted page (the JavaScript SDK runs in the seller's browser). */
function signupPage(meta: MetaApp, graph: GraphOptions, base: string): Response {
  const version = new URL(`https://x/${(graph.version ?? "v26.0")}`).pathname.slice(1);
  const cfg = JSON.stringify({
    appId: meta.appId,
    configId: meta.signupConfigId,
    version,
    complete: `${base}/whatsapp/complete`,
  });
  const html =
    `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aisellia · WhatsApp</title></head><body style="font-family:sans-serif;padding:24px">
<p id="msg">Connect WhatsApp · پەیوەستکردنی واتساپ · ربط واتساب</p><button id="go">Continue</button>
<script>
const cfg = ${cfg};
const state = new URLSearchParams(location.search).get("state");
let ids = null;
window.addEventListener("message", (e) => {
  if (!/facebook\\.com$/.test(new URL(e.origin).hostname)) return;
  try { const d = typeof e.data === "string" ? JSON.parse(e.data) : e.data;
    if (d && d.type === "WA_EMBEDDED_SIGNUP" && d.data && d.data.phone_number_id) ids = d.data; } catch (_) {}
});
window.fbAsyncInit = () => FB.init({ appId: cfg.appId, autoLogAppEvents: false, xfbml: false, version: cfg.version });
document.getElementById("go").onclick = () => FB.login(async (r) => {
  const code = r && r.authResponse && r.authResponse.code;
  const res = code && ids ? await fetch(cfg.complete, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ state, code, waba_id: ids.waba_id, phone_number_id: ids.phone_number_id }) }) : null;
  document.getElementById("msg").textContent = res && res.ok ? "Connected. You can return to Aisellia." : "Not connected. Please try again from Aisellia.";
}, { config_id: cfg.configId, response_type: "code", override_default_response_type: true, extras: { setup: {} } });
</script><script async defer crossorigin="anonymous" src="https://connect.facebook.net/en_US/sdk.js"></script></body></html>`;
  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy":
        "default-src 'none'; script-src 'unsafe-inline' https://connect.facebook.net; connect-src 'self' https://*.supabase.co; " +
        "frame-src https://*.facebook.com; img-src https://*.facebook.com https://*.fbcdn.net",
      ...securityHeaders,
    },
  });
}
