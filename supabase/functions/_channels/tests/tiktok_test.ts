// TikTok (BLOCKED for real use): the adapter refuses to send until an endpoint is configured; with a
// configured path it passes the outbound kit against a local imitation of the ASSUMED API; and the
// inbound kit runs through the database's timestamped-signature path with the ASSUMED body.
import { assertEquals } from "jsr:@std/assert@1.0.13";
import type { StubMode } from "../conformance.ts";
import { conformanceSuite } from "../conformance.ts";
import { TikTokAdapter } from "../providers/tiktok.ts";
import { hmacSha256Hex } from "../text.ts";
import { inboundConformanceSuite, type InboundConnection, jsonString } from "./inbound_kit.ts";
import { bearer, imitationFixture, type ImitationSpec } from "./provider_imitation.ts";

const TOKEN = `act.${crypto.randomUUID().replace(/-/g, "")}`;
const PATH = "/open_api/v1.3/business/message/send/";
const spec: ImitationSpec = {
  text: (b) => b.message?.text,
  credential: bearer,
  respond: (mode: StubMode, n: number) => {
    switch (mode) {
      case "429":
        return Response.json({ code: 40100, message: "too many" }, { status: 429 });
      case "500":
        return Response.json({ code: 50000 }, { status: 500 });
      case "window_closed":
        return Response.json({ code: 40010, message: "window" }, { status: 400 });
      case "blocked":
        return Response.json({ code: 40300, message: "blocked" }, { status: 403 });
      case "bad_token":
        return Response.json({ code: 40105, message: "token" }, { status: 401 });
      default:
        return Response.json({ code: 0, message: "OK", data: { message_id: `tt-msg-${n}` } });
    }
  },
};
const fixture = () =>
  imitationFixture(spec, (baseURL) => new TikTokAdapter({ baseURL, sendPath: PATH }), {
    credential: TOKEN,
    recipient: "open-id-1",
    accountId: "client-key-1",
  });

conformanceSuite("tiktok (configured endpoint, assumed API)", fixture);

Deno.test("tiktok: without a configured endpoint nothing is ever sent", async () => {
  let called = false;
  const fetchFn = () => {
    called = true;
    return Promise.resolve(Response.json({ code: 0, data: { message_id: "x" } }));
  };
  for (const sendPath of [undefined, null, "", "https://evil.example/x", "/a/../b"]) {
    const r = await new TikTokAdapter({ sendPath, fetchFn }).send(
      { text: "x", textSha256: "-", recipient: "o", accountId: "c" },
      TOKEN,
      { timeoutMs: 1000 },
    );
    assertEquals(r, { kind: "permanent", code: "provider_unresolved" });
  }
  assertEquals(called, false);
});

const secret = `tt-client-secret-${crypto.randomUUID()}`;
const body = (c: InboundConnection, o: { text: string; id: string; user: string; escaped: boolean }) => {
  const content = `{"conversation_id":"conv-${o.user}","message_id":"${o.id}","text":${
    jsonString(o.text, o.escaped)
  }}`;
  return new TextEncoder().encode(
    // A space after the first colon, as many senders write: re-serialising then changes the bytes.
    `{"client_key": "${c.accountId}","event":"direct_message.receive","create_time":${
      Math.floor(Date.now() / 1000)
    },` +
      `"user_openid":"${o.user}","content":${JSON.stringify(content)}}`,
  );
};
const sign = async (raw: Uint8Array, _c: InboundConnection, wrong?: boolean) => {
  const t = Math.floor(Date.now() / 1000);
  const signed = new Uint8Array([...new TextEncoder().encode(`${t}.`), ...raw]);
  return { "tiktok-signature": `t=${t},s=${await hmacSha256Hex(wrong ? `${secret}-x` : secret, signed)}` };
};

inboundConformanceSuite("tiktok", {
  scheme: "tiktok_sha256",
  format: "tiktok_bm",
  providerSecrets: { client_secret: secret },
  makeAdapter: (provider) => new TikTokAdapter({ provider }),
  connections: [{ accountId: `ck-${Date.now()}-1`, credential: TOKEN }, {
    accountId: `ck-${Date.now()}-2`,
    credential: TOKEN,
  }],
  body,
  sign,
  messageId: (id) => id,
  roundtrip: {
    spec,
    makeAdapter: (provider, baseURL) => new TikTokAdapter({ provider, baseURL, sendPath: PATH }),
    recipient: (user) => user,
  },
});
