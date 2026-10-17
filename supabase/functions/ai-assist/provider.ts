// The only provider-specific seam (Phase 3 AI §3). The pipeline asks for one structured JSON
// answer; a provider returns it with usage metadata or throws a ProviderError.

export interface PromptBlock {
  text: string;
  /** Stable blocks are marked for prompt caching (system rules, store context). */
  cache: boolean;
}

export interface ProviderRequest {
  system: PromptBlock[];
  user: string;
  schema: Record<string, unknown>;
  model: string;
  effort: "low" | "medium" | "high";
  maxTokens: number;
  timeoutMs: number;
  /** Requested inference region; null or absent leaves the provider's default. */
  inferenceGeo?: "global" | "us" | null;
}

export interface ProviderUsage {
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_creation_input_tokens: number;
}

export interface ProviderResponse {
  /** The model's text output (expected to be the JSON document), or null when there was none. */
  text: string | null;
  stopReason: string | null;
  servedModel: string | null;
  requestId: string | null;
  usage: ProviderUsage;
  /** Where the provider reports inference ran, when it says. */
  inferenceGeo?: string | null;
}

export type ProviderErrorKind = "timeout" | "rate_limited" | "provider_error" | "not_configured";

export class ProviderError extends Error {
  constructor(
    readonly kind: ProviderErrorKind,
    /** A short machine code safe to store and log (never contains request content or keys). */
    readonly code: string,
    readonly status: number | null = null,
    readonly requestId: string | null = null,
  ) {
    super(`${kind}:${code}`);
  }
}

export interface AiProvider {
  readonly name: string;
  generate(request: ProviderRequest): Promise<ProviderResponse>;
}

export const emptyUsage = (): ProviderUsage => ({
  input_tokens: 0,
  output_tokens: 0,
  cache_read_input_tokens: 0,
  cache_creation_input_tokens: 0,
});
