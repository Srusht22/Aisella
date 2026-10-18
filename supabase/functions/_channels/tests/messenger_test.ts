// Messenger: outbound conformance against a local Graph imitation, the request (messaging_type
// RESPONSE), and the inbound kit through the database's meta_sha256 / meta_messenger path.
import { assertEquals } from "jsr:@std/assert@1.0.13";
import { conformanceSuite } from "../conformance.ts";
import { MessengerAdapter } from "../providers/messenger.ts";
import { inboundConformanceSuite } from "./inbound_kit.ts";
import { metaBody, metaSign } from "./meta_fixtures.ts";
import { bearer, graphResponses, imitationFixture, type ImitationSpec } from "./provider_imitation.ts";

const TOKEN = `EAAtest${crypto.randomUUID().replace(/-/g, "")}`;
const spec: ImitationSpec = {
  text: (b) => b.message?.text,
  credential: bearer,
  respond: graphResponses((n) => ({ recipient_id: "2463", message_id: `m_AG5Hz2Uq7tuwNEhXfYYKj8mJEM_${n}` })),
};
const fixture = () =>
  imitationFixture(spec, (baseURL) => new MessengerAdapter({ baseURL }), {
    credential: TOKEN,
    recipient: "24637829385",
    accountId: "1066000000000001",
  });

conformanceSuite("messenger", fixture);

Deno.test("messenger: the Send API request is a RESPONSE to the customer, token as Bearer", async () => {
  const fx = await fixture();
  try {
    await fx.adapter.send(
      { text: "Thanks!", textSha256: "-", recipient: "24637829385", accountId: "1" },
      TOKEN,
      {
        timeoutMs: 5000,
      },
    );
    const req = fx.imitation.received[0];
    assertEquals(req.url.pathname, "/v26.0/me/messages");
    assertEquals(JSON.parse(new TextDecoder().decode(req.raw)), {
      recipient: { id: "24637829385" },
      messaging_type: "RESPONSE",
      message: { text: "Thanks!" },
    });
  } finally {
    await fx.close();
  }
});

const appSecret = `fb-app-secret-${crypto.randomUUID()}`;
inboundConformanceSuite("messenger", {
  scheme: "meta_sha256",
  format: "meta_messenger",
  providerSecrets: { app_secret: appSecret, verify_token: `vt-${crypto.randomUUID()}` },
  makeAdapter: (provider) => new MessengerAdapter({ provider }),
  connections: [{ accountId: `1066${Date.now()}1`, credential: TOKEN }, {
    accountId: `1066${Date.now()}2`,
    credential: TOKEN,
  }],
  body: metaBody("page"),
  sign: metaSign(appSecret),
  messageId: (id) => id,
  roundtrip: {
    spec,
    makeAdapter: (provider, baseURL) => new MessengerAdapter({ provider, baseURL }),
    recipient: (user) => user,
  },
});
