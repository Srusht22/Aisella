// Gemini through the Generative Language REST API (`models/{model}:generateContent`), asking for one
// JSON document that follows the output schema. The key travels in the `x-goog-api-key` header,
// never in the URL, so it cannot end up in proxy or access logs.
//
// Request and response shapes follow the public Gemini API reference. They could not be re-read on
// the official page from this environment (network policy), so they are covered here by a local
// stub only; a real call is part of the staging preflight (ops/staging_check.ts --provider).
import { type AiProvider, ProviderError, type ProviderRequest, type ProviderResponse } from "./provider.ts";

export interface GeminiProviderOptions {
  apiKey: string | null;
  /** Overrides the API host (tests point it at a local stub); default https://generativelanguage.googleapis.com. */
  baseURL?: string;
  /** Retries on 429 / 5xx / connection errors (Phase 3 AI §11: at most 1). */
  maxRetries?: number;
  /**
   * `json_schema` sends the output schema as `responseJsonSchema`; `json_only` asks only for JSON
   * (the prompt and the database still enforce the shape). A fallback if a model refuses the schema.
   */
  structuredOutput?: "json_schema" | "json_only";
  fetchFn?: typeof fetch;
}

const DEFAULT_BASE = "https://generativelanguage.googleapis.com";

/** Finish reasons that mean the model (or Google's filters) declined to answer. */
const REFUSALS = new Set(["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION", "IMAGE_SAFETY"]);

/** Effort → thinking: a budget in tokens for 2.x models, a level for later ones. */
function thinkingConfig(model: string, effort: ProviderRequest["effort"]): Record<string, unknown> {
  if (/^gemini-[3-9]/.test(model)) return { thinkingLevel: effort === "low" ? "low" : "high" };
  return { thinkingBudget: effort === "low" ? 1024 : effort === "medium" ? 4096 : 16384 };
}

export function geminiRequestBody(
  request: ProviderRequest,
  structuredOutput: "json_schema" | "json_only",
): Record<string, unknown> {
  return {
    // Gemini caches repeated prefixes implicitly: the stable blocks come first, unchanged.
    systemInstruction: { parts: request.system.map((b) => ({ text: b.text })) },
    contents: [{ role: "user", parts: [{ text: request.user }] }],
    generationConfig: {
      maxOutputTokens: request.maxTokens,
      responseMimeType: "application/json",
      ...(structuredOutput === "json_schema" ? { responseJsonSchema: request.schema } : {}),
      thinkingConfig: thinkingConfig(request.model, request.effort),
    },
  };
}

interface GeminiResponse {
  candidates?: {
    content?: { parts?: { text?: string; thought?: boolean }[] };
    finishReason?: string;
  }[];
  promptFeedback?: { blockReason?: string };
  usageMetadata?: {
    promptTokenCount?: number;
    candidatesTokenCount?: number;
    thoughtsTokenCount?: number;
    cachedContentTokenCount?: number;
  };
  modelVersion?: string;
  responseId?: string;
}

export function parseGeminiResponse(body: GeminiResponse): ProviderResponse {
  const candidate = body.candidates?.[0];
  const finish = candidate?.finishReason ?? null;
  const blocked = body.promptFeedback?.blockReason ?? null;
  const text = (candidate?.content?.parts ?? [])
    .filter((p) => !p.thought && typeof p.text === "string")
    .map((p) => p.text)
    .join("");
  const usage = body.usageMetadata ?? {};
  const prompt = Math.max(0, usage.promptTokenCount ?? 0);
  const cached = Math.min(prompt, Math.max(0, usage.cachedContentTokenCount ?? 0));
  return {
    text: text === "" ? null : text,
    // Mapped onto the pipeline's stop reasons; the original is kept after the colon.
    stopReason: blocked || (finish && REFUSALS.has(finish))
      ? "refusal"
      : finish === "MAX_TOKENS"
      ? "max_tokens"
      : finish === "STOP"
      ? "end_turn"
      : finish
      ? `other:${finish.toLowerCase().slice(0, 30)}`
      : null,
    servedModel: body.modelVersion ?? null,
    requestId: body.responseId ?? null,
    inferenceGeo: null,
    usage: {
      // Same meaning as the Anthropic fields: uncached input, cached input, and output (thinking
      // tokens are billed as output).
      input_tokens: prompt - cached,
      output_tokens: Math.max(0, usage.candidatesTokenCount ?? 0) +
        Math.max(0, usage.thoughtsTokenCount ?? 0),
      cache_read_input_tokens: cached,
      cache_creation_input_tokens: 0,
    },
  };
}

export class GeminiProvider implements AiProvider {
  readonly name = "gemini";
  readonly #key: string | null;
  readonly #base: string;
  readonly #retries: number;
  readonly #structured: "json_schema" | "json_only";
  readonly #fetch: typeof fetch;

  constructor(options: GeminiProviderOptions) {
    this.#key = options.apiKey;
    // Explicit, so no ambient setting can redirect customer data.
    this.#base = (options.baseURL ?? DEFAULT_BASE).replace(/\/+$/, "");
    this.#retries = Math.max(0, Math.min(options.maxRetries ?? 1, 1));
    this.#structured = options.structuredOutput ?? "json_schema";
    this.#fetch = options.fetchFn ?? fetch;
  }

  async generate(request: ProviderRequest): Promise<ProviderResponse> {
    if (!this.#key) throw new ProviderError("not_configured", "no_api_key");
    if (!/^[a-z0-9.-]{3,80}$/.test(request.model)) throw new ProviderError("provider_error", "bad_model");
    const url = `${this.#base}/v1beta/models/${request.model}:generateContent`;
    const body = JSON.stringify(geminiRequestBody(request, this.#structured));
    const deadline = Date.now() + request.timeoutMs;
    let last: ProviderError | null = null;
    for (let attempt = 0; attempt <= this.#retries; attempt++) {
      const left = deadline - Date.now();
      if (left <= 0) break;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), left);
      try {
        const res = await this.#fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json", "x-goog-api-key": this.#key },
          body,
          signal: controller.signal,
        });
        if (res.ok) return parseGeminiResponse(await res.json() as GeminiResponse);
        await res.body?.cancel();
        last = httpError(res.status);
        if (!(res.status === 429 || res.status >= 500)) throw last;
      } catch (error) {
        if (error instanceof ProviderError) throw error;
        if (controller.signal.aborted || (error instanceof DOMException && error.name === "AbortError")) {
          throw new ProviderError("timeout", "provider_timeout");
        }
        // Response body that is not JSON: never retried (the call may have been billed).
        if (error instanceof SyntaxError) throw new ProviderError("provider_error", "bad_response");
        last = new ProviderError("provider_error", "connection");
      } finally {
        clearTimeout(timer);
      }
    }
    throw last ?? new ProviderError("timeout", "provider_timeout");
  }
}

/** Maps HTTP statuses to stored codes. Bodies are never copied: they may echo request content. */
function httpError(status: number): ProviderError {
  if (status === 429) return new ProviderError("rate_limited", "provider_rate_limited", status);
  if (status === 401 || status === 403) return new ProviderError("provider_error", "auth", status);
  if (status === 400) return new ProviderError("provider_error", "bad_request", status);
  if (status === 404) return new ProviderError("provider_error", "model_not_found", status);
  if (status === 503) return new ProviderError("provider_error", "overloaded", status);
  if (status >= 500) return new ProviderError("provider_error", "server_error", status);
  return new ProviderError("provider_error", `http_${status}`, status);
}
