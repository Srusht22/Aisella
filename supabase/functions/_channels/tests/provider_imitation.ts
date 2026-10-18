// A local HTTP imitation of a provider's send API, for the outbound conformance kit (loopback only).
// It records each request's raw bytes, URL and headers so tests can prove what reached the provider.
// deno-lint-ignore-file no-explicit-any -- request bodies of several providers' APIs
import type { ConformanceFixture, StubMode } from "../conformance.ts";
import type { ProviderAdapter } from "../adapter.ts";

export interface ImitationSpec {
  /** The text the provider would deliver, read from the parsed request body. */
  text(body: any): string;
  /** How the credential arrived (Bearer header, auth header, URL path…). */
  credential(req: Request, url: URL): string | null;
  /** The provider's answer for `mode` (the n-th request). */
  respond(mode: StubMode, n: number, body: any): Response;
}

export interface Received {
  raw: Uint8Array;
  url: URL;
  headers: Headers;
  credential: string | null;
}

export function startImitation(spec: ImitationSpec) {
  const received: Received[] = [];
  let mode: StubMode = "ok";
  const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen: () => {} }, async (req) => {
    const raw = new Uint8Array(await req.arrayBuffer());
    const url = new URL(req.url);
    received.push({ raw, url, headers: req.headers, credential: spec.credential(req, url) });
    if (mode === "timeout") await new Promise((r) => setTimeout(r, 1500));
    let body: any = {};
    try {
      body = JSON.parse(new TextDecoder().decode(raw));
    } catch {
      body = {};
    }
    return spec.respond(mode === "timeout" ? "ok" : mode, received.length, body);
  });
  return {
    url: `http://127.0.0.1:${server.addr.port}`,
    received,
    setMode: (m: StubMode) => (mode = m),
    textBytes: (i: number) =>
      new TextEncoder().encode(spec.text(JSON.parse(new TextDecoder().decode(received[i].raw)))),
    close: () => server.shutdown(),
  };
}

/** A ConformanceFixture from an imitation and an adapter factory pointed at it. */
export function imitationFixture(
  spec: ImitationSpec,
  make: (baseURL: string) => ProviderAdapter,
  o: { credential: string; recipient: string; accountId: string },
): Promise<ConformanceFixture & { imitation: ReturnType<typeof startImitation> }> {
  const imitation = startImitation(spec);
  return Promise.resolve({
    imitation,
    adapter: make(imitation.url),
    ...o,
    setMode: imitation.setMode,
    receivedTextBytes: imitation.textBytes,
    receivedCount: () => imitation.received.length,
    receivedCredential: (i) => imitation.received[i]?.credential ?? null,
    close: imitation.close,
  });
}

/** Meta Graph API answers (Instagram, Messenger; WhatsApp overrides the success body). */
export const graphResponses =
  (ok: (n: number) => Record<string, unknown>) => (mode: StubMode, n: number): Response => {
    const error = (status: number, code: number, sub?: number) =>
      Response.json({
        error: {
          message: "secret detail",
          type: "OAuthException",
          code,
          error_subcode: sub,
          fbtrace_id: "x",
        },
      }, {
        status,
      });
    switch (mode) {
      case "429":
        return error(400, 613);
      case "500":
        return error(500, 2);
      case "window_closed":
        return error(400, 10, 2018278);
      case "blocked":
        return error(400, 551, 1545041);
      case "bad_token":
        return error(401, 190);
      default:
        return Response.json(ok(n));
    }
  };

export const bearer = (req: Request) => req.headers.get("authorization")?.replace(/^Bearer /, "") ?? null;
