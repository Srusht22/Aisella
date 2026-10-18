// The conformance fixture for the stub provider (tests only).
import type { ConformanceFixture } from "../conformance.ts";
import { signStub, StubProvider } from "../stub_provider.ts";
import { startStubServer } from "./stub_server.ts";

const escapeNonAscii = (s: string) =>
  s.replace(/[\u0080-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);

export function randomSecret(): string {
  return `stub-secret-${crypto.randomUUID()}`;
}

export function stubFixture(
  provider = "stub",
): Promise<ConformanceFixture & { url: string; secret: string }> {
  const secret = randomSecret();
  const server = startStubServer();
  const adapter = new StubProvider({ provider, appSecret: secret, baseURL: server.url });
  const body = (text: string, id: string, escaped: boolean) => {
    const json =
      `{"event_id":"ev-${id}","entries":[{"type":"message","account":"acct-1","from":"cust-1","id":"${id}",` +
      `"at":"2026-10-18T10:00:00Z","text":${
        escaped ? `"${escapeNonAscii(text).replace(/\n/g, "\\n")}"` : JSON.stringify(text)
      }}]}`;
    return new TextEncoder().encode(json);
  };
  return Promise.resolve({
    adapter,
    url: server.url,
    secret,
    inboundBody: (t, id) => body(t, id, false),
    inboundBodyEscaped: (t, id) => body(t, id, true),
    sign: (raw) => signStub(secret, raw),
    signWithWrongSecret: (raw) => signStub(randomSecret(), raw),
    setMode: server.setMode,
    receivedTextBytes: server.textBytes,
    receivedCount: () => server.received.length,
    secrets: [secret],
    close: () => server.close(),
  });
}
