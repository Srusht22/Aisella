// The shared conformance kit (Phase 9 L §3): every adapter must pass it before release.
// A provider supplies a fixture: its adapter wired to a LOCAL imitation of its API, a way to sign
// raw bodies, and control over the imitation's responses. No network beyond loopback.
import type { ProviderAdapter } from "./adapter.ts";
import { handleWebhook } from "./ingest.ts";
import type { ApiResult, IngestDb } from "./db.ts";

export interface ConformanceFixture {
  adapter: ProviderAdapter;
  /** A raw webhook body (bytes as the provider would send them) with one inbound text message. */
  inboundBody(text: string, messageId: string): Uint8Array;
  /** Same body, but with non-ASCII characters escaped the way some providers do (\uXXXX). */
  inboundBodyEscaped(text: string, messageId: string): Uint8Array;
  sign(raw: Uint8Array): Promise<Headers>;
  signWithWrongSecret(raw: Uint8Array): Promise<Headers>;
  setMode(mode: "ok" | "429" | "500" | "timeout" | "window_closed"): void;
  /** Bytes of the text the imitation received in its i-th send request. */
  receivedTextBytes(i: number): Uint8Array;
  receivedCount(): number;
  /** Values that must never appear in logs (app secret, credentials). */
  secrets: string[];
  close(): Promise<void>;
}

export const SAMPLE_TEXTS = {
  en: "Hello! Size M is 35,000 IQD.",
  // Sorani with a zero-width non-joiner and Arabic-Indic digits.
  ckb: "سڵاو! قەبارەی M بە ٣٥٠٠٠ دینارە‌. سوپاس",
  // Arabic with diacritics, trailing spaces and a newline.
  ar: "مرحبًا! المقاس M بسعر ٣٥ ألف دينار  \n",
};

class CaptureDb implements IngestDb {
  stored: { id: string; events: unknown[] }[] = [];
  ingest(_p: string, id: string, _h: string | null, events: unknown[]): Promise<ApiResult> {
    const dup = this.stored.some((s) => s.id === id);
    if (!dup) this.stored.push({ id, events });
    return Promise.resolve({ ok: true, data: { stored: !dup, duplicate: dup } });
  }
}

