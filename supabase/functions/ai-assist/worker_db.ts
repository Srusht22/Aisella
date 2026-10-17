// The worker's database access: its own login role (aisellia_ai_worker), four functions, nothing else.
import postgres from "postgres";

export interface ApiResult<T = Record<string, unknown>> {
  ok: boolean;
  data?: T;
  error?: { code: string; details?: Record<string, unknown> };
}

export interface WorkerDb {
  claimRun(runId: string): Promise<ApiResult>;
  completeRun(runId: string, output: unknown, meta: Record<string, unknown>): Promise<ApiResult>;
  failRun(
    runId: string,
    status: string,
    errorCode: string,
    meta: Record<string, unknown>,
  ): Promise<ApiResult>;
  runState(runId: string): Promise<ApiResult>;
}

/** A transport failure: the call may or may not have reached the database. */
export class DbUnavailable extends Error {}

export class PostgresWorkerDb implements WorkerDb {
  readonly #url: string;

  constructor(url: string) {
    this.#url = url;
  }

  async #call(text: string, params: unknown[]): Promise<ApiResult> {
    // One short-lived connection per call: no state survives between steps, and a lost
    // connection is reported as DbUnavailable so the pipeline reconciles instead of guessing.
    const sql = postgres(this.#url, {
      max: 1,
      prepare: false,
      connect_timeout: 5,
      idle_timeout: 1,
      onnotice: () => {},
    });
    try {
      const rows = await sql.unsafe(text, params as postgres.ParameterOrJSON<never>[]);
      return rows[0].r as ApiResult;
    } catch (error) {
      if (error instanceof postgres.PostgresError) throw error;
      throw new DbUnavailable("worker database unavailable");
    } finally {
      await sql.end({ timeout: 2 }).catch(() => {});
    }
  }

  claimRun(runId: string) {
    return this.#call("select api.ai_claim_run($1::uuid) as r", [runId]);
  }
  completeRun(runId: string, output: unknown, meta: Record<string, unknown>) {
    return this.#call("select api.ai_complete_run($1::uuid, $2::jsonb, $3::jsonb) as r", [
      runId,
      // Objects, not strings: the driver encodes jsonb parameters itself.
      output,
      meta,
    ]);
  }
  failRun(runId: string, status: string, errorCode: string, meta: Record<string, unknown>) {
    return this.#call("select api.ai_fail_run($1::uuid, $2, $3, $4::jsonb) as r", [
      runId,
      status,
      errorCode,
      meta,
    ]);
  }
  runState(runId: string) {
    return this.#call("select api.ai_run_state($1::uuid) as r", [runId]);
  }
}
