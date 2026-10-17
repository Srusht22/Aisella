// The seller's side of a run: their own JWT, forwarded to api.request_ai_assist through PostgREST.
// The database checks membership, the AI switch, quotas and idempotency; this function holds no
// privilege of its own on that path.
import type { ApiResult } from "./worker_db.ts";

export interface SellerApi {
  requestAssist(
    jwt: string,
    body: AssistRequest,
  ): Promise<ApiResult<{ run_id: string; status: string; replayed: boolean }>>;
}

export interface AssistRequest {
  store_id: string;
  conversation_id: string;
  mode: "reply" | "draft";
  idempotency_key: string;
}

export class PostgrestSellerApi implements SellerApi {
  constructor(private readonly url: string, private readonly anonKey: string) {}

  async requestAssist(jwt: string, body: AssistRequest) {
    const response = await fetch(`${this.url}/rest/v1/rpc/request_ai_assist`, {
      method: "POST",
      headers: {
        apikey: this.anonKey,
        Authorization: `Bearer ${jwt}`,
        "Content-Type": "application/json",
        "Content-Profile": "api",
        "Accept-Profile": "api",
      },
      body: JSON.stringify({
        p_store_id: body.store_id,
        p_conversation_id: body.conversation_id,
        p_mode: body.mode,
        p_idempotency_key: body.idempotency_key,
      }),
      signal: AbortSignal.timeout(10000),
    });
    if (response.status === 401 || response.status === 403) {
      await response.body?.cancel();
      return { ok: false, error: { code: response.status === 401 ? "UNAUTHENTICATED" : "FORBIDDEN" } };
    }
    if (!response.ok) {
      await response.body?.cancel();
      return { ok: false, error: { code: "INTERNAL" } };
    }
    return await response.json();
  }
}