/** Registers the kit as Deno tests for one provider. */
export function conformanceSuite(name: string, make: () => Promise<ConformanceFixture>) {
  const enc = (s: Uint8Array) => s;
  const req = (raw: Uint8Array, headers: Headers) =>
    new Request("http://local/webhook", { method: "POST", headers, body: enc(raw).slice() });

  Deno.test(`[${name}] conformance: authenticity, raw bytes, deduplication, outcomes, exact text, no secrets`, async (t) => {
    const fx = await make();
    const logs: Record<string, unknown>[] = [];
    const log = (e: Record<string, unknown>) => logs.push(e);
    try {
      await t.step("a correctly signed webhook is accepted and stored", async () => {
        const db = new CaptureDb();
        const raw = fx.inboundBody(SAMPLE_TEXTS.ckb, "m-1");
        const res = await handleWebhook(req(raw, await fx.sign(raw)), { adapter: fx.adapter, db, log });
        if (res.status !== 200 || db.stored.length !== 1) {
          throw new Error(`expected 200 and one stored event, got ${res.status}`);
        }
      });
      await t.step(
        "a wrong secret, a missing signature and a tampered byte are rejected (401), nothing stored",
        async () => {
          const db = new CaptureDb();
          const raw = fx.inboundBody(SAMPLE_TEXTS.en, "m-2");
          const tampered = raw.slice();
          tampered[tampered.length - 3] ^= 1;
          const cases: [Uint8Array, Headers][] = [
            [raw, await fx.signWithWrongSecret(raw)],
            [raw, new Headers({ "content-type": "application/json" })],
            [tampered, await fx.sign(raw)],
          ];
          for (const [body, headers] of cases) {
            const res = await handleWebhook(req(body, headers), { adapter: fx.adapter, db, log });
            if (res.status !== 401) throw new Error(`expected 401, got ${res.status}`);
          }
          if (db.stored.length !== 0) throw new Error("a rejected webhook was stored");
        },
      );
      await t.step("verification uses the raw bytes: a re-serialized body no longer verifies", async () => {
        const raw = fx.inboundBodyEscaped(SAMPLE_TEXTS.ar, "m-3");
        const headers = await fx.sign(raw);
        if (!(await fx.adapter.verify(raw, headers)).ok) {
          throw new Error("the original escaped body must verify");
        }
        const reserialized = new TextEncoder().encode(
          JSON.stringify(JSON.parse(new TextDecoder().decode(raw))),
        );
        if ((await fx.adapter.verify(reserialized, headers)).ok) {
          throw new Error("a re-serialized body must not verify");
        }
      });
      await t.step(
        "parsing is deterministic: the same body yields the same event and message ids",
        async () => {
          const raw = fx.inboundBody(SAMPLE_TEXTS.en, "m-4");
          const a = await fx.adapter.parse(raw);
          const b = await fx.adapter.parse(raw);
          if (
            a.externalEventId !== b.externalEventId || JSON.stringify(a.events) !== JSON.stringify(b.events)
          ) {
            throw new Error("parse is not deterministic");
          }
          const db = new CaptureDb();
          for (let i = 0; i < 2; i++) {
            await handleWebhook(req(raw, await fx.sign(raw)), { adapter: fx.adapter, db, log });
          }
          if (db.stored.length !== 1) {
            throw new Error("a redelivered webhook was stored twice");
          }
        },
      );
      await t.step("inbound Sorani and Arabic text is parsed byte for byte", async () => {
        for (const text of [SAMPLE_TEXTS.ckb, SAMPLE_TEXTS.ar]) {
          const parsed = await fx.adapter.parse(fx.inboundBodyEscaped(text, `m-${text.length}`));
          const got = (parsed.events[0] as { text?: string }).text ?? "";
          if (new TextEncoder().encode(got).join() !== new TextEncoder().encode(text).join()) {
            throw new Error("inbound text changed in parsing");
          }
        }
      });
      await t.step("outbound en / ckb / ar text reaches the provider byte-identical", async () => {
        fx.setMode("ok");
        const before = fx.receivedCount();
        const texts = [SAMPLE_TEXTS.en, SAMPLE_TEXTS.ckb, SAMPLE_TEXTS.ar];
        for (const text of texts) {
          const r = await fx.adapter.send(
            { text, textSha256: "-", recipient: "u-1", accountId: "acct" },
            "cred-x",
            { timeoutMs: 5000 },
          );
          if (r.kind !== "sent") throw new Error(`expected sent, got ${r.kind}`);
        }
        texts.forEach((text, i) => {
          if (fx.receivedTextBytes(before + i).join() !== new TextEncoder().encode(text).join()) {
            throw new Error(`text ${i} was altered on the way to the provider`);
          }
        });
      });
      await t.step(
        "outcomes map safely: 429 / 5xx retriable, rejection permanent, timeout unknown",
        async () => {
          const send = () =>
            fx.adapter.send({ text: "x", textSha256: "-", recipient: "u", accountId: "a" }, null, {
              timeoutMs: 300,
            });
          fx.setMode("429");
          const r429 = await send();
          fx.setMode("500");
          const r500 = await send();
          fx.setMode("window_closed");
          const rClosed = await send();
          fx.setMode("timeout");
          const rTimeout = await send();
          fx.setMode("ok");
          const kinds = [r429.kind, r500.kind, rClosed.kind, rTimeout.kind].join(",");
          if (kinds !== "retriable,retriable,permanent,unknown") {
            throw new Error(`unexpected outcome mapping: ${kinds}`);
          }
        },
      );
      await t.step("no secret or credential appears in any log line", () => {
        const text = JSON.stringify(logs);
        for (const s of [...fx.secrets, "cred-x"]) {
          if (text.includes(s)) throw new Error("a secret reached the logs");
        }
        for (const s of Object.values(SAMPLE_TEXTS)) {
          if (text.includes(s.trim())) throw new Error("message text reached the logs");
        }
      });
    } finally {
      await fx.close();
    }
  });
}
