// Meta webhook bodies and signatures shared by the Instagram, Messenger and WhatsApp tests.
import { hmacSha256Hex } from "../text.ts";
import { type InboundConnection, jsonString } from "./inbound_kit.ts";

export const metaBody =
  (object: string) =>
  (c: InboundConnection, o: { text: string; id: string; user: string; escaped: boolean }) =>
    new TextEncoder().encode(
      `{"object":"${object}","entry":[{"id":"${c.accountId}","time":${Date.now()},"messaging":[{"sender":{"id":"${o.user}"},` +
        `"recipient":{"id":"${c.accountId}"},"timestamp":${Date.now()},"message":{"mid":"${o.id}","text":${
          jsonString(o.text, o.escaped)
        }}}]}]}`,
    );
export const metaSign =
  (secret: string) => async (raw: Uint8Array, _c: InboundConnection, wrong?: boolean) => ({
    "x-hub-signature-256": `sha256=${await hmacSha256Hex(wrong ? `${secret}-wrong` : secret, raw)}`,
  });
