// Telegram: outbound conformance against a local Bot API imitation, request details, and the inbound
// kit through the database's per-bot secret-token path (telegram_token / telegram_bot).
import { assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import type { StubMode } from "../conformance.ts";
import { conformanceSuite } from "../conformance.ts";
import { TelegramAdapter } from "../providers/telegram.ts";
import { inboundConformanceSuite, type InboundConnection, jsonString } from "./inbound_kit.ts";
import { imitationFixture, type ImitationSpec } from "./provider_imitation.ts";

const token = () => `${Math.floor(1e9 + Math.random() * 8e9)}:AA${crypto.randomUUID().replace(/-/g, "")}`;
const TOKEN = token();
const botError = (status: number, description: string, retry?: number) =>
  Response.json({
    ok: false,
    error_code: status,
    description,
    ...(retry ? { parameters: { retry_after: retry } } : {}),
  }, {
    status,
  });
const spec: ImitationSpec = {
  text: (b) => b.text,
  credential: (_req, url) => url.pathname.match(/^\/bot([^/]+)\//)?.[1] ?? null,
  respond: (mode: StubMode, n: number, b) => {
    switch (mode) {
      case "429":
        return botError(429, "Too Many Requests: retry after 3", 3);
      case "500":
        return botError(502, "Bad Gateway");
      case "window_closed":
      case "blocked":
        return botError(403, "Forbidden: bot was blocked by the user");
      case "bad_token":
        return botError(401, "Unauthorized");
      default:
        return Response.json({
          ok: true,
          result: { message_id: 100 + n, chat: { id: Number(b.chat_id) }, text: b.text },
        });
    }
  },
};
const fixture = () =>
  imitationFixture(spec, (baseURL) => new TelegramAdapter({ baseURL }), {
    credential: TOKEN,
    recipient: "9647501110006",
    accountId: "bot",
  });

conformanceSuite("telegram", fixture);

Deno.test("telegram: sendMessage as plain text (no parse_mode); the id is scoped to the chat", async () => {
  const fx = await fixture();
  try {
    const r = await fx.adapter.send(
      { text: "*not bold*", textSha256: "-", recipient: "42", accountId: "bot" },
      TOKEN,
      {
        timeoutMs: 5000,
      },
    );
    assertEquals(r, { kind: "sent", providerMessageId: "42:101" });
    const req = fx.imitation.received[0];
    assertEquals(req.url.pathname, `/bot${TOKEN}/sendMessage`);
    assertEquals(JSON.parse(new TextDecoder().decode(req.raw)), { chat_id: "42", text: "*not bold*" });
  } finally {
    await fx.close();
  }
});

Deno.test("telegram: a malformed token or chat id sends nothing; 429 waits as told", async () => {
  let called = 0;
  const adapter = new TelegramAdapter({
    fetchFn: () => {
      called++;
      return Promise.resolve(botError(429, "slow down", 7));
    },
  });
  const send = (cred: string, to: string) =>
    adapter.send({ text: "x", textSha256: "-", recipient: to, accountId: "b" }, cred, { timeoutMs: 1000 });
  assertEquals(await send("not-a-token", "42"), { kind: "permanent", code: "token_invalid" });
  assertEquals(await send(TOKEN, "../getUpdates?x="), { kind: "permanent", code: "invalid_recipient" });
  assertEquals(called, 0);
  assertEquals(await send(TOKEN, "42"), { kind: "retriable", code: "rate_limited", retryAfterMs: 7000 });
});

/** A stable positive message number for a test id (Telegram message ids are integers). */
const num = (id: string) => {
  let h = 7;
  for (const c of id) h = (h * 31 + c.charCodeAt(0)) % 1_000_000_007;
  return h + 1;
};
const body = (_c: InboundConnection, o: { text: string; id: string; user: string; escaped: boolean }) =>
  new TextEncoder().encode(
    `{"update_id":${num(o.id)},"message":{"message_id":${num(o.id)},"from":{"id":${o.user},"is_bot":false,` +
      `"first_name":"Customer"},"chat":{"id":${o.user},"type":"private"},"date":${
        Math.floor(Date.now() / 1000)
      },` +
      `"text":${jsonString(o.text, o.escaped)}}}`,
  );

const secretA = `tg-secret-${crypto.randomUUID()}`;
const secretB = `tg-secret-${crypto.randomUUID()}`;
inboundConformanceSuite("telegram", {
  scheme: "telegram_token",
  format: "telegram_bot",
  providerSecrets: {},
  makeAdapter: (provider) => new TelegramAdapter({ provider }),
  connections: [
    { accountId: `${Date.now()}1`, credential: token(), webhookSecret: secretA },
    { accountId: `${Date.now()}2`, credential: token(), webhookSecret: secretB },
  ],
  body,
  sign: (_raw, c, wrong) =>
    Promise.resolve({ "x-telegram-bot-api-secret-token": wrong ? `${c.webhookSecret}-x` : c.webhookSecret! }),
  messageId: (id, user) => `${user}:${num(id)}`,
  // Telegram's secret token authenticates the sender, not the body (see the migration's note).
  signsBody: false,
  roundtrip: {
    spec,
    makeAdapter: (provider, baseURL) => new TelegramAdapter({ provider, baseURL }),
    recipient: (user) => user,
  },
});

Deno.test("telegram: the token never appears in a send result or a stored code", async () => {
  const adapter = new TelegramAdapter({
    fetchFn: () => Promise.reject(new TypeError(`request to /bot${TOKEN}/x failed`)),
  });
  const r = await adapter.send({ text: "x", textSha256: "-", recipient: "42", accountId: "b" }, TOKEN, {
    timeoutMs: 1000,
  });
  assertFalse(JSON.stringify(r).includes(TOKEN));
});
