#!/usr/bin/env python3
"""Aisellia pilot AI cost model (Phase 3). Standard library only.

Every number below is an ASSUMPTION or a PUBLISHED PRICE, labelled as such.
Run: python3 docs/architecture/phase-3/tools/cost_model.py
"""

# Published per-million-token prices (Anthropic Claude API reference, cached 2026-10-06).
# cache_write = 1.25x input (5-minute TTL); cache_read per the reference
# (Opus 5.5: $0.20 = 0.05x; Sonnet 5.5: $0.20; Haiku 5.5: ASSUMED 0.1x input = $0.01).
PRICES = {
    "claude-opus-5-5":   {"in": 4.00, "out": 20.00, "cache_read": 0.20, "cache_write": 5.00},
    "claude-sonnet-5-5": {"in": 2.00, "out": 10.00, "cache_read": 0.20, "cache_write": 2.50},
    "claude-haiku-5-5":  {"in": 0.10, "out": 0.50,  "cache_read": 0.01, "cache_write": 0.125},
}

# ASSUMED tokens per AI call (estimates to be replaced by measured ai_runs data in Phase 8).
CACHED_PREFIX = 3_000 + 6_000   # system/instructions/schema + store context (~240 variants)
UNCACHED_INPUT = 2_500          # availability map + conversation + draft state
OUTPUT = 1_600                  # ~600 visible JSON + ~1,000 thinking tokens at low effort (unmeasured)
CALLS_PER_CONVERSATION = 2.5    # first message, follow-up after customer reply, occasional regenerate

SCENARIOS = {  # sellers, conversations per seller per day, days per month
    "A  pilot-small  (3 sellers x 10 conv/day)": (3, 10, 30),
    "B  pilot-target (5 sellers x 25 conv/day)": (5, 25, 30),
    "C  growth       (30 sellers x 30 conv/day)": (30, 30, 30),
}


def cost_per_call(p, hit_rate, output=OUTPUT):
    prefix = CACHED_PREFIX * (hit_rate * p["cache_read"] + (1 - hit_rate) * p["cache_write"])
    return (prefix + UNCACHED_INPUT * p["in"] + output * p["out"]) / 1e6


def main():
    print("Cost per AI call (USD)")
    print(f"{'model':20} {'hit 20%':>9} {'hit 50%':>9} {'hit 80%':>9} {'50%, 2x output':>15}")
    for m, p in PRICES.items():
        row = [cost_per_call(p, h) for h in (0.2, 0.5, 0.8)] + [cost_per_call(p, 0.5, OUTPUT * 2)]
        print(f"{m:20} " + " ".join(f"{v:9.4f}" for v in row[:3]) + f" {row[3]:15.4f}")
    print("\nMonthly AI cost by scenario (USD; 50% cache hit; range = 20%..80% hit and 1x..2x output)")
    print(f"{'scenario':46} {'calls/mo':>9} " + " ".join(f"{m.split('-')[1]:>22}" for m in PRICES))
    for name, (sellers, conv, days) in SCENARIOS.items():
        calls = sellers * conv * days * CALLS_PER_CONVERSATION
        cells = []
        for p in PRICES.values():
            base = calls * cost_per_call(p, 0.5)
            lo = calls * cost_per_call(p, 0.8)
            hi = calls * cost_per_call(p, 0.2, OUTPUT * 2)
            cells.append(f"{base:7.0f} ({lo:5.0f}-{hi:5.0f})")
        print(f"{name:46} {calls:9.0f} " + " ".join(f"{c:>22}" for c in cells))


if __name__ == "__main__":
    main()
