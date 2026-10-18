// Database access for the channel functions: each uses its own LOGIN role with a fixed function
// set (aisellia_channel_ingest: raw ingest and the handshake check; aisellia_channel_sender: 4).
// Never the service role.
import postgres from "postgres";

export interface ApiResult<T = Record<string, unknown>> {
  ok: boolean;
  data?: T;
  error?: { code: string; details?: Record<string, unknown> };
}

/** A transport failure: the call may or may not have reached the database. */
export class DbUnavailable extends Error {}

export interface IngestDb {
  /** Raw bytes and the signature headers; the database verifies, normalises and stores. */
  ingestRaw(
    provider: string,
    connectionHint: string | null,
    raw: Uint8Array,
    headers: Record<string, string>,
  ): Promise<ApiResult>;
  challenge(provider: string, verifyToken: string): Promise<ApiResult>;
}

export interface ClaimedSend {
  send_request_id: string;
  provider: string;
  account_id: string;
  recipient: string;
  text: string;
  text_sha256: string;
  credential: string | null;
  attempt: number;
  /** The connection's display name (providers that require a sender name). */
  sender_name?: string | null;
  /** Template sends: what to submit; `text` is its rendering, re-checked before submission. */
  template?: { name: string; language: string; body_text: string; params: string[] } | null;
}

export interface TemplateSync {
  connection_id: string;
  provider: string;
  waba_id: string;
  credential: string | null;
}

export interface SenderDb {
  claim(sendRequestId: string): Promise<ApiResult<ClaimedSend>>;
  complete(sendRequestId: string, providerMessageId: string, textSha256: string): Promise<ApiResult>;
  fail(
    sendRequestId: string,
    outcome: "retriable" | "permanent" | "unknown" | "integrity",
    code: string,
    retryAfterMs: number | null,
  ): Promise<ApiResult>;
  state(sendRequestId: string): Promise<ApiResult>;
}

/** The worker's extra read: which queued sends are due, chosen fairly by the database. */
export interface WorkerDb extends SenderDb {
  dueSends(limit: number): Promise<ApiResult<{ ids: string[] }>>;
  /** Connections whose access token expires soon and can be refreshed (TikTok). */
  dueRefreshes?(): Promise<
    ApiResult<{ items: { connection_id: string; provider: string; refresh_token: string }[] }>
  >;
  /** WhatsApp numbers whose template list is stale, with the token to read it. */
  dueTemplateSyncs?(): Promise<ApiResult<{ items: TemplateSync[] }>>;
  storeTemplates?(connectionId: string, templates: unknown[]): Promise<ApiResult>;
  storeRefresh?(
    connectionId: string,
    ok: boolean,
    accessToken: string | null,
    refreshToken: string | null,
    expiresAt: string | null,
  ): Promise<ApiResult>;
}

async function call<T = Record<string, unknown>>(
  url: string,
  text: string,
  params: unknown[],
): Promise<ApiResult<T>> {
  // One short-lived connection per call; a lost connection is DbUnavailable so callers reconcile
  // instead of guessing.
  const sql = postgres(url, {
    max: 1,
    prepare: false,
    connect_timeout: 5,
    idle_timeout: 1,
    onnotice: () => {},
  });
  try {
    const rows = await sql.unsafe(text, params as postgres.ParameterOrJSON<never>[]);
    return rows[0].r as ApiResult<T>;
  } catch (error) {
    if (error instanceof postgres.PostgresError) throw error;
    throw new DbUnavailable("channel database unavailable");
  } finally {
    await sql.end({ timeout: 2 }).catch(() => {});
  }
}

export interface ConnectorDb {
  register(
    nonce: string,
    provider: string,
    accountId: string,
    displayName: string,
    credential: string,
    webhookSecret: string,
  ): Promise<ApiResult<{ connection_id: string }>>;
  finish(nonce: string, ok: boolean): Promise<ApiResult>;
  /** One OAuth-granted account (Page, Instagram account, WhatsApp number, TikTok business). */
  registerAccount?(
    nonce: string,
    provider: string,
    a: {
      accountId: string;
      displayName: string;
      credential: string;
      refreshToken: string | null;
      expiresAt: string | null;
      meta: Record<string, string>;
    },
  ): Promise<ApiResult<{ connection_id: string }>>;
}

