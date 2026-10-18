// Instagram: outbound conformance against a local Graph API imitation, request details, and the
// inbound kit through the database's meta_sha256 / meta_instagram path. No network, no real account.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import { conformanceSuite } from "../conformance.ts";
import { InstagramAdapter } from "../providers/instagram.ts";
import { hmacSha256Hex } from "../text.ts";
import { inboundConformanceSuite, type InboundConnection, jsonString } from "./inbound_kit.ts";
import { bearer, graphResponses, imitationFixture, type ImitationSpec } from "./provider_imitation.ts";

const TOKEN = `EAAtest${crypto.randomUUID().replace(/-/g, "")}`;
export const instagramSpec: ImitationSpec = {
  text: (b) => b.message?.text,
  credential: bearer,
  respond: graphResponses((n) => ({ recipient_id: "1784", message_id: `aWdfZAG1faXRlbTo${n}` })),
};
const fixture = () =>
  imitationFixture(instagramSpec, (baseURL) => new InstagramAdapter({ baseURL }), {
    credential: TOKEN,
    recipient: "6203145623143021",
    accountId: "17841400000000001",
  });

conformanceSuite("instagram", fixture);

Deno.test("instagram: the Send API request (path, Bearer token, body) and the token never in the URL", async () => {
  const fx = await fixture();
  try {
    const r = await fx.adapter.send(
      { text: "سڵاو", textSha256: "-", recipient: "6203145623143021", accountId: "17841400000000001" },
      TOKEN,
      { timeoutMs: 5000 },
    );
    assertEquals(r, { kind: "sent", providerMessageId: "aWdfZAG1faXRlbTo1" });
    const req = fx.imitation.received[0];
    assertEquals(req.url.pathname, "/v21.0/me/messages");
    assertFalse(req.url.href.includes(TOKEN));
    assertEquals(JSON.parse(new TextDecoder().decode(req.raw)), {
      recipient: { id: "6203145623143021" },
      message: { text: "سڵاو" },
    });
  } finally {
    await fx.close();
  }
});

Deno.test("instagram: no credential sends nothing; an answer without a message id is unknown", async () => {
  const adapter = new InstagramAdapter({
    baseURL: "http://127.0.0.1:9",
    fetchFn: () => Promise.resolve(Response.json({ recipient_id: "1" })),
  });
  const msg = { text: "x", textSha256: "-", recipient: "1", accountId: "2" };
  assertEquals(await adapter.send(msg, null, { timeoutMs: 1000 }), {
    kind: "permanent",
    code: "no_credential",
  });
  assertEquals(await adapter.send(msg, TOKEN, { timeoutMs: 1000 }), {
    kind: "unknown",
    code: "no_message_id",
  });
  assert(new InstagramAdapter().webhookHeaders.includes("x-hub-signature-256"));
});

const appSecret = `ig-app-secret-${crypto.randomUUID()}`;
export const metaBody =
  (object: string) =>
  (c: InboundConnection, o: { text: string; id: string; user: string; escaped: boolean }) =>
    new TextEncoder().encode(
      `{"object":"${object}","entry":[{"id":"${c.accountId}","time":${Date.now()},"messaging":[{"sender":{"id":"${o.user}"},` +
        `"recipient":{"id":"${c.accountId}"},"timestamp":${Date.now()},"message":{"mid":"${o.id}","text":${
          jsonString(o.text, o.escaped)
        }}}]}]}`,
    );
export const metaSign =
  (secret: string) => async (raw: Uint8Array, _c: InboundConnection, wrong?: boolean) => ({
    "x-hub-signature-256": `sha256=${await hmacSha256Hex(wrong ? `${secret}-wrong` : secret, raw)}`,
  });

inboundConformanceSuite("instagram", {
  scheme: "meta_sha256",
  format: "meta_instagram",
  providerSecrets: { app_secret: appSecret, verify_token: `vt-${crypto.randomUUID()}`, app_id: "1234567890" },
  makeAdapter: (provider) => new InstagramAdapter({ provider }),
  connections: [{ accountId: `1784${Date.now()}1`, credential: TOKEN }, {
    accountId: `1784${Date.now()}2`,
    credential: TOKEN,
  }],
  body: metaBody("instagram"),
  sign: metaSign(appSecret),
  messageId: (id) => id,
  roundtrip: {
    spec: instagramSpec,
    makeAdapter: (provider, baseURL) => new InstagramAdapter({ provider, baseURL }),
    recipient: (user) => user,
  },
});
