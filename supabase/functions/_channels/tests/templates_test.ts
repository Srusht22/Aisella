// WhatsApp templates (outside the 24-hour window): rendering identical to the database, the request
// the adapter submits, the exact-text check before submission, refusal by providers without
// templates, the template list read from Meta, and the worker's sync cycle.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1.0.13";
import type { OutboundText, ProviderAdapter, SendResult } from "../adapter.ts";
import type { ApiResult, ClaimedSend, TemplateSync, WorkerDb } from "../db.ts";
import { fetchTemplates, WhatsAppAdapter } from "../providers/whatsapp.ts";
import { runSend } from "../send.ts";
import { renderTemplate, sha256Hex } from "../text.ts";
import { runTemplateSyncCycle } from "../worker.ts";

const BODY = "سڵاو {{1}}، داواکارییەکەت {{2}} ئامادەیە. Order {{2}} is ready.";

Deno.test("templates render exactly like app.render_template (same cases as pgTAP suite 24)", () => {
  assertEquals(
    renderTemplate(BODY, ["ئارام", "A-17"]),
    "سڵاو ئارام، داواکارییەکەت A-17 ئامادەیە. Order A-17 is ready.",
  );
  assertEquals(renderTemplate("No parameters.", []), "No parameters.");
  assertEquals(
    renderTemplate("{{1}}{{1}} {{2}}", ["$&", "{1}"]),
    "$&$& {1}",
    "no regex replacement semantics",
  );
});

function capture(): { fetchFn: typeof fetch; bodies: Record<string, unknown>[]; urls: string[] } {
  const bodies: Record<string, unknown>[] = [];
  const urls: string[] = [];
  const fetchFn: typeof fetch = (input, init) => {
    urls.push(String(input));
    bodies.push(JSON.parse(String(init?.body)));
    return Promise.resolve(Response.json({ messages: [{ id: "wamid.T1" }] }));
  };
  return { fetchFn, bodies, urls };
}

const MSG: OutboundText = {
  text: renderTemplate(BODY, ["ئارام", "A-17"]),
  textSha256: "",
  recipient: "9647501112233",
  accountId: "106540352242922",
  template: { name: "order_ready", language: "ckb", params: ["ئارام", "A-17"] },
};

Deno.test("whatsapp: a template is submitted as type template with its body parameters, in order", async () => {
  const c = capture();
  const out = await new WhatsAppAdapter({ baseURL: "http://imitation.invalid", fetchFn: c.fetchFn })
    .send(MSG, "token", { timeoutMs: 1000 });
  assertEquals(out, { kind: "sent", providerMessageId: "wamid.T1" });
  assertEquals(c.bodies[0], {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: "9647501112233",
    type: "template",
    template: {
      name: "order_ready",
      language: { code: "ckb" },
      components: [{
        type: "body",
        parameters: [{ type: "text", text: "ئارام" }, { type: "text", text: "A-17" }],
      }],
    },
  });
  assert(!("text" in c.bodies[0]), "no free-form text alongside the template");
  const plain = capture();
  await new WhatsAppAdapter({ baseURL: "http://imitation.invalid", fetchFn: plain.fetchFn })
    .send({ ...MSG, template: null, text: "hi" }, "token", { timeoutMs: 1000 });
  assertEquals(plain.bodies[0].type, "text", "without a template it stays a text message");
});

class OneClaimDb {
  calls: { fn: string; args: unknown[] }[] = [];
  constructor(private claimed: ClaimedSend) {}
  claim(): Promise<ApiResult<ClaimedSend>> {
    return Promise.resolve({ ok: true, data: this.claimed });
  }
  complete(...args: unknown[]): Promise<ApiResult> {
    this.calls.push({ fn: "complete", args });
    return Promise.resolve({ ok: true, data: { state: "sent" } });
  }
  fail(...args: unknown[]): Promise<ApiResult> {
    this.calls.push({ fn: "fail", args });
    return Promise.resolve({ ok: true, data: { state: "failed" } });
  }
  state(): Promise<ApiResult> {
    return Promise.resolve({ ok: true, data: { state: "sending" } });
  }
}

class Recorder implements ProviderAdapter {
  readonly webhookHeaders = [] as const;
  readonly perConnectionWebhook = false;
  sent: OutboundText[] = [];
  constructor(readonly provider: string, readonly supportsTemplates: boolean) {}
  send(msg: OutboundText): Promise<SendResult> {
    this.sent.push(msg);
    return Promise.resolve({ kind: "sent", providerMessageId: "p1" });
  }
}

