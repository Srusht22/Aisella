// Connecting a bot end to end on the LOCAL stack (AISELLIA_E2E=1): the seller's nonce, the provider's
// identity check, the connector role, the webhook registration, then real traffic through the
// database's per-bot verification; another store's takeover attempt, a reused nonce, a rejected token
// and disconnection. A fixture provider is configured like Telegram but released to "pilot" for the
// test only; the real Telegram row stays in development, where connecting is refused.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import postgres from "postgres";
import { handleConnect } from "../connect.ts";
import { PostgresConnectorDb, PostgresIngestDb } from "../db.ts";
import { handleWebhook } from "../ingest.ts";
import { TelegramAdapter } from "../providers/telegram.ts";
import { ADMIN_DB, assertLocal, b64, createSeller, rpc, uuid } from "../../ai-assist/tests/local_stack.ts";

Deno.test({
  name: "bot connect end to end: provider-confirmed identity, no takeover, single-use nonce, disconnect",
  ignore: Deno.env.get("AISELLIA_E2E") !== "1",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn(t) {
    assertLocal();
    const admin = postgres(ADMIN_DB, { max: 1, onnotice: () => {} });
    const pw = {
      connector: b64(crypto.getRandomValues(new Uint8Array(24))),
      ingest: b64(crypto.getRandomValues(new Uint8Array(24))),
    };
    const provider = `t_tgconnect_${uuid().slice(0, 6)}`;
    const BOT_ID = Math.floor(5e9 + Math.random() * 1e9);
    const TOKEN = `${BOT_ID}:AA${crypto.randomUUID().replace(/-/g, "")}`;
    const OTHER_TOKEN = `${BOT_ID + 1}:AA${crypto.randomUUID().replace(/-/g, "")}`;
    const hooks: { token: string; url: string; secret: string }[] = [];
    // A local imitation of the Bot API's getMe and setWebhook.
    const api = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen: () => {} }, async (req) => {
      const path = new URL(req.url).pathname;
      const token = path.split("/")[1]?.slice(3) ?? "";
      const body = await req.json().catch(() => ({}));
      const known = token === TOKEN;
      if (path.endsWith("/getMe")) {
        return known
          ? Response.json({
            ok: true,
            result: { id: BOT_ID, is_bot: true, first_name: "Shop Bot", username: "shop_bot" },
          })
          : Response.json({ ok: false, error_code: 401, description: "Unauthorized" }, { status: 401 });
      }
      if (path.endsWith("/setWebhook")) {
        hooks.push({ token, url: body.url, secret: body.secret_token });
        return Response.json({ ok: true, result: true });
      }
      return Response.json({ ok: false }, { status: 404 });
    });
    const logs: Record<string, unknown>[] = [];
    const log = (e: Record<string, unknown>) => logs.push(e);
    try {
      await admin.unsafe(`alter role aisellia_channel_connector password '${pw.connector}'`);
      await admin.unsafe(`alter role aisellia_channel_ingest password '${pw.ingest}'`);
      const url = (role: string, p: string) =>
        `postgresql://${role}:${encodeURIComponent(p)}@127.0.0.1:54322/postgres`;
      const db = new PostgresConnectorDb(url("aisellia_channel_connector", pw.connector));
      const ingest = new PostgresIngestDb(url("aisellia_channel_ingest", pw.ingest));
      await admin`insert into app.providers (id, display_name, status, webhook_scheme, payload_format)
                  values (${provider}, 'Connect fixture', 'pilot', 'telegram_token', 'telegram_bot')`;
      await admin`insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on)
                  values (${provider}, 'reply_window_hours', 'null', 'assumption', null, null)`;
      const adapter = new TelegramAdapter({ provider, baseURL: `http://127.0.0.1:${api.addr.port}` });
      const adapters = { [provider]: adapter };
      const a = await createSeller(admin, { tag: "conn-a", storeName: "Connect A", zones: [], products: [] });
      const b = await createSeller(admin, { tag: "conn-b", storeName: "Connect B", zones: [], products: [] });
      const begin = async (s: { store: string; token: string }) =>
        (await rpc("begin_channel_connect", { p_store_id: s.store, p_provider: provider }, s.token)).data
          ?.nonce as string;
      const connect = async (body: Record<string, unknown>) => {
        const res = await handleConnect(
          new Request("http://local/channel-connect", { method: "POST", body: JSON.stringify(body) }),
          {
            db,
            adapters,
            webhookBase: "https://project.example/functions/v1/channel-webhook",
            log,
            timeoutMs: 3000,
          },
        );
        return { status: res.status, body: await res.json() };
      };

      let connectionId = "";
      let nonceA = "";
      await t.step(
        "the seller's nonce + a token the provider confirms → a connected bot with a registered webhook",
        async () => {
          nonceA = await begin(a);
          assert(/^[0-9a-f]{64}$/.test(nonceA));
          const r = await connect({ provider, nonce: nonceA, token: TOKEN });
          assertEquals(r.status, 200, JSON.stringify(r.body));
          connectionId = r.body.data.connection_id;
          const [c] = await admin`select store_id, external_account_id, display_name, state, is_test,
                                       credential_ref is not null as cred, webhook_secret_ref is not null as secret
                                  from app.connections where id = ${connectionId}`;
          assertEquals([
            c.store_id,
            c.external_account_id,
            c.display_name,
            c.state,
            c.is_test,
            c.cred,
            c.secret,
          ], [
            a.store,
            String(BOT_ID),
            "Shop Bot",
            "connected",
            false,
            true,
            true,
          ]);
          assertEquals(
            hooks.at(-1)!.url,
            `https://project.example/functions/v1/channel-webhook/${provider}/${connectionId}`,
          );
          assert(/^[A-Za-z0-9_-]{40,}$/.test(hooks.at(-1)!.secret));
        },
      );

      await t.step("the registered secret authenticates the bot's webhooks; nothing else does", async () => {
        const raw = new TextEncoder().encode(
          `{"update_id":1,"message":{"message_id":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"hello"}}`,
        );
        const deliver = (secret: string) =>
          handleWebhook(
            new Request("http://local/w", {
              method: "POST",
              body: raw.slice(),
              headers: { "content-type": "application/json", "x-telegram-bot-api-secret-token": secret },
            }),
            { adapter, db: ingest, log, connectionHint: connectionId },
          );
        assertEquals((await deliver("guessed-secret-guessed-secret-guessed")).status, 401);
        assertEquals((await deliver(hooks.at(-1)!.secret)).status, 200);
        await admin`select internal.channel_process_batch()`;
        const [m] =
          await admin`select c.store_id from app.messages m join app.conversations c on c.id = m.conversation_id
                                 where m.connection_id = ${connectionId} and m.external_message_id = '77:1'`;
        assertEquals(m.store_id, a.store);
      });

      await t.step("a nonce works once", async () => {
        const r = await connect({ provider, nonce: nonceA, token: TOKEN });
        assertEquals([r.status, r.body.error.code], [404, "NOT_FOUND"]);
      });

      await t.step("another store cannot take over a connected bot, even with its token", async () => {
        const r = await connect({ provider, nonce: await begin(b), token: TOKEN });
        assertEquals([r.status, r.body.error.code], [409, "ACCOUNT_IN_USE"]);
        const [n] = await admin`select count(*)::int as n from app.connections where store_id = ${b.store}`;
        assertEquals(n.n, 0);
      });

      await t.step("a token the provider rejects creates nothing", async () => {
        const before = hooks.length;
        const r = await connect({ provider, nonce: await begin(b), token: OTHER_TOKEN });
        assertEquals([r.status, r.body.error.code], [400, "TOKEN_REJECTED"]);
        assertEquals(hooks.length, before, "no webhook was registered");
      });

      await t.step(
        "disconnecting erases the secrets; the bot's webhook URL then refuses deliveries",
        async () => {
          const [refs] =
            await admin`select credential_ref, webhook_secret_ref from app.connections where id = ${connectionId}`;
          const r = await rpc(
            "disconnect_channel",
            { p_store_id: a.store, p_connection_id: connectionId },
            a.token,
          );
          assert(r.ok, JSON.stringify(r.error));
          const [left] = await admin`select count(*)::int as n from vault.secrets
                                    where id in (${refs.credential_ref}, ${refs.webhook_secret_ref})`;
          assertEquals(left.n, 0);
          const raw = new TextEncoder().encode(
            `{"update_id":2,"message":{"message_id":2,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"x"}}`,
          );
          const res = await handleWebhook(
            new Request("http://local/w", {
              method: "POST",
              body: raw,
              headers: {
                "content-type": "application/json",
                "x-telegram-bot-api-secret-token": hooks.at(-1)!.secret,
              },
            }),
            { adapter, db: ingest, log, connectionHint: connectionId },
          );
          assertEquals(res.status, 401);
        },
      );

      await t.step(
        "the real Telegram provider (in development) cannot be connected by a seller",
        async () => {
          const r = await rpc(
            "begin_channel_connect",
            { p_store_id: a.store, p_provider: "telegram" },
            a.token,
          );
          assertEquals(r.error?.code, "CHANNEL_UNAVAILABLE");
        },
      );

      await t.step("no token, nonce or secret reaches the logs", () => {
        const text = JSON.stringify(logs);
        for (
          const s of [
            TOKEN,
            OTHER_TOKEN,
            nonceA,
            ...hooks.map((h) => h.secret),
            pw.connector,
            pw.ingest,
          ]
        ) {
          assertFalse(text.includes(s), "a secret reached the logs");
        }
      });
    } finally {
      await admin.unsafe("alter role aisellia_channel_connector password null").catch(() => {});
      await admin.unsafe("alter role aisellia_channel_ingest password null").catch(() => {});
      await admin`update app.providers set status = 'suspended' where id = ${provider}`.catch(() => {});
      await admin.end();
      await api.shutdown();
    }
  },
});
