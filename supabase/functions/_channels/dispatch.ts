// The send endpoint (Edge Function channel-send): a signed-in member of the store asks to submit a
// send they (or a colleague) already authorized with api.send_message. Ownership is checked with the
// caller's own JWT (api.check_send_dispatch); the submission itself runs with the sender role.
import type { ProviderAdapter } from "./adapter.ts";
import type { SenderDb } from "./db.ts";
import type { Logger } from "./ingest.ts";
import { runSend } from "./send.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export type OwnerCheck = (authorization: string, sendRequestId: string) => Promise<boolean>;

/** api.check_send_dispatch through PostgREST, as the caller (never the service role). */
export function postgrestOwnerCheck(
  supabaseUrl: string,
  anonKey: string,
  fetchFn: typeof fetch = fetch,
): OwnerCheck {
  return async (authorization, id) => {
    const res = await fetchFn(`${supabaseUrl.replace(/\/+$/, "")}/rest/v1/rpc/check_send_dispatch`, {
      method: "POST",
      headers: {
        apikey: anonKey,
        Authorization: authorization,
        "Content-Type": "application/json",
        "Content-Profile": "api",
      },
      body: JSON.stringify({ p_send_request_id: id }),
    });
    const body = await res.json().catch(() => null) as { ok?: boolean } | null;
    return res.ok && body?.ok === true;
  };
}

export async function handleSendRequest(
  req: Request,
  deps: { db: SenderDb; adapters: Record<string, ProviderAdapter>; checkOwner: OwnerCheck; log: Logger },
): Promise<Response> {
  if (req.method !== "POST") return new Response(null, { status: 405 });
  const authorization = req.headers.get("authorization") ?? "";
  if (!/^Bearer [A-Za-z0-9._-]{20,4096}$/.test(authorization)) return new Response(null, { status: 401 });
  const body = await req.json().catch(() => null) as { send_request_id?: unknown } | null;
  const id = typeof body?.send_request_id === "string" ? body.send_request_id : "";
  if (!UUID.test(id)) {
    return Response.json({ ok: false, error: { code: "VALIDATION_FAILED" } }, { status: 400 });
  }
  if (!(await deps.checkOwner(authorization, id))) {
    deps.log({ event: "send_dispatch_refused", send_request_id: id });
    return Response.json({ ok: false, error: { code: "NOT_FOUND" } }, { status: 404 });
  }
  const out = await runSend(id, { db: deps.db, adapters: deps.adapters, log: deps.log });
  return Response.json({ ok: true, data: { state: out.state, code: out.code ?? null } });
}