async function claimed(provider: string, params: string[], authorizedText: string): Promise<ClaimedSend> {
  return {
    send_request_id: "s1",
    provider,
    account_id: "106540352242922",
    recipient: "9647501112233",
    text: authorizedText,
    text_sha256: await sha256Hex(authorizedText),
    credential: "token",
    attempt: 1,
    template: { name: "order_ready", language: "ckb", body_text: BODY, params },
  };
}

Deno.test("send: a template goes out only if its rendering is the exact authorized text", async () => {
  const text = renderTemplate(BODY, ["ئارام", "A-17"]);
  const ok = new Recorder("whatsapp", true);
  const db = new OneClaimDb(await claimed("whatsapp", ["ئارام", "A-17"], text));
  const out = await runSend("s1", { db, adapters: { whatsapp: ok }, log: () => {} });
  assertEquals(out.state, "sent");
  assertEquals(ok.sent[0].template, { name: "order_ready", language: "ckb", params: ["ئارام", "A-17"] });
  assertEquals(ok.sent[0].text, text);

  // Parameters changed after authorization (the rendering no longer matches): nothing is submitted.
  const tampered = new Recorder("whatsapp", true);
  const db2 = new OneClaimDb(await claimed("whatsapp", ["ئارام", "B-99"], text));
  const out2 = await runSend("s1", { db: db2, adapters: { whatsapp: tampered }, log: () => {} });
  assertEquals([out2.state, out2.code], ["failed", "text_integrity"]);
  assertEquals(tampered.sent.length, 0);
  assertEquals(db2.calls[0].args.slice(1, 3), ["integrity", "text_integrity"]);
});

Deno.test("send: a provider without templates refuses a template send (permanent, nothing submitted)", async () => {
  const text = renderTemplate(BODY, ["ئارام", "A-17"]);
  const telegram = new Recorder("telegram", false);
  const db = new OneClaimDb(await claimed("telegram", ["ئارام", "A-17"], text));
  const out = await runSend("s1", { db, adapters: { telegram }, log: () => {} });
  assertEquals([out.state, out.code], ["failed", "templates_unsupported"]);
  assertEquals(telegram.sent.length, 0);
});

Deno.test("fetchTemplates follows Meta's cursor on the same host only, token as Bearer", async () => {
  const seen: { url: string; auth: string | null }[] = [];
  const fetchFn: typeof fetch = (input, init) => {
    const url = String(input);
    seen.push({ url, auth: new Headers(init?.headers).get("authorization") });
    if (url.includes("after=p2")) {
      return Promise.resolve(
        Response.json({ data: [{ name: "b" }], paging: { next: "https://evil.invalid/steal" } }),
      );
    }
    return Promise.resolve(Response.json({
      data: [{ name: "a" }],
      paging: { next: "https://graph.facebook.com/v26.0/123456/message_templates?after=p2" },
    }));
  };
  const out = await fetchTemplates({ fetchFn }, "123456", "tok");
  assertEquals(out, [{ name: "a" }, { name: "b" }]);
  assertEquals(seen.length, 2, "the foreign-host cursor is not followed");
  assert(seen[0].url.startsWith("https://graph.facebook.com/v26.0/123456/message_templates?fields="));
  assert(!seen.some((s) => s.url.includes("tok")), "the token never goes in the URL");
  assertEquals(seen[0].auth, "Bearer tok");
  await assertRejects(() => fetchTemplates({ fetchFn }, "12/../me", "tok"));
  const failing: typeof fetch = () => Promise.resolve(new Response("no", { status: 403 }));
  await assertRejects(() => fetchTemplates({ fetchFn: failing }, "123456", "tok"));
});

Deno.test("the worker's template sync stores what Meta returned and survives a failing account", async () => {
  const stored: { id: string; templates: unknown[] }[] = [];
  const items: TemplateSync[] = [
    { connection_id: "c1", provider: "whatsapp", waba_id: "111111", credential: "t1" },
    { connection_id: "c2", provider: "whatsapp", waba_id: "222222", credential: "t2" },
    { connection_id: "c3", provider: "whatsapp", waba_id: "333333", credential: null },
  ];
  const db = {
    dueTemplateSyncs: () => Promise.resolve({ ok: true, data: { items } }),
    storeTemplates: (id: string, templates: unknown[]) => {
      stored.push({ id, templates });
      return Promise.resolve({ ok: true });
    },
  } as unknown as WorkerDb;
  const out = await runTemplateSyncCycle({
    db,
    fetchers: {
      whatsapp: (waba) =>
        waba === "222222" ? Promise.reject(new Error("http_500")) : Promise.resolve([{ name: "x" }]),
    },
    log: () => {},
  });
  assertEquals(out, { synced: 1, failed: 1 });
  assertEquals(
    stored,
    [{ id: "c1", templates: [{ name: "x" }] }],
    "a failure leaves the stored list untouched",
  );
});
