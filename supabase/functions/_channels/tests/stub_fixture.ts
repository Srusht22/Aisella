// The outbound conformance fixture for the stub provider (tests only).
import type { ConformanceFixture } from "../conformance.ts";
import { StubProvider } from "../stub_provider.ts";
import { startStubServer } from "./stub_server.ts";

export function randomSecret(): string {
  return `stub-secret-${crypto.randomUUID()}`;
}

export function stubFixture(provider = "stub"): Promise<ConformanceFixture> {
  const server = startStubServer();
  return Promise.resolve({
    adapter: new StubProvider({ provider, baseURL: server.url }),
    credential: `stub-cred-${crypto.randomUUID()}`,
    recipient: "u-1",
    accountId: "acct",
    setMode: server.setMode,
    receivedTextBytes: server.textBytes,
    receivedCount: () => server.received.length,
    receivedCredential: (i) => server.received[i]?.auth?.replace(/^Bearer /, "") ?? null,
    close: () => server.close(),
  });
}
