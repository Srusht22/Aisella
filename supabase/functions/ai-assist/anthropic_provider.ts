// Claude through the official Anthropic SDK (Messages API, structured JSON output).
import Anthropic from "@anthropic-ai/sdk";
import { type AiProvider, ProviderError, type ProviderRequest, type ProviderResponse } from "./provider.ts";

export interface AnthropicProviderOptions {
  apiKey: string | null;
  /** Overrides the API host (tests point it at a local stub); default https://api.anthropic.com. */
  baseURL?: string;
  /** SDK retries on 429 / 5xx / connection errors, with backoff (Phase 3 AI §11: at most 1). */
  maxRetries?: number;
}

export class AnthropicProvider implements AiProvider {
  readonly name = "anthropic";
  readonly #client: Anthropic | null;

  constructor(options: AnthropicProviderOptions) {
    this.#client = options.apiKey
      ? new Anthropic({
        apiKey: options.apiKey,
        // Explicit, so an ambient ANTHROPIC_BASE_URL can never redirect customer data.
        baseURL: options.baseURL ?? "https://api.anthropic.com",
        maxRetries: options.maxRetries ?? 1,
      })
      : null;
  }

  async generate(request: ProviderRequest): Promise<ProviderResponse> {
    if (!this.#client) throw new ProviderError("not_configured", "no_api_key");
    let response: Anthropic.Message;
    try {
      response = await this.#client.messages.create(
        {
          model: request.model,
          max_tokens: request.maxTokens,
          system: request.system.map((b) =>
            b.cache
              ? { type: "text" as const, text: b.text, cache_control: { type: "ephemeral" as const } }
              : { type: "text" as const, text: b.text }
          ),
          messages: [{ role: "user", content: request.user }],
          output_config: { effort: request.effort, format: { type: "json_schema", schema: request.schema } },
        },
        { timeout: request.timeoutMs },
      );
    } catch (error) {
      throw toProviderError(error);
    }
    const text = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("");
    const usage = response.usage;
    return {
      text: text === "" ? null : text,
      stopReason: response.stop_reason ?? null,
      servedModel: response.model ?? null,
      requestId: (response as { _request_id?: string | null })._request_id ?? null,
      usage: {
        input_tokens: usage?.input_tokens ?? 0,
        output_tokens: usage?.output_tokens ?? 0,
        cache_read_input_tokens: usage?.cache_read_input_tokens ?? 0,
        cache_creation_input_tokens: usage?.cache_creation_input_tokens ?? 0,
      },
    };
  }
}

/** Maps SDK errors to stored codes. Messages are never copied: they may echo request content. */
export function toProviderError(error: unknown): ProviderError {
  if (error instanceof ProviderError) return error;
  if (error instanceof Anthropic.APIConnectionTimeoutError) {
    return new ProviderError("timeout", "provider_timeout");
  }
  if (error instanceof Anthropic.APIConnectionError) return new ProviderError("provider_error", "connection");
  if (error instanceof Anthropic.APIError) {
    const status = typeof error.status === "number" ? error.status : null;
    const requestId = (error as { requestID?: string | null }).requestID ?? null;
    if (status === 429) return new ProviderError("rate_limited", "provider_rate_limited", status, requestId);
    if (status === 401 || status === 403) {
      return new ProviderError("provider_error", "auth", status, requestId);
    }
    if (status === 400) return new ProviderError("provider_error", "bad_request", status, requestId);
    if (status === 529) return new ProviderError("provider_error", "overloaded", status, requestId);
    if (status !== null && status >= 500) {
      return new ProviderError("provider_error", "server_error", status, requestId);
    }
    return new ProviderError("provider_error", `http_${status ?? "unknown"}`, status, requestId);
  }
  if (error instanceof DOMException && error.name === "AbortError") {
    return new ProviderError("timeout", "aborted");
  }
  return new ProviderError("provider_error", "unexpected");
}
