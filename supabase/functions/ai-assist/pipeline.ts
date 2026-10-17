// One AI run: claim (context from the database) → one provider call (one retry on invalid output)
// → hand the output to the database, which validates and persists. Never more than two provider
// calls, never a retry of the database write without first reconciling the run's state.
import { OUTPUT_SCHEMA, outputErrors } from "./output_schema.ts";
import { type AssistContext, buildPrompt, PROMPT_VERSION } from "./prompt.ts";
import { type AiProvider, emptyUsage, ProviderError, type ProviderUsage } from "./provider.ts";
import { type ApiResult, DbUnavailable, type WorkerDb } from "./worker_db.ts";

export interface PipelineSettings {
  model: string;
  effort: "low" | "medium" | "high";
  maxTokens: number;
  providerTimeoutMs: number;
  budgetMs: number;
}

export interface RunOutcome {
  run_id: string;
  status: string;
  error_code?: string;
  suggestion_id?: string | null;
  order_id?: string | null;
  escalated?: boolean;
}

export type Logger = (event: Record<string, unknown>) => void;

const addUsage = (a: ProviderUsage, b: ProviderUsage): ProviderUsage => ({
  input_tokens: a.input_tokens + b.input_tokens,
  output_tokens: a.output_tokens + b.output_tokens,
  cache_read_input_tokens: a.cache_read_input_tokens + b.cache_read_input_tokens,
  cache_creation_input_tokens: a.cache_creation_input_tokens + b.cache_creation_input_tokens,
});

export async function runAssist(
  runId: string,
  deps: {
    db: WorkerDb;
    provider: AiProvider;
    settings: PipelineSettings;
    log: Logger;
    correlationId: string;
    now?: () => number;
  },
): Promise<RunOutcome> {
  const { db, provider, settings, log, correlationId } = deps;
  const now = deps.now ?? (() => Date.now());
  const started = now();

  const claim = await db.claimRun(runId);
  if (!claim.ok) {
    log({ event: "claim_refused", run_id: runId, code: claim.error?.code, correlation_id: correlationId });
    return { run_id: runId, status: "not_claimed", error_code: claim.error?.code ?? "RUN_NOT_CLAIMABLE" };
  }
  const context = claim.data!.context as AssistContext;
  const mode = claim.data!.mode === "draft" ? "draft" : "reply";
  const prompt = buildPrompt(context, mode);

  let usage = emptyUsage();
  let attempts = 0;
  let servedModel: string | null = null;
  let requestId: string | null = null;
  let stopReason: string | null = null;
  let output: unknown = null;
  let invalid: string[] = [];
  const meta = () => ({
    model: settings.model,
    served_model: servedModel,
    prompt_version: PROMPT_VERSION,
    effort: settings.effort,
    stop_reason: stopReason,
    request_id: requestId,
    correlation_id: correlationId,
    attempts,
    latency_ms: now() - started,
    usage,
  });

  try {
    while (attempts < 2) {
      attempts++;
      const remaining = settings.budgetMs - (now() - started);
      if (attempts > 1 && remaining < settings.providerTimeoutMs / 2) break; // no time for a second try
      const response = await provider.generate({
        system: prompt.system,
        user: prompt.user,
        schema: OUTPUT_SCHEMA,
        model: settings.model,
        effort: settings.effort,
        maxTokens: settings.maxTokens,
        timeoutMs: Math.max(1000, Math.min(settings.providerTimeoutMs, remaining)),
      });
      usage = addUsage(usage, response.usage);
      servedModel = response.servedModel;
      requestId = response.requestId;
      stopReason = response.stopReason;
      if (response.stopReason === "refusal") {
        return await finishFailure(db, runId, "refused", "refusal", meta(), log, correlationId);
      }
      if (response.stopReason === "max_tokens" || response.text === null) {
        invalid = [response.stopReason === "max_tokens" ? "truncated" : "empty"];
        continue;
      }
      try {
        output = JSON.parse(response.text);
      } catch {
        invalid = ["not_json"];
        continue;
      }
      invalid = outputErrors(output);
      if (invalid.length === 0) break;
    }
  } catch (error) {
    const e = error instanceof ProviderError ? error : new ProviderError("provider_error", "unexpected");
    requestId = e.requestId ?? requestId;
    const status = e.kind === "timeout"
      ? "timeout"
      : e.kind === "rate_limited"
      ? "rate_limited"
      : "provider_error";
    return await finishFailure(db, runId, status, e.code, meta(), log, correlationId);
  }

  if (invalid.length > 0 || output === null) {
    log({
      event: "invalid_output",
      run_id: runId,
      errors: invalid.slice(0, 10),
      correlation_id: correlationId,
    });
    return await finishFailure(
      db,
      runId,
      "invalid_output",
      invalid[0] ?? "invalid",
      meta(),
      log,
      correlationId,
    );
  }

  let result: ApiResult;
  try {
    result = await db.completeRun(runId, output, meta());
  } catch (error) {
    if (!(error instanceof DbUnavailable)) throw error;
    // The write may have committed. Reconcile before deciding (never write blindly twice).
    const state = await db.runState(runId);
    const status = state.data?.status as string | undefined;
    log({ event: "complete_reconciled", run_id: runId, status, correlation_id: correlationId });
    if (status !== "running") return { run_id: runId, status: status ?? "unknown" };
    result = await db.completeRun(runId, output, meta());
  }
  const data = (result.data ?? {}) as Record<string, unknown>;
  log({
    event: "run_finished",
    run_id: runId,
    status: result.ok ? "succeeded" : result.error?.code,
    attempts,
    latency_ms: now() - started,
    input_tokens: usage.input_tokens,
    output_tokens: usage.output_tokens,
    cache_read_tokens: usage.cache_read_input_tokens,
    escalated: data.escalated ?? null,
    correlation_id: correlationId,
  });
  if (!result.ok) return { run_id: runId, status: "invalid_output", error_code: result.error?.code };
  return {
    run_id: runId,
    status: "succeeded",
    suggestion_id: (data.suggestion_id as string) ?? null,
    order_id: (data.order_id as string) ?? null,
    escalated: Boolean(data.escalated),
  };
}

async function finishFailure(
  db: WorkerDb,
  runId: string,
  status: string,
  code: string,
  meta: Record<string, unknown>,
  log: Logger,
  correlationId: string,
): Promise<RunOutcome> {
  log({ event: "run_failed", run_id: runId, status, code, correlation_id: correlationId });
  try {
    await db.failRun(runId, status, code, meta);
  } catch (error) {
    if (!(error instanceof DbUnavailable)) throw error;
    // The run expires on its own; the seller can retry.
  }
  return { run_id: runId, status, error_code: code };
}
