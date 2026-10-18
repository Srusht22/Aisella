// The one place that turns configuration into a model provider. Everything above it (pipeline,
// database checks, limits) is provider-neutral.
import { AnthropicProvider } from "./anthropic_provider.ts";
import type { AiProviderName } from "./config.ts";
import { GeminiProvider } from "./gemini_provider.ts";
import type { AiProvider } from "./provider.ts";

export function createProvider(config: {
  provider: AiProviderName;
  geminiApiKey: string | null;
  geminiStructuredOutput?: "json_schema" | "json_only";
  anthropicApiKey: string | null;
}): AiProvider {
  return config.provider === "anthropic"
    ? new AnthropicProvider({ apiKey: config.anthropicApiKey })
    : new GeminiProvider({ apiKey: config.geminiApiKey, structuredOutput: config.geminiStructuredOutput });
}
