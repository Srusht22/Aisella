// The real provider adapters, built from server-side configuration. The fixture-only stub is never
// part of it. Each provider still sends only once its registry row allows it (status and VERIFIED
// capabilities in app.providers / app.provider_capabilities).
import type { ProviderAdapter } from "../adapter.ts";
import { DEFAULT_GRAPH_VERSION } from "./meta_graph.ts";
import { InstagramAdapter } from "./instagram.ts";
import { MessengerAdapter } from "./messenger.ts";
import { TelegramAdapter } from "./telegram.ts";
import { ViberAdapter } from "./viber.ts";
import { WhatsAppAdapter } from "./whatsapp.ts";

export function realAdapters(env: (k: string) => string | undefined): Record<string, ProviderAdapter> {
  const graph = { version: env("META_GRAPH_VERSION")?.trim() || DEFAULT_GRAPH_VERSION };
  const list: ProviderAdapter[] = [
    new InstagramAdapter(graph),
    new MessengerAdapter(graph),
    new WhatsAppAdapter(graph),
    new TelegramAdapter(),
    new ViberAdapter(),
  ];
  return Object.fromEntries(list.map((a) => [a.provider, a]));
}
