// OAuth connection end to end on the LOCAL stack (AISELLIA_E2E=1), against local imitations of Meta's
// Graph API and TikTok's token endpoints: Instagram and Messenger (Facebook Login), WhatsApp (Embedded
// Signup), TikTok (account authorization) and token refresh. Fixture providers are configured like the
// real ones and released to "pilot" for the test only; the real providers stay in development.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import postgres from "postgres";
import { PostgresConnectorDb, PostgresSenderDb } from "../db.ts";
import { handleOAuth, type ProviderKind } from "../oauth.ts";
import { refreshTikTokToken } from "../providers/tiktok_connect.ts";
import { runRefreshCycle } from "../worker.ts";
import { ADMIN_DB, assertLocal, b64, createSeller, rpc, uuid } from "../../ai-assist/tests/local_stack.ts";

const APP_SECRET = `meta-app-secret-${uuid()}`;
const TT_SECRET = `tiktok-client-secret-${uuid()}`;
const tok = (p: string) =>
  `${p}${crypto.randomUUID().replace(/-/g, "")}${crypto.randomUUID().replace(/-/g, "")}`;

Deno.test({
  name: "OAuth connect end to end: Meta login, WhatsApp signup, TikTok, refresh, states",
  ignore: Deno.env.get("AISELLIA_E2E") !== "1",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn(t) {
    assertLocal();
    const admin = postgres(ADMIN_DB, { max: 1, onnotice: () => {} });
    const pw = {
      c: b64(crypto.getRandomValues(new Uint8Array(24))),
      s: b64(crypto.getRandomValues(new Uint8Array(24))),
    };
    const sfx = uuid().slice(0, 6);
    const ids = {
      instagram: `t_ig_${sfx}`,
      messenger: `t_fb_${sfx}`,
      whatsapp: `t_wa_${sfx}`,
      tiktok: `t_tt_${sfx}`,
    };
    const kindOf = (p: string) =>
      (Object.entries(ids).find(([, v]) => v === p)?.[0]) as ProviderKind | undefined;
    const PAGE_TOKEN_1 = tok("EAAPage1");
    const PAGE_TOKEN_2 = tok("EAAPage2");
    const USER_SHORT = tok("EAAShort");
    const USER_LONG = tok("EAALong");
    const WA_TOKEN = tok("EAAWaba");
    let ttRefreshOk = true;
    const requests: { method: string; path: string; url: string; auth: string | null; body: string }[] = [];
    const api = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen: () => {} }, async (req) => {
      const u = new URL(req.url);
      const body = await req.text();
      requests.push({
        method: req.method,
        path: u.pathname,
        url: req.url,
        auth: req.headers.get("authorization"),
        body,
      });
      const form = new URLSearchParams(body);
      const p = u.pathname.replace(/^\/v26\.0\//, "");
      if (p === "oauth/access_token") {
        if (form.get("client_secret") !== APP_SECRET) {
          return Response.json({ error: { code: 1 } }, { status: 400 });
        }
        if (form.get("grant_type") === "fb_exchange_token") return Response.json({ access_token: USER_LONG });
        if (form.get("code") === "wa-code") return Response.json({ access_token: WA_TOKEN });
        if (form.get("code")?.startsWith("good")) return Response.json({ access_token: USER_SHORT });
        return Response.json({ error: { code: 100 } }, { status: 400 });
      }
      if (p === "me/accounts") {
        assertEquals(req.headers.get("authorization"), `Bearer ${USER_LONG}`);
        return Response.json({
          data: [
            {
              id: "1001",
              name: "Shop Page",
              access_token: PAGE_TOKEN_1,
              instagram_business_account: { id: "1784001", username: "shop" },
            },
            { id: "1002", name: "Second Page", access_token: PAGE_TOKEN_2 },
          ],
        });
      }
      if (/^\d+\/subscribed_apps$/.test(p)) return Response.json({ success: true });
      if (p === "200100/phone_numbers") {
        return Response.json({
          data: [{ id: "300100", display_phone_number: "+964 750 000 0000", verified_name: "Shop WA" }],
        });
      }
      if (u.pathname === "/open_api/v1.3/tt_user/oauth2/token/") {
        const b = JSON.parse(body);
        return b.client_secret === TT_SECRET && b.auth_code === "tt-code"
          ? Response.json({
            code: 0,
            data: {
              access_token: tok("act."),
              refresh_token: tok("rft."),
              open_id: "open-1",
              expires_in: 86400,
            },
          })
          : Response.json({ code: 40001, message: "bad" });
      }
      if (u.pathname === "/open_api/v1.3/tt_user/oauth2/refresh_token/") {
        return ttRefreshOk
          ? Response.json({
            code: 0,
            data: {
              access_token: tok("act2."),
              refresh_token: tok("rft2."),
              open_id: "open-1",
              expires_in: 86400,
            },
          })
          : Response.json({ code: 40002, message: "expired" });
      }
      return new Response(null, { status: 404 });
    });
    const logs: Record<string, unknown>[] = [];
    try {
      await admin.unsafe(`alter role aisellia_channel_connector password '${pw.c}'`);
      await admin.unsafe(`alter role aisellia_channel_sender password '${pw.s}'`);
      const url = (r: string, p: string) =>
        `postgresql://${r}:${encodeURIComponent(p)}@127.0.0.1:54322/postgres`;
      const db = new PostgresConnectorDb(url("aisellia_channel_connector", pw.c));
      const sender = new PostgresSenderDb(url("aisellia_channel_sender", pw.s));
      for (const [kind, id] of Object.entries(ids)) {
        const method = kind === "whatsapp"
          ? "whatsapp_signup"
          : kind === "tiktok"
          ? "tiktok_oauth"
          : "meta_login";
        await admin`insert into app.providers (id, display_name, status, webhook_scheme, payload_format, connect_method)
                    values (${id}, ${"OAuth " + kind}, 'pilot', 'meta_sha256', 'meta_instagram', ${method})`;
        await admin`insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
                    (${id}, 'outbound_text', 'true', 'verified', 'https://fixture.invalid', current_date),
                    (${id}, 'reply_window_hours', '24', 'verified', 'https://fixture.invalid', current_date)`;
      }
      const base = `http://127.0.0.1:${api.addr.port}`;
      const handle = (req: Request) =>
        handleOAuth(req, {
          db,
          baseUrl: "https://project.example/functions/v1/channel-oauth",
          meta: {
            appId: "123456",
            appSecret: APP_SECRET,
            loginConfigId: "cfg-login",
            signupConfigId: "cfg-signup",
          },
          graph: { baseURL: base, version: "v26.0" },
          tiktok: {
            clientId: "ck-1",
            clientSecret: TT_SECRET,
            authorizeUrl: "https://tiktok.example/auth",
            baseURL: base,
          },
          appReturnUrl: "aisellia://channels",
          log: (e) => logs.push(e),
          kindOf,
        });
      const a = await createSeller(admin, { tag: "oauth-a", storeName: "OAuth A", zones: [], products: [] });
      const b = await createSeller(admin, { tag: "oauth-b", storeName: "OAuth B", zones: [], products: [] });
      const begin = async (s: { store: string; token: string }, provider: string) =>
        (await rpc("begin_channel_connect", { p_store_id: s.store, p_provider: provider }, s.token)).data
          .nonce as string;
      const conns = (store: string, provider: string) =>
        admin`select external_account_id, display_name, state, credential_ref is not null as cred, refresh_ref is not null as refresh,
                     provider_meta, expires_at from app.connections where store_id = ${store} and provider_id = ${provider}
               order by external_account_id`;
      const callback = (provider: string, q: string) =>
        handle(new Request(`https://project.example/functions/v1/channel-oauth/callback/${provider}?${q}`));

      await t.step(
        "start: the Facebook Login URL carries our config and the nonce as state, never the secret",
        async () => {
          const nonce = await begin(a, ids.instagram);
          const res = await handle(
            new Request("https://x/functions/v1/channel-oauth/start", {
              method: "POST",
              body: JSON.stringify({ provider: ids.instagram, nonce }),
            }),
          );
          const u = new URL((await res.json()).data.url);
          assertEquals(u.origin + u.pathname, "https://www.facebook.com/v26.0/dialog/oauth");
          assertEquals([
            u.searchParams.get("state"),
            u.searchParams.get("config_id"),
            u.searchParams.get("response_type"),
          ], [
            nonce,
            "cfg-login",
            "code",
          ]);
          assertEquals(
            u.searchParams.get("redirect_uri"),
            `https://project.example/functions/v1/channel-oauth/callback/${ids.instagram}`,
          );
          assertFalse(u.toString().includes(APP_SECRET));
          await rpc("begin_channel_connect", { p_store_id: a.store, p_provider: ids.instagram }, a.token); // unrelated nonce
        },
      );

      await t.step(
        "Instagram: the code is exchanged server to server; the Page's Instagram account is connected",
        async () => {
          const nonce = await begin(a, ids.instagram);
          const res = await callback(ids.instagram, `code=good-ig&state=${nonce}`);
          assertEquals(res.status, 200);
          assertEquals(res.headers.get("referrer-policy"), "no-referrer");
          const [c] = await conns(a.store, ids.instagram);
          assertEquals([c.external_account_id, c.display_name, c.state, c.cred, c.provider_meta.page_id], [
            "1784001",
            "@shop",
            "connected",
            true,
            "1001",
          ]);
          const sub = requests.find((r) => r.path === "/v26.0/1001/subscribed_apps")!;
          assertEquals(sub.auth, `Bearer ${PAGE_TOKEN_1}`);
          for (const r of requests) {
            assertFalse(r.url.includes(APP_SECRET), "the app secret is never in a URL");
          }
          assertEquals(
            (await callback(ids.instagram, `code=good-again&state=${nonce}`)).status,
            400,
            "the state works once",
          );
        },
      );

      await t.step("Messenger: every granted Page becomes a connection", async () => {
        const nonce = await begin(a, ids.messenger);
        assertEquals((await callback(ids.messenger, `code=good-fb&state=${nonce}`)).status, 200);
        assertEquals((await conns(a.store, ids.messenger)).map((c) => [c.external_account_id, c.state]), [
          ["1001", "connected"],
          ["1002", "connected"],
        ]);
      });

      await t.step(
        "a Page connected to another store is not taken over; a declined login creates nothing",
        async () => {
          const nonce = await begin(b, ids.messenger);
          await callback(ids.messenger, `code=good-fb2&state=${nonce}`);
          assertEquals((await conns(b.store, ids.messenger)).length, 0);
          const declined = await begin(b, ids.instagram);
          assertEquals((await callback(ids.instagram, `error=access_denied&state=${declined}`)).status, 400);
          assertEquals((await conns(b.store, ids.instagram)).length, 0);
        },
      );

      await t.step("WhatsApp Embedded Signup: the number must belong to the business account", async () => {
        const complete = (nonce: string, phone: string) =>
          handle(
            new Request("https://x/functions/v1/channel-oauth/whatsapp/complete", {
              method: "POST",
              body: JSON.stringify({
                state: nonce,
                code: "wa-code",
                waba_id: "200100",
                phone_number_id: phone,
                provider: ids.whatsapp,
              }),
            }),
          );
        assertEquals(
          (await complete(await begin(a, ids.whatsapp), "399900")).status,
          400,
          "a number outside the WABA is refused",
        );
        const okRes = await complete(await begin(a, ids.whatsapp), "300100");
        assertEquals(okRes.status, 200, JSON.stringify(logs.slice(-3)));
        const [c] = await conns(a.store, ids.whatsapp);
        assertEquals([c.external_account_id, c.state, c.provider_meta.waba_id], [
          "300100",
          "connected",
          "200100",
        ]);
        assert(
          requests.some((r) => r.path === "/v26.0/200100/subscribed_apps" && r.auth === `Bearer ${WA_TOKEN}`),
        );
        const page = await handle(
          new Request(`https://x/functions/v1/channel-oauth/signup/whatsapp?state=${"a".repeat(64)}`),
        );
        assert(
          (await page.text()).includes("cfg-signup"),
          "the hosted signup page uses the signup configuration",
        );
      });

      await t.step(
        "TikTok: the business account is connected with a refresh token; refresh keeps it alive",
        async () => {
          const nonce = await begin(a, ids.tiktok);
          assertEquals((await callback(ids.tiktok, `auth_code=tt-code&state=${nonce}`)).status, 200);
          const [c] = await conns(a.store, ids.tiktok);
          assertEquals([c.external_account_id, c.state, c.refresh], ["open-1", "connected", true]);
          await admin`update app.connections set expires_at = now() + interval '10 minutes' where provider_id = ${ids.tiktok}`;
          const app = { clientId: "ck-1", clientSecret: TT_SECRET, authorizeUrl: null, baseURL: base };
          const refreshers = { [ids.tiktok]: (rt: string) => refreshTikTokToken(app, rt) };
          assertEquals(await runRefreshCycle({ db: sender, refreshers, log: (e) => logs.push(e) }), {
            refreshed: 1,
            failed: 0,
          });
          const [after] = await conns(a.store, ids.tiktok);
          assert(
            new Date(after.expires_at).getTime() > Date.now() + 20 * 3600 * 1000,
            "a fresh one-day token",
          );
          await admin`update app.connections set expires_at = now() + interval '10 minutes' where provider_id = ${ids.tiktok}`;
          ttRefreshOk = false;
          assertEquals(await runRefreshCycle({ db: sender, refreshers, log: (e) => logs.push(e) }), {
            refreshed: 0,
            failed: 1,
          });
          const list = await rpc("list_connections", { p_store_id: a.store }, a.token);
          const tt = list.data.items.find((i: { provider: string }) => i.provider === ids.tiktok);
          assertEquals([tt.ui_state, tt.attention_reason, tt.can_send], [
            "error",
            "token_refresh_failed",
            false,
          ]);
        },
      );

      await t.step("connection states for the app: connected, unavailable, disconnected", async () => {
        const list = await rpc("list_connections", { p_store_id: a.store }, a.token);
        const ig = list.data.items.find((i: { provider: string }) => i.provider === ids.instagram);
        assertEquals([ig.ui_state, ig.can_send, ig.username], ["connected", true, "shop"]);
        const providers = await rpc("list_channel_providers", { p_store_id: b.store }, b.token);
        const real = providers.data.items.filter((p: { provider: string }) =>
          ["instagram", "messenger", "whatsapp", "telegram", "viber", "tiktok"].includes(p.provider)
        );
        assertEquals(real.length, 6);
        assert(
          real.every((p: { ui_state: string; can_connect: boolean }) =>
            p.ui_state === "unavailable" && !p.can_connect
          ),
          "the real providers are not released: unavailable, not connectable",
        );
        const fixture = providers.data.items.find((p: { provider: string }) => p.provider === ids.instagram);
        assertEquals([fixture.ui_state, fixture.can_connect], ["disconnected", true]);
      });

      await t.step("no token, code, state or secret reaches the logs", () => {
        const text = JSON.stringify(logs);
        for (
          const s of [
            APP_SECRET,
            TT_SECRET,
            PAGE_TOKEN_1,
            PAGE_TOKEN_2,
            USER_SHORT,
            USER_LONG,
            WA_TOKEN,
            "good-ig",
            "tt-code",
          ]
        ) {
          assertFalse(text.includes(s), "a secret reached the logs");
        }
      });
    } finally {
      await admin.unsafe("alter role aisellia_channel_connector password null").catch(() => {});
      await admin.unsafe("alter role aisellia_channel_sender password null").catch(() => {});
      for (const id of Object.values(ids)) {
        await admin`update app.providers set status = 'suspended' where id = ${id}`.catch(() => {});
      }
      await admin.end();
      await api.shutdown();
    }
  },
});
