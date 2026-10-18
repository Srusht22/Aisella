// The shared OUTBOUND conformance kit (Phase 9 L §3): every adapter must pass it before release.
// A provider supplies its adapter wired to a LOCAL imitation of its API and control over the
// imitation's responses. No network beyond loopback. Inbound conformance (signature, raw bytes,
// normalisation, deduplication) runs against the database, which owns verification since the
// security review: tests/inbound_kit.ts.
import type { ProviderAdapter } from "./adapter.ts";

export type StubMode = "ok" | "429" | "500" | "timeout" | "window_closed" | "blocked" | "bad_token";

export interface ConformanceFixture {
  adapter: ProviderAdapter;
  /** A credential of the right shape for this provider (never real). */
  credential: string;
  recipient: string;
  accountId: string;
  setMode(mode: StubMode): void;
  /** Bytes of the text the imitation received in its i-th send request. */
  receivedTextBytes(i: number): Uint8Array;
  receivedCount(): number;
  /** How the credential reached the imitation in the i-th request (header or URL), for checking. */
  receivedCredential(i: number): string | null;
  close(): Promise<void>;
}

export const SAMPLE_TEXTS = {
  en: "Hello! Size M is 35,000 IQD.",
  // Sorani with a zero-width non-joiner and Arabic-Indic digits.
  ckb: "سڵاو! قەبارەی M بە ٣٥٠٠٠ دینارە‌. سوپاس",
  // Arabic with diacritics, trailing spaces and a newline.
  ar: "مرحبًا! المقاس M بسعر ٣٥ ألف دينار  \n",
};

/** Registers the kit as Deno tests for one provider. */
export function conformanceSuite(name: string, make: () => Promise<ConformanceFixture>) {
  Deno.test(`[${name}] outbound conformance: exact bytes, safe outcome mapping, credential use`, async (t) => {
    const fx = await make();
    const send = (text: string, timeoutMs = 5000) =>
      fx.adapter.send(
        { text, textSha256: "-", recipient: fx.recipient, accountId: fx.accountId },
        fx.credential,
        {
          timeoutMs,
        },
      );
    try {
      await t.step("en / ckb / ar text reaches the provider byte-identical", async () => {
        fx.setMode("ok");
        const before = fx.receivedCount();
        const texts = [SAMPLE_TEXTS.en, SAMPLE_TEXTS.ckb, SAMPLE_TEXTS.ar];
        for (const text of texts) {
          const r = await send(text);
          if (r.kind !== "sent" || !r.providerMessageId) {
            throw new Error(`expected sent with an id, got ${r.kind}`);
          }
        }
        texts.forEach((text, i) => {
          if (fx.receivedTextBytes(before + i).join() !== new TextEncoder().encode(text).join()) {
            throw new Error(`text ${i} was altered on the way to the provider`);
          }
        });
      });
      await t.step("the stored credential is what authenticates the request", () => {
        const got = fx.receivedCredential(fx.receivedCount() - 1);
        if (got !== fx.credential) throw new Error("the credential did not reach the provider as configured");
      });
      await t.step(
        "outcomes map safely: 429 / 5xx retriable; window, block, token permanent; timeout unknown",
        async () => {
          const kinds: string[] = [];
          for (const mode of ["429", "500", "window_closed", "blocked", "bad_token"] as const) {
            fx.setMode(mode);
            kinds.push((await send("x")).kind);
          }
          fx.setMode("timeout");
          kinds.push((await send("x", 300)).kind);
          fx.setMode("ok");
          const got = kinds.join(",");
          if (got !== "retriable,retriable,permanent,permanent,permanent,unknown") {
            throw new Error(`unexpected outcome mapping: ${got}`);
          }
        },
      );
      await t.step("an error code is a short code, never provider prose or the credential", async () => {
        fx.setMode("window_closed");
        const r = await send("x");
        fx.setMode("ok");
        const code = "code" in r ? r.code : "";
        if (!/^[a-z0-9_]{1,64}$/.test(code) || code.includes(fx.credential)) {
          throw new Error(`unsafe error code: ${code}`);
        }
      });
    } finally {
      await fx.close();
    }
  });
}
