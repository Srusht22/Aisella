// A local HTTP server playing the stub provider's send API. It records the raw request bytes so
// tests can prove the text arrived byte for byte. Loopback only.
import type { StubMode as Mode } from "../conformance.ts";

export function startStubServer() {
  const received: { raw: Uint8Array; auth: string | null }[] = [];
  let mode: Mode = "ok";
  let n = 0;
  const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen: () => {} }, async (req) => {
    const raw = new Uint8Array(await req.arrayBuffer());
    received.push({ raw, auth: req.headers.get("authorization") });
    switch (mode) {
      case "429":
        return Response.json({ error: "rate_limited" }, { status: 429, headers: { "retry-after": "2" } });
      case "500":
        return Response.json({ error: "server" }, { status: 500 });
      case "window_closed":
        return Response.json({ error: "window_closed" }, { status: 400 });
      case "blocked":
        return Response.json({ error: "blocked" }, { status: 403 });
      case "bad_token":
        return Response.json({ error: "bad_token" }, { status: 401 });
      case "timeout":
        await new Promise((r) => setTimeout(r, 1500));
        return Response.json({ id: `late-${++n}` });
      default:
        return Response.json({ id: `stub-msg-${++n}-${crypto.randomUUID().slice(0, 8)}` });
    }
  });
  return {
    url: `http://127.0.0.1:${server.addr.port}`,
    received,
    setMode: (m: Mode) => (mode = m),
    /** The `text` field of the n-th request, as bytes. */
    textBytes: (i: number) =>
      new TextEncoder().encode(
        (JSON.parse(new TextDecoder().decode(received[i].raw)) as { text: string }).text,
      ),
    close: () => server.shutdown(),
  };
}
