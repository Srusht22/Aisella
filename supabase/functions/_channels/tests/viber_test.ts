// Viber: outbound conformance against a local REST Bot API imitation, the request (sender name, auth
// header), exact 64-bit message tokens, and the inbound kit through the database's per-bot HMAC path.
import { assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import type { StubMode } from "../conformance.ts";
import { conformanceSuite } from "../conformance.ts";
import { mapViberStatus, ViberAdapter } from "../providers/viber.ts";
import { hmacSha256Hex } from "../text.ts";
import { inboundConformanceSuite, type InboundConnection, jsonString } from "./inbound_kit.ts";
import { imitationFixture, type ImitationSpec } from "./provider_imitation.ts";

const hex = (n: number) =>
  Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => b.toString(16).padStart(2, "0")).join("");
const token = () => `${hex(8)}-${hex(8)}-${hex(8)}`;
const TOKEN = token();
/** A token above 2^53: JSON.parse would round it. */
const bigToken = (n: number) => `49126618466552381${String(n).padStart(2, "0")}`;
const status = (code: number) =>
  new Response(`{"status":${code},"status_message":"detail","chat_hostname":"x"}`, { status: 200 });
const spec: ImitationSpec = {
  text: (b) => b.text,
  credential: (req) => req.headers.get("x-viber-auth-token"),
  respond: (mode: StubMode, n: number) => {
    switch (mode) {
      case "429":
        return status(12);
      case "500":
        return new Response("busy", { status: 503 });
      case "window_closed":
        return status(6);
      case "blocked":
        return status(5);
      case "bad_token":
        return status(2);
      default:
        // Written as raw text: the token must survive without JavaScript rounding.
        return new Response(
          `{"status":0,"status_message":"ok","message_token":${bigToken(n)},"chat_hostname":"x"}`,
          {
            status: 200,
            headers: { "content-type": "application/json" },
          },
        );
    }
  },
};
const fixture = async () => {
  const fx = await imitationFixture(spec, (baseURL) => new ViberAdapter({ baseURL }), {
    credential: TOKEN,
    recipient: "01234567890A=",
    accountId: "bot",
  });
  // The conformance kit sends without a sender name; the pipeline always passes the connection's.
  const send = fx.adapter.send.bind(fx.adapter);
  fx.adapter = {
    ...fx.adapter,
    send: (m, c, o) => send({ ...m, senderName: m.senderName ?? "Shop A" }, c, o),
  };
  return fx;
};

conformanceSuite("viber", fixture);

Deno.test("viber: the request names the store as sender; the token is a header; ids stay exact", async () => {
  const fx = await fixture();
  try {
    const r = await fx.adapter.send(
      { text: "سڵاو", textSha256: "-", recipient: "01234567890A=", accountId: "b", senderName: "Shop A" },
      TOKEN,
      {
        timeoutMs: 5000,
      },
    );
    assertEquals(r, { kind: "sent", providerMessageId: bigToken(1) });
    const req = fx.imitation.received[0];
    assertEquals(req.url.pathname, "/pa/send_message");
    assertEquals(req.headers.get("x-viber-auth-token"), TOKEN);
    assertFalse(req.url.href.includes(TOKEN));
    assertEquals(JSON.parse(new TextDecoder().decode(req.raw)), {
      receiver: "01234567890A=",
      min_api_version: 1,
      sender: { name: "Shop A" },
      type: "text",
      text: "سڵاو",
    });
  } finally {
    await fx.close();
  }
});

Deno.test("viber: no sender name or a malformed token sends nothing; status codes map safely", async () => {
  let called = 0;
  const adapter = new ViberAdapter({
    fetchFn: () => {
      called++;
      return Promise.resolve(status(0));
    },
  });
  const m = { text: "x", textSha256: "-", recipient: "u=", accountId: "b" };
  assertEquals(await adapter.send(m, TOKEN, { timeoutMs: 1000 }), {
    kind: "permanent",
    code: "sender_name_missing",
  });
  assertEquals(await adapter.send({ ...m, senderName: "S" }, "abc", { timeoutMs: 1000 }), {
    kind: "permanent",
    code: "token_invalid",
  });
  assertEquals(called, 0);
  assertEquals(await adapter.send({ ...m, senderName: "S" }, TOKEN, { timeoutMs: 1000 }), {
    kind: "unknown",
    code: "no_message_id",
  });
  assertEquals(mapViberStatus(24), { kind: "permanent", code: "payment_required" });
  assertEquals(mapViberStatus(9), { kind: "permanent", code: "account_restricted" });
  assertEquals(mapViberStatus(99), { kind: "permanent", code: "viber_status_99" });
});

const num = (id: string) => {
  let h = 7n;
  for (const c of id) h = (h * 31n + BigInt(c.charCodeAt(0))) % 9_000_000_000_000_000_000n;
  return (h + 1_000_000_000_000_000_000n).toString(); // 19 digits, above 2^53
};
const body = (_c: InboundConnection, o: { text: string; id: string; user: string; escaped: boolean }) =>
  new TextEncoder().encode(
    `{"event":"message","timestamp":${Date.now()},"chat_hostname":"SN-1","message_token":${num(o.id)},` +
      `"sender":{"id":"${o.user}=","name":"Customer","language":"ckb","country":"IQ","api_version":10},` +
      `"message":{"type":"text","text":${jsonString(o.text, o.escaped)}},"silent":false}`,
  );
const connA = { accountId: `viber-${Date.now()}-1`, credential: token() };
const connB = { accountId: `viber-${Date.now()}-2`, credential: token() };
inboundConformanceSuite("viber", {
  scheme: "viber_sha256",
  format: "viber_bot",
  providerSecrets: {},
  makeAdapter: (provider) => new ViberAdapter({ provider }),
  connections: [connA, connB],
  body,
  sign: async (raw, c, wrong) => ({
    "x-viber-content-signature": await hmacSha256Hex(wrong ? token() : c.credential!, raw),
  }),
  messageId: (id) => num(id),
  roundtrip: {
    spec,
    makeAdapter: (provider, baseURL) => new ViberAdapter({ provider, baseURL }),
    recipient: (user) => `${user}=`,
  },
});
