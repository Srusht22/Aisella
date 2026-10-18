// The shared INBOUND conformance kit, against the LOCAL database (AISELLIA_E2E=1): since the security
// review (O6) the database verifies and normalises webhooks, so a provider's inbound behaviour is
// proven there, through the real Edge handler and the real aisellia_channel_ingest login role.
//
// For each provider fixture it checks: a signed body becomes a live message byte for byte (Sorani,
// Arabic, \u-escaped bodies); a wrong secret, a missing signature, a changed byte and a re-serialised
// body are refused and nothing is stored; a redelivery stores one message; per-bot webhooks cannot be
// delivered through another connection's URL; and no secret or text reaches the logs.
//
// Each run registers a fresh fixture provider configured exactly like the real one (same scheme and
// payload format), so nothing depends on, or changes, the real providers' registry rows.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import postgres from "postgres";
import type { ProviderAdapter } from "../adapter.ts";
import { PostgresIngestDb, PostgresSenderDb } from "../db.ts";
import { handleWebhook } from "../ingest.ts";
import { SAMPLE_TEXTS } from "../conformance.ts";
import { runSend } from "../send.ts";
import { ADMIN_DB, assertLocal, b64, createSeller, rpc, uuid } from "../../ai-assist/tests/local_stack.ts";
import { type ImitationSpec, startImitation } from "./provider_imitation.ts";

export interface InboundConnection {
  /** The provider account id (page id, phone number id, bot id, …). */
  accountId: string;
  /** Per-connection secrets, stored in the local Vault for the test. */
  credential?: string;
  webhookSecret?: string;
}

export interface InboundFixture {
  /** Registry configuration of the real provider. */
  scheme: string;
  format: string;
  /** Provider-wide secrets by Vault name suffix (app_secret, verify_token, client_secret, app_id). */
  providerSecrets: Record<string, string>;
  makeAdapter(provider: string): ProviderAdapter;
  /** Two connections (two stores), each with its own account and secrets. */
  connections: [InboundConnection, InboundConnection];
  /** A raw webhook body with one inbound text message, as the provider sends it. */
  body(conn: InboundConnection, o: { text: string; id: string; user: string; escaped: boolean }): Uint8Array;
  /** Headers signing `raw` for `conn` (or with a wrong secret). */
  sign(raw: Uint8Array, conn: InboundConnection, wrong?: boolean): Promise<Record<string, string>>;
  /** The external message id the database derives for message `id` from `user`. */
  messageId(id: string, user: string): string;
  /**
   * False for schemes that authenticate the sender but do not sign the body (Telegram's secret token):
   * a changed byte cannot be detected there (TLS protects the body in transit). Default true.
   */
  signsBody?: boolean;
  /**
   * Full round trip: the seller replies through PostgREST, the sender role submits through the real
   * adapter to a local imitation of the provider's API. The fixture provider gets a VERIFIED
   * outbound_text capability for the test only (the real provider's rows stay as they are).
   */
  roundtrip?: {
    spec: ImitationSpec;
    makeAdapter(provider: string, baseURL: string): ProviderAdapter;
    /** The recipient id the provider expects for inbound user `user` (e.g. a chat id). */
    recipient(user: string): string;
  };
}

