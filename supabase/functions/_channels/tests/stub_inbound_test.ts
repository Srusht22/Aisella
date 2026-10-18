// The inbound kit against the fixture-only stub provider's webhook format (aisellia_stub).
import { StubProvider } from "../stub_provider.ts";
import { hmacSha256Hex } from "../text.ts";
import { inboundConformanceSuite, type InboundConnection, jsonString } from "./inbound_kit.ts";
import { randomSecret } from "./stub_fixture.ts";

const secret = randomSecret();

inboundConformanceSuite("stub", {
  scheme: "stub_sha256",
  format: "aisellia_stub",
  providerSecrets: { app_secret: secret },
  makeAdapter: (provider) => new StubProvider({ provider, baseURL: "http://127.0.0.1:9" }),
  connections: [{ accountId: `acct-${crypto.randomUUID()}` }, { accountId: `acct-${crypto.randomUUID()}` }],
  body: (c: InboundConnection, o) =>
    new TextEncoder().encode(
      `{"event_id":"ev-${o.id}","entries":[{"type":"message","account":"${c.accountId}","from":"${o.user}",` +
        `"id":"${o.id}","at":"${new Date().toISOString()}","text":${jsonString(o.text, o.escaped)}}]}`,
    ),
  sign: async (raw, _c, wrong) => ({
    "x-stub-signature": `sha256=${await hmacSha256Hex(wrong ? randomSecret() : secret, raw)}`,
  }),
  messageId: (id) => id,
});
