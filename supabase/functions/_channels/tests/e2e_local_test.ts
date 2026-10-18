// End to end on the LOCAL stack only (AISELLIA_E2E=1): a signed stub webhook → ingest role →
// processor → live conversation; the seller authorizes en / ckb / ar replies through PostgREST with
// their JWT → sender role → stub provider receives the exact bytes; a timeout stays unknown.
// The two channel roles get random passwords for the test and lose them afterwards.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import postgres from "postgres";
import { handleWebhook } from "../ingest.ts";
import { PostgresIngestDb, PostgresSenderDb } from "../db.ts";
import { runSend } from "../send.ts";
import { signStub, StubProvider } from "../stub_provider.ts";
import { sha256Hex } from "../text.ts";
import { SAMPLE_TEXTS } from "../conformance.ts";
import { startStubServer } from "./stub_server.ts";
import { randomSecret } from "./stub_fixture.ts";
import { ADMIN_DB, assertLocal, b64, createSeller, rpc, uuid } from "../../ai-assist/tests/local_stack.ts";

Deno.test({
  name: "local end to end: verified ingest, seller-authorized exact-text sends, unknown never resent",
  ignore: Deno.env.get("AISELLIA_E2E") !== "1",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn(t) {
    assertLocal();
    const admin = postgres(ADMIN_DB, { max: 1, onnotice: () => {} });
    const pw = {
      ingest: b64(crypto.getRandomValues(new Uint8Array(24))),
      sender: b64(crypto.getRandomValues(new Uint8Array(24))),
    };
    const provider = `e2e_${uuid().slice(0, 8).replace(/-/g, "")}`;
    const appSecret = randomSecret();
    const credential = `cred-${uuid()}`;
    const server = startStubServer();
    const logs: Record<string, unknown>[] = [];
    const log = (e: Record<string, unknown>) => logs.push(e);
    try {
      await admin.unsafe(`alter role aisellia_channel_ingest password '${pw.ingest}'`);
      await admin.unsafe(`alter role aisellia_channel_sender password '${pw.sender}'`);
      const url = (role: string, p: string) =>
        `postgresql://${role}:${encodeURIComponent(p)}@127.0.0.1:54322/postgres`;
      const ingestDb = new PostgresIngestDb(url("aisellia_channel_ingest", pw.ingest));
      const senderDb = new PostgresSenderDb(url("aisellia_channel_sender", pw.sender));
      const adapter = new StubProvider({ provider, appSecret, baseURL: server.url });

      // Registry, seller, a TEST connection holding a Vault credential (all local).
      await admin`insert into app.providers (id, display_name, status) values (${provider}, 'E2E stub', 'in_development')`;
      await admin`insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on) values
        (${provider}, 'outbound_text', 'true', 'verified', 'https://stub.invalid/docs', current_date),
        (${provider}, 'reply_window_hours', '24', 'verified', 'https://stub.invalid/docs', current_date)`;
      const seller = await createSeller(admin, {
        tag: "mc2",
        storeName: "MC-2 Shop",
        zones: [],
        products: [],
      });
      const account = `acct-${uuid()}`;
      const [conn] =
        await admin`insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at, credential_ref)
        values (${seller.store}, ${provider}, ${account}, 'connected', true, now(),
                vault.create_secret(${credential}, ${"mc2-e2e-" + uuid()})) returning id`;

      let conversation = "";
      await t.step(
        "a signed webhook is stored by the ingest role and becomes a live conversation",
        async () => {
          const raw = new TextEncoder().encode(JSON.stringify({
            event_id: `ev-${uuid()}`,
            entries: [{
              type: "message",
              account,
              from: "cust-e2e",
              id: `in-${uuid()}`,
              text: SAMPLE_TEXTS.ckb,
              name: "Customer",
            }],
          }));
          const forged = await handleWebhook(
            new Request("http://local/webhook", {
              method: "POST",
              body: raw,
              headers: await signStub(randomSecret(), raw),
            }),
            { adapter, db: ingestDb, log },
          );
          assertEquals(forged.status, 401, "a forged signature is rejected");
          const res = await handleWebhook(
            new Request("http://local/webhook", {
              method: "POST",
              body: raw,
              headers: await signStub(appSecret, raw),
            }),
            { adapter, db: ingestDb, log },
          );
          assertEquals(res.status, 200);
          const again = await handleWebhook(
            new Request("http://local/webhook", {
              method: "POST",
              body: raw,
              headers: await signStub(appSecret, raw),
            }),
            { adapter, db: ingestDb, log },
          );
          assertEquals(again.status, 200, "a redelivery is acknowledged");
          await admin`select internal.channel_process_batch()`;
          const rows =
            await admin`select c.id, c.store_id, m.body from app.conversations c join app.messages m on m.conversation_id = c.id
                                  where c.connection_id = ${conn.id} and m.origin = 'channel_in'`;
          assertEquals(rows.length, 1, "one message despite the redelivery");
          assertEquals(rows[0].store_id, seller.store);
          assertEquals(new TextEncoder().encode(rows[0].body), new TextEncoder().encode(SAMPLE_TEXTS.ckb));
          conversation = rows[0].id;
        },
      );

      for (const [lang, text] of Object.entries(SAMPLE_TEXTS)) {
        await t.step(`${lang}: the seller authorizes, the sender submits exactly those bytes`, async () => {
          const auth = await rpc("send_message", {
            p_store_id: seller.store,
            p_conversation_id: conversation,
            p_text: text,
            p_suggestion_id: null,
            p_kind: "reply",
            p_order_id: null,
            p_idempotency_key: uuid(),
          }, seller.token);
          assert(auth.ok, JSON.stringify(auth.error));
          assertEquals(auth.data.text_sha256, await sha256Hex(text));
          const before = server.received.length;
          const out = await runSend(auth.data.send_request_id, {
            db: senderDb,
            adapters: { [provider]: adapter },
            log,
          });
          assertEquals(out.state, "sent");
          assertEquals(
            server.textBytes(before),
            new TextEncoder().encode(text),
            "byte-identical at the provider",
          );
          assertEquals(server.received[before].auth, `Bearer ${credential}`, "the Vault credential was used");
          const [row] =
            await admin`select s.state, m.delivery_state, m.external_message_id is not null as has_id,
                                           convert_to(m.body, 'UTF8') = convert_to(${text}, 'UTF8') as same
                                      from app.send_requests s join app.messages m on m.id = s.message_id
                                     where s.id = ${auth.data.send_request_id}`;
          assertEquals([row.state, row.delivery_state, row.has_id, row.same], ["sent", "sent", true, true]);
        });
      }

      await t.step("a provider timeout is unknown and the send is never claimed again", async () => {
        const auth = await rpc("send_message", {
          p_store_id: seller.store,
          p_conversation_id: conversation,
          p_text: "timeout please",
          p_suggestion_id: null,
          p_kind: "reply",
          p_order_id: null,
          p_idempotency_key: uuid(),
        }, seller.token);
        server.setMode("timeout");
        const out = await runSend(auth.data.send_request_id, {
          db: senderDb,
          adapters: { [provider]: adapter },
          log,
          timeoutMs: 300,
        });
        server.setMode("ok");
        assertEquals(out.state, "unknown");
        const second = await runSend(auth.data.send_request_id, {
          db: senderDb,
          adapters: { [provider]: adapter },
          log,
        });
        assertEquals(second.state, "not_claimed");
      });

      await t.step(
        "the AI worker's credentials cannot send (no grant), and logs hold no text or secret",
        async () => {
          const logText = JSON.stringify(logs);
          for (
            const s of [
              appSecret,
              credential,
              pw.ingest,
              pw.sender,
              SAMPLE_TEXTS.en,
              SAMPLE_TEXTS.ckb.slice(0, 8),
            ]
          ) {
            assertFalse(logText.includes(s), "a secret or message text reached the logs");
          }
          const [g] =
            await admin`select has_function_privilege('aisellia_ai_worker', 'api.channel_claim_send(uuid)', 'EXECUTE') as a,
                                       has_function_privilege('aisellia_ai_worker', 'api.send_message(uuid,uuid,text,uuid,text,uuid,uuid)', 'EXECUTE') as b`;
          assertEquals([g.a, g.b], [false, false]);
        },
      );
    } finally {
      await admin.unsafe("alter role aisellia_channel_ingest password null").catch(() => {});
      await admin.unsafe("alter role aisellia_channel_sender password null").catch(() => {});
      // The test provider is suspended so nothing in the local database can use it afterwards.
      await admin`update app.providers set status = 'suspended' where id = ${provider}`.catch(() => {});
      await admin.end();
      await server.close();
    }
  },
});
