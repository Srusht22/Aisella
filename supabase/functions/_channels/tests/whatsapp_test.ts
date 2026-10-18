// WhatsApp: outbound conformance against a local Cloud API imitation, the request, WhatsApp error
// codes, and the inbound kit through the database's meta_sha256 / whatsapp_cloud path.
import { assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import type { StubMode } from "../conformance.ts";
import { conformanceSuite } from "../conformance.ts";
import { WhatsAppAdapter } from "../providers/whatsapp.ts";
import { hmacSha256Hex } from "../text.ts";
import { inboundConformanceSuite, type InboundConnection, jsonString } from "./inbound_kit.ts";
import { bearer, imitationFixture, type ImitationSpec } from "./provider_imitation.ts";

const TOKEN = `EAAwa${crypto.randomUUID().replace(/-/g, "")}`;
const waError = (status: number, code: number) =>
  Response.json({ error: { message: "secret detail", type: "OAuthException", code, fbtrace_id: "x" } }, {
    status,
  });
const spec: ImitationSpec = {
  text: (b) => b.text?.body,
  credential: bearer,
  respond: (mode: StubMode, n: number) => {
    switch (mode) {
      case "429":
        return waError(400, 130429);
      case "500":
        return waError(500, 131016);
      case "window_closed":
        return waError(400, 131047);
      case "blocked":
        return waError(400, 131026);
      case "bad_token":
        return waError(401, 190);
      default:
        return Response.json({
          messaging_product: "whatsapp",
          contacts: [{ input: "9647501112233", wa_id: "9647501112233" }],
          messages: [{ id: `wamid.HBgM${n}` }],
        });
    }
  },
};
const fixture = () =>
  imitationFixture(spec, (baseURL) => new WhatsAppAdapter({ baseURL }), {
    credential: TOKEN,
    recipient: "9647501112233",
    accountId: "106540352242922",
  });

conformanceSuite("whatsapp", fixture);

Deno.test("whatsapp: a text message from the business number, no link preview, token as Bearer", async () => {
  const fx = await fixture();
  try {
    const r = await fx.adapter.send(
      {
        text: "https://shop.example is open",
        textSha256: "-",
        recipient: "9647501112233",
        accountId: "106540352242922",
      },
      TOKEN,
      { timeoutMs: 5000 },
    );
    assertEquals(r, { kind: "sent", providerMessageId: "wamid.HBgM1" });
    const req = fx.imitation.received[0];
    assertEquals(req.url.pathname, "/v26.0/106540352242922/messages");
    assertFalse(req.url.href.includes(TOKEN));
    assertEquals(JSON.parse(new TextDecoder().decode(req.raw)), {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: "9647501112233",
      type: "text",
      text: { preview_url: false, body: "https://shop.example is open" },
    });
  } finally {
    await fx.close();
  }
});

Deno.test("whatsapp: ids that are not plain numbers are refused before any request", async () => {
  let called = false;
  const adapter = new WhatsAppAdapter({
    fetchFn: () => {
      called = true;
      return Promise.resolve(Response.json({}));
    },
  });
  const send = (accountId: string, recipient: string) =>
    adapter.send({ text: "x", textSha256: "-", recipient, accountId }, TOKEN, { timeoutMs: 1000 });
  assertEquals(await send("../me", "9647501112233"), { kind: "permanent", code: "invalid_account" });
  assertEquals(await send("106540352242922", "+964 750"), { kind: "permanent", code: "invalid_recipient" });
  assertFalse(called);
});

Deno.test("whatsapp: policy restrictions and missing permissions are permanent", async () => {
  for (
    const [code, expected] of [
      [368, "account_restricted"],
      [131031, "account_restricted"],
      [131005, "permission_missing"],
      [131049, "marketing_limit"],
    ] as const
  ) {
    const adapter = new WhatsAppAdapter({ fetchFn: () => Promise.resolve(waError(400, code)) });
    assertEquals(
      await adapter.send(
        { text: "x", textSha256: "-", recipient: "9647501112233", accountId: "1065403522" },
        TOKEN,
        {
          timeoutMs: 1000,
        },
      ),
      { kind: "permanent", code: expected },
    );
  }
});

const appSecret = `wa-app-secret-${crypto.randomUUID()}`;
const body = (c: InboundConnection, o: { text: string; id: string; user: string; escaped: boolean }) =>
  new TextEncoder().encode(
    `{"object":"whatsapp_business_account","entry":[{"id":"WABA1","changes":[{"field":"messages","value":{` +
      `"messaging_product":"whatsapp","metadata":{"display_phone_number":"9647500000000","phone_number_id":"${c.accountId}"},` +
      `"contacts":[{"profile":{"name":"Customer"},"wa_id":"${o.user}"}],"messages":[{"from":"${o.user}","id":"${o.id}",` +
      `"timestamp":"${Math.floor(Date.now() / 1000)}","type":"text","text":{"body":${
        jsonString(o.text, o.escaped)
      }}}]}}]}]}`,
  );

inboundConformanceSuite("whatsapp", {
  scheme: "meta_sha256",
  format: "whatsapp_cloud",
  providerSecrets: { app_secret: appSecret, verify_token: `vt-${crypto.randomUUID()}` },
  makeAdapter: (provider) => new WhatsAppAdapter({ provider }),
  connections: [
    { accountId: `10654${Date.now()}`, credential: TOKEN },
    { accountId: `10655${Date.now()}`, credential: TOKEN },
  ],
  body,
  sign: async (raw, _c, wrong) => ({
    "x-hub-signature-256": `sha256=${await hmacSha256Hex(wrong ? `${appSecret}-x` : appSecret, raw)}`,
  }),
  messageId: (id) => id,
  roundtrip: {
    spec,
    makeAdapter: (provider, baseURL) => new WhatsAppAdapter({ provider, baseURL }),
    recipient: (user) => user,
  },
});
