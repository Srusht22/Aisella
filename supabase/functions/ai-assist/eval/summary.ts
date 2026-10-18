// Pure helpers of the real-model evaluation: argument parsing and the per-language report.
// Kept apart from run_eval.ts so they are tested without a key, a database or a model.

/** Server flags that mean the model wrote something it may not state itself. */
export const FABRICATION_FLAGS = [
  "money",
  "discount",
  "promise",
  "claim",
  "stock_count",
  "unverified_number",
  "invalid_reference",
] as const;

export interface EvalResult {
  id: string;
  lang: string;
  pass: boolean;
  failures: string[];
  /** "succeeded", another run status, or "not_run" (budget reached). */
  run_status: string;
  expected_escalated: boolean | null;
  escalated: boolean;
  /** Whether the scenario expects specific server-rendered facts (a grounding check). */
  grounding_expected: boolean;
  grounding_ok: boolean;
  flags: string[];
  is_holding: boolean;
  order_status: string | null;
  approved: boolean;
  latency_ms: number | null;
  cost_micro_usd: number | null;
}

export interface LanguageSummary {
  scenarios: number;
  ran: number;
  passed: number;
  failed_runs: number;
  grounded: { expected: number; ok: number };
  fabrication: { attempts_caught: number; shown_to_seller: number };
  escalation: { expected: number; caught: number; missed: number; false_alarms: number };
  orders: { advanced_past_review: number; approved: number };
  latency_ms: { p50: number | null; p95: number | null; max: number | null };
  cost_usd: { total: number; mean_per_run: number | null };
}

export interface EvalArgs {
  ids: string[];
  maxCostUsd: number;
  setPath: string | null;
  plan: boolean;
}

export class ArgsError extends Error {}

export function parseArgs(args: string[]): EvalArgs {
  const out: EvalArgs = { ids: [], maxCostUsd: 2, setPath: null, plan: false };
  for (const a of args) {
    if (a === "--plan") out.plan = true;
    else if (a.startsWith("--max-cost-usd=")) {
      const n = Number(a.slice("--max-cost-usd=".length));
      if (!Number.isFinite(n) || n <= 0 || n > 100) {
        throw new ArgsError("--max-cost-usd must be between 0 and 100");
      }
      out.maxCostUsd = n;
    } else if (a.startsWith("--set=")) {
      out.setPath = a.slice("--set=".length);
      if (out.setPath === "") throw new ArgsError("--set needs a path");
    } else if (a.startsWith("--")) throw new ArgsError(`unknown option ${a}`);
    else out.ids.push(a);
  }
  return out;
}

function percentile(sorted: number[], p: number): number | null {
  if (sorted.length === 0) return null;
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
}

export function summarize(results: EvalResult[]): LanguageSummary {
  const ran = results.filter((r) => r.run_status !== "not_run");
  const latencies = ran.map((r) => r.latency_ms).filter((l): l is number => l !== null).sort((a, b) => a - b);
  const costed = ran.filter((r) => r.cost_micro_usd !== null);
  const total = costed.reduce((a, r) => a + Number(r.cost_micro_usd), 0) / 1e6;
  const fabricated = (r: EvalResult) =>
    r.flags.some((f) => (FABRICATION_FLAGS as readonly string[]).includes(f));
  return {
    scenarios: results.length,
    ran: ran.length,
    passed: ran.filter((r) => r.pass).length,
    failed_runs: ran.filter((r) => r.run_status !== "succeeded").length,
    grounded: {
      expected: ran.filter((r) => r.grounding_expected).length,
      ok: ran.filter((r) => r.grounding_expected && r.grounding_ok).length,
    },
    fabrication: {
      attempts_caught: ran.filter((r) => fabricated(r) && r.is_holding).length,
      shown_to_seller: ran.filter((r) => fabricated(r) && !r.is_holding).length,
    },
    escalation: {
      expected: ran.filter((r) => r.expected_escalated === true).length,
      caught: ran.filter((r) => r.expected_escalated === true && r.escalated).length,
      missed: ran.filter((r) => r.expected_escalated === true && !r.escalated).length,
      false_alarms: ran.filter((r) => r.expected_escalated === false && r.escalated).length,
    },
    orders: {
      advanced_past_review:
        ran.filter((r) => r.order_status !== null && !["draft", "pending_approval"].includes(r.order_status))
          .length,
      approved: ran.filter((r) => r.approved).length,
    },
    latency_ms: {
      p50: percentile(latencies, 50),
      p95: percentile(latencies, 95),
      max: latencies.at(-1) ?? null,
    },
    cost_usd: {
      total: Math.round(total * 1e6) / 1e6,
      mean_per_run: costed.length ? Math.round((total / costed.length) * 1e6) / 1e6 : null,
    },
  };
}

/** Overall and per-language summaries (en, ckb, ar, and any other language present). */
export function report(results: EvalResult[]): Record<string, LanguageSummary> {
  const langs = [...new Set(results.map((r) => r.lang))].sort();
  return Object.fromEntries([
    ["all", summarize(results)],
    ...langs.map((l) => [l, summarize(results.filter((r) => r.lang === l))]),
  ]);
}