/** The aisellia_channel_connector role: it can only redeem a seller's connect nonce. */
export class PostgresConnectorDb implements ConnectorDb {
  constructor(private readonly url: string) {}
  register(
    nonce: string,
    provider: string,
    accountId: string,
    displayName: string,
    credential: string,
    webhookSecret: string,
  ) {
    return call<{ connection_id: string }>(
      this.url,
      "select api.channel_register_bot($1, $2, $3, $4, $5, $6) as r",
      [nonce, provider, accountId, displayName, credential, webhookSecret],
    );
  }
  finish(nonce: string, ok: boolean) {
    return call(this.url, "select api.channel_finish_connect($1, $2) as r", [nonce, ok]);
  }
  registerAccount(
    nonce: string,
    provider: string,
    a: {
      accountId: string;
      displayName: string;
      credential: string;
      refreshToken: string | null;
      expiresAt: string | null;
      meta: Record<string, string>;
    },
  ) {
    return call<{ connection_id: string }>(
      this.url,
      "select api.channel_register_account($1, $2, $3, $4, $5, $6, $7::timestamptz, $8::jsonb) as r",
      [nonce, provider, a.accountId, a.displayName, a.credential, a.refreshToken, a.expiresAt, a.meta],
    );
  }
}

export class PostgresIngestDb implements IngestDb {
  constructor(private readonly url: string) {}
  ingestRaw(provider: string, hint: string | null, raw: Uint8Array, headers: Record<string, string>) {
    return call(this.url, "select api.channel_ingest_raw($1, $2, $3::bytea, $4::jsonb) as r", [
      provider,
      hint,
      raw, // bytes: the signature is over these exact bytes
      headers, // an object: the driver encodes jsonb itself
    ]);
  }
  challenge(provider: string, verifyToken: string) {
    return call(this.url, "select api.channel_webhook_challenge($1, $2) as r", [provider, verifyToken]);
  }
}

export class PostgresSenderDb implements WorkerDb {
  constructor(private readonly url: string) {}
  dueSends(limit: number) {
    return call<{ ids: string[] }>(this.url, "select api.channel_due_sends($1) as r", [limit]);
  }
  dueRefreshes() {
    return call<{ items: { connection_id: string; provider: string; refresh_token: string }[] }>(
      this.url,
      "select api.channel_due_refreshes() as r",
      [],
    );
  }
  storeRefresh(
    id: string,
    ok: boolean,
    accessToken: string | null,
    refreshToken: string | null,
    expiresAt: string | null,
  ) {
    return call(this.url, "select api.channel_store_refresh($1::uuid, $2, $3, $4, $5::timestamptz) as r", [
      id,
      ok,
      accessToken,
      refreshToken,
      expiresAt,
    ]);
  }
  dueTemplateSyncs() {
    return call<{ items: TemplateSync[] }>(this.url, "select api.channel_due_template_syncs() as r", []);
  }
  storeTemplates(id: string, templates: unknown[]) {
    return call(this.url, "select api.channel_store_templates($1::uuid, $2::jsonb) as r", [id, templates]);
  }
  claim(id: string) {
    return call<ClaimedSend>(this.url, "select api.channel_claim_send($1::uuid) as r", [id]);
  }
  complete(id: string, providerMessageId: string, textSha256: string) {
    return call(this.url, "select api.channel_complete_send($1::uuid, $2, $3) as r", [
      id,
      providerMessageId,
      textSha256,
    ]);
  }
  fail(id: string, outcome: string, code: string, retryAfterMs: number | null) {
    return call(this.url, "select api.channel_fail_send($1::uuid, $2, $3, $4) as r", [
      id,
      outcome,
      code,
      retryAfterMs,
    ]);
  }
  state(id: string) {
    return call(this.url, "select api.channel_send_state($1::uuid) as r", [id]);
  }
}