export const escapeNonAscii = (s: string) =>
  s.replace(/[\u0080-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`).replace(
    /\n/g,
    "\\n",
  );

/** A JSON string literal, optionally with every non-ASCII character escaped as \uXXXX. */
export const jsonString = (s: string, escaped: boolean) =>
  escaped ? `"${escapeNonAscii(s)}"` : JSON.stringify(s);

export function inboundConformanceSuite(name: string, fx: InboundFixture) {
  Deno.test({
    name: `[${name}] inbound conformance on the local database`,
    ignore: Deno.env.get("AISELLIA_E2E") !== "1",
    sanitizeResources: false,
    sanitizeOps: false,
    async fn(t) {
      assertLocal();
      const admin = postgres(ADMIN_DB, { max: 1, onnotice: () => {} });
      const pw = b64(crypto.getRandomValues(new Uint8Array(24)));
      const spw = b64(crypto.getRandomValues(new Uint8Array(24)));
      const provider = `t_${name.replace(/[^a-z]/g, "").slice(0, 12)}_${uuid().slice(0, 6)}`;
      const logs: Record<string, unknown>[] = [];
      const log = (e: Record<string, unknown>) => logs.push(e);
      const adapter = fx.makeAdapter(provider);
      try {
        await admin.unsafe(`alter role aisellia_channel_ingest password '${pw}'`);
        await admin.unsafe(`alter role aisellia_channel_sender password '${spw}'`);
        const db = new PostgresIngestDb(
          `postgresql://aisellia_channel_ingest:${encodeURIComponent(pw)}@127.0.0.1:54322/postgres`,
        );
        await admin`insert into app.providers (id, display_name, status, webhook_scheme, payload_format)
                    values (${provider}, ${
          "Inbound kit " + name
        }, 'in_development', ${fx.scheme}, ${fx.format})`;
        await admin`insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on)
                    values (${provider}, 'reply_window_hours', '24', 'assumption', null, null)`;
        for (const [k, v] of Object.entries(fx.providerSecrets)) {
          await admin`select vault.create_secret(${v}, ${`aisellia/provider/${provider}/${k}`})`;
        }
        const conns: string[] = [];
        const sellers: { store: string; token: string }[] = [];
        for (const [i, c] of fx.connections.entries()) {
          const seller = await createSeller(admin, {
            tag: `in-${name}-${i}`,
            storeName: `Inbound ${name} ${i}`,
            zones: [],
            products: [],
          });
          const [row] = await admin`
            insert into app.connections (store_id, provider_id, external_account_id, state, is_test, connected_at,
                                         credential_ref, webhook_secret_ref)
            values (${seller.store}, ${provider}, ${c.accountId}, 'connected', true, now(),
                    ${c.credential ? admin`vault.create_secret(${c.credential})` : null},
                    ${c.webhookSecret ? admin`vault.create_secret(${c.webhookSecret})` : null})
            returning id`;
          conns.push(row.id);
          sellers.push(seller);
        }
        const [a] = fx.connections;
        const hintFor = (i: number) => adapter.perConnectionWebhook ? conns[i] : null;
        const deliver = async (raw: Uint8Array, headers: Record<string, string>, hint = hintFor(0)) =>
          (await handleWebhook(
            new Request("http://local/channel-webhook", {
              method: "POST",
              body: raw.slice(),
              headers: { "content-type": "application/json", ...headers },
            }),
            { adapter, db, log, connectionHint: hint },
          )).status;
        const process = () => admin`select internal.channel_process_batch()`;
        const stored = async () =>
          (await admin`select count(*)::int as n from app.webhook_events where provider_id = ${provider}`)[0]
            .n as number;
        const message = async (
          id: string,
          user: string,
        ) => (await admin`select m.body, c.store_id, m.connection_id from app.messages m join app.conversations c on c.id = m.conversation_id
                        where m.connection_id = any (${conns}) and m.external_message_id = ${
          fx.messageId(id, user)
        }`);

        for (const [lang, text] of [["ckb", SAMPLE_TEXTS.ckb], ["ar", SAMPLE_TEXTS.ar]] as const) {
          for (const escaped of [false, true]) {
            await t.step(
              `${lang}${
                escaped ? " (\\u-escaped body)" : ""
              }: a signed webhook becomes a live message byte for byte`,
              async () => {
                const id = `m-${lang}-${escaped}-${uuid().slice(0, 8)}`;
                const raw = fx.body(a, { text, id, user: "9647501110001", escaped });
                assertEquals(await deliver(raw, await fx.sign(raw, a)), 200);
                await process();
                const rows = await message(id, "9647501110001");
                assertEquals(rows.length, 1, "one message");
                assertEquals(rows[0].connection_id, conns[0], "it belongs to the signing connection");
                assertEquals(new TextEncoder().encode(rows[0].body), new TextEncoder().encode(text));
              },
            );
          }
        }

        await t.step(
          "a wrong secret, no signature, a changed byte and a re-serialised body are refused; nothing stored",
          async () => {
            const before = await stored();
            const raw = fx.body(a, {
              text: SAMPLE_TEXTS.ar,
              id: `m-bad-${uuid().slice(0, 8)}`,
              user: "9647501110002",
              escaped: true,
            });
            const tampered = raw.slice();
            tampered[tampered.length - 4] ^= 1;
            const reserialised = new TextEncoder().encode(
              JSON.stringify(JSON.parse(new TextDecoder().decode(raw))),
            );
            const good = await fx.sign(raw, a);
            assertEquals(await deliver(raw, await fx.sign(raw, a, true)), 401, "wrong secret");
            assertEquals(await deliver(raw, {}), 401, "no signature");
            if (fx.signsBody !== false) {
              assertEquals(await deliver(tampered, good), 401, "a changed byte");
              assertEquals(await deliver(reserialised, good), 401, "a re-serialised body");
            }
            assertEquals(await stored(), before);
          },
        );

        await t.step("a redelivered webhook stores one message", async () => {
          const id = `m-dup-${uuid().slice(0, 8)}`;
          const raw = fx.body(a, { text: SAMPLE_TEXTS.en, id, user: "9647501110003", escaped: false });
          const headers = await fx.sign(raw, a);
          assertEquals(await deliver(raw, headers), 200);
          assertEquals(await deliver(raw, headers), 200);
          await process();
          assertEquals((await message(id, "9647501110003")).length, 1);
        });

        if (adapter.perConnectionWebhook) {
          await t.step(
            "a webhook signed for one connection cannot be delivered through another's URL",
            async () => {
              const raw = fx.body(a, {
                text: "cross",
                id: `m-x-${uuid().slice(0, 8)}`,
                user: "9647501110004",
                escaped: false,
              });
              assertEquals(await deliver(raw, await fx.sign(raw, a), conns[1]), 401);
            },
          );
        } else {
          await t.step(
            "an account the provider names is routed only to the store that connected it",
            async () => {
              const b = fx.connections[1];
              const id = `m-b-${uuid().slice(0, 8)}`;
              const raw = fx.body(b, { text: "for store B", id, user: "9647501110005", escaped: false });
              assertEquals(await deliver(raw, await fx.sign(raw, b)), 200);
              await process();
              const rows = await message(id, "9647501110005");
              assertEquals(rows.length, 1);
              assertEquals(rows[0].connection_id, conns[1]);
            },
          );
        }

        if (fx.roundtrip) {
          const rt = fx.roundtrip;
          await t.step(
            "round trip: the seller's en / ckb / ar replies reach the provider byte-identical",
            async () => {
              await admin`insert into app.provider_capabilities (provider_id, capability, value, evidence, source_url, checked_on)
                        values (${provider}, 'outbound_text', 'true', 'verified', 'https://fixture.invalid/test-only', current_date)`;
              const imitation = startImitation(rt.spec);
              const sender = new PostgresSenderDb(
                `postgresql://aisellia_channel_sender:${encodeURIComponent(spw)}@127.0.0.1:54322/postgres`,
              );
              const outAdapter = rt.makeAdapter(provider, imitation.url);
              try {
                const id = `m-rt-${uuid().slice(0, 8)}`;
                const raw = fx.body(a, {
                  text: "I want to order",
                  id,
                  user: "9647501110006",
                  escaped: false,
                });
                assertEquals(await deliver(raw, await fx.sign(raw, a)), 200);
                await process();
                const [conv] = await admin`select conversation_id from app.messages
                                          where connection_id = ${conns[0]} and external_message_id = ${
                  fx.messageId(id, "9647501110006")
                }`;
                for (const text of [SAMPLE_TEXTS.en, SAMPLE_TEXTS.ckb, SAMPLE_TEXTS.ar]) {
                  const auth = await rpc("send_message", {
                    p_store_id: sellers[0].store,
                    p_conversation_id: conv.conversation_id,
                    p_text: text,
                    p_suggestion_id: null,
                    p_kind: "reply",
                    p_order_id: null,
                    p_idempotency_key: uuid(),
                  }, sellers[0].token);
                  assert(auth.ok, JSON.stringify(auth.error));
                  const before = imitation.received.length;
                  const out = await runSend(auth.data.send_request_id, {
                    db: sender,
                    adapters: { [provider]: outAdapter },
                    log,
                  });
                  assertEquals(out.state, "sent");
                  assertEquals(
                    imitation.textBytes(before),
                    new TextEncoder().encode(text),
                    "byte-identical at the provider",
                  );
                  const recipientSeen = JSON.stringify(
                    JSON.parse(new TextDecoder().decode(imitation.received[before].raw)),
                  );
                  assert(
                    recipientSeen.includes(rt.recipient("9647501110006")),
                    "addressed to the customer who wrote",
                  );
                  if (a.credential) {
                    assertEquals(
                      imitation.received[before].credential,
                      a.credential,
                      "the connection's credential",
                    );
                  }
                }
              } finally {
                await imitation.close();
              }
            },
          );
        }

        await t.step("no secret and no message text reaches the logs", () => {
          const text = JSON.stringify(logs);
          const secrets = [
            ...Object.values(fx.providerSecrets),
            ...fx.connections.flatMap((c) => [c.credential, c.webhookSecret]).filter((s): s is string => !!s),
            pw,
            spw,
          ];
          for (const s of secrets) assertFalse(text.includes(s), "a secret reached the logs");
          for (const s of Object.values(SAMPLE_TEXTS)) assertFalse(text.includes(s.trim().slice(0, 12)));
          assert(logs.some((l) => l.event === "webhook_stored"));
        });
      } finally {
        await admin.unsafe("alter role aisellia_channel_ingest password null").catch(() => {});
        await admin.unsafe("alter role aisellia_channel_sender password null").catch(() => {});
        await admin`update app.providers set status = 'suspended' where id = ${provider}`.catch(() => {});
        await admin.end();
      }
    },
  });
}
