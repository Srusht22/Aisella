# Pilot cost estimate

**Phase 3** · Status: **Estimate — not a quote.** Prices were collected on 2026-10-15. Items marked *(verify)* come from search summaries of vendor pages, not from a direct page read. Every number must be re-checked before money is committed.
Reproducible AI model: [tools/cost_model.py](tools/cost_model.py) (standard library; run it to regenerate the tables).

## 1. Published prices used
| Item | Price | Source |
|---|---|---|
| Supabase Pro | $25/month per organisation, including $10/month compute credits (covers one Micro instance); 100k MAU, 8 GB disk per project, 250 GB egress, 100 GB storage, 2M Edge Function invocations; 7-day daily backups; spend cap on by default *(verify)* | supabase.com/pricing, via search |
| Supabase PITR add-on | About $100/month for 7 days; requires at least Small compute; not covered by the spend cap *(verify)* | supabase.com docs, via search |
| Supabase overages (examples) | Egress $0.09/GB; storage about $0.021/GB; Edge Functions $2 per million *(verify)* | Third-party summary of the Supabase pricing page; lower confidence |
| Claude Opus 5.5 | $4 input / $20 output per million tokens; cache read $0.20 per million; 5-minute cache write 1.25× input | Anthropic Claude API reference (cached 2026-10-06) |
| Claude Sonnet 5.5 | $2 / $10; cache read $0.20 | Same |
| Claude Haiku 5.5 | $0.10 / $0.50 (prompts ≤ 100k tokens); cache read **assumed** 0.1× input | Same (cache-read price for Haiku 5.5 not stated) |
| Sentry | Developer plan free (1 user; about 5k errors); Team about $26/month (annual) or $29 (monthly) *(verify)* | sentry.io, via search |
| WhatsApp Business Platform | Per-message pricing by category and country; service messages charged from 2026-10-01, with 1,000 free per number per month; **Iraq rate not retrieved** | developers.facebook.com, via search |
| Telegram Bot API | No fee found *(verify)* | — |
| Instagram and Messenger messaging | No per-message fee found *(verify)* | — |
| Apple Developer Program / Google Play developer account | $99/year / $25 one-time *(widely published; verify at enrolment)* | — |

## 2. AI usage assumptions (to be replaced by measured `ai_runs` data in Phase 8)
| Assumption | Value | Why |
|---|---|---|
| Cached prefix per call | 9,000 tokens (3k instructions and schema + 6k store context ≈ 240 variants) | Catalog-in-context design ([AI §4](ai-integration-architecture.md#4-trusted-context-what-is-retrieved)) |
| Uncached input per call | 2,500 tokens (availability, conversation, draft state) | — |
| Output per call | 1,600 tokens (about 600 JSON + about 1,000 thinking at low effort). **Unmeasured**; sensitivity at 2×. | Thinking volume is the largest uncertainty |
| Calls per conversation | 2.5 | First message, follow-up, occasional regenerate |
| Cache hit rate | 50% base; 20–80% range | Bursty seller usage around the 5-minute TTL |

## 3. AI cost (output of `cost_model.py`)
**Per call:**

| Model | Per call (50% hit) | Range |
|---|---|---|
| Opus 5.5 | $0.065 | $0.052–0.097 |
| Sonnet 5.5 | $0.033 | — |
| Haiku 5.5 | $0.0017 | — |

**Per month:**

| Scenario | Calls/month | **Opus 5.5** (default) | Sonnet 5.5 | Haiku 5.5 |
|---|---|---|---|---|
| A: 3 sellers × 10 conversations/day | 2,250 | **$147** ($118–248) | $75 ($61–125) | $4 ($3–6) |
| B: 5 sellers × 25 conversations/day | 9,375 | **$613** ($492–1,035) | $311 ($253–519) | $16 ($13–26) |
| C: 30 sellers × 30 conversations/day | 67,500 | **$4,414** ($3,540–7,449) | $2,238 ($1,818–3,737) | $112 ($91–187) |

**Interpretation:**
- At the default model, **AI is the dominant running cost**: about $0.16 per customer conversation (2.5 calls × about $0.065).
- Whether a cheaper tier is acceptable is an **owner decision gated by the evaluation set** (AD-07). The architecture makes it a configuration change, not a redesign.
- No tier is recommended over the default without evidence that it meets the fabrication = 0 and accuracy gates in Sorani.

## 4. Monthly running cost scenarios (pilot)
| Line | Scenario A | Scenario B | Notes |
|---|---|---|---|
| Supabase Pro (production) | $25 | $25 | Usage well inside quotas: about 1–2 GB of images, under 1 GB database, under 20 GB egress (estimates) |
| Supabase staging project | ≈ $10 *(verify)* | ≈ $10 | A second project in the Pro organisation incurs its own compute. Alternative: a Free-organisation project ($0; pauses when inactive). |
| PITR (optional, **not recommended for the pilot**, AD-05) | ($100 + compute upgrade) | same | Recommended before commercialization |
| AI (Opus 5.5 default) | $147 (118–248) | $613 (492–1,035) | §3 |
| Sentry | $0 | $0 | Developer plan unless quota is exceeded |
| Transactional email (SMTP) | $0–20 *(estimate)* | $0–20 | Provider chosen in Phase 5; free tiers exist at pilot volume |
| Off-site encrypted dump storage | < $1 *(estimate)* | < $1 | A few GB |
| Messaging | $0 (Stage A) | $0 (Stage A) | P1 costs depend on the channel (§6) |
| **Total, recurring** | **≈ $180–300/month** | **≈ $650–1,090/month** | Dominated by the AI model tier |

## 5. One-time and annual costs (not monthly)
| Item | Cost |
|---|---|
| Apple Developer Program | $99/year *(verify)* |
| Google Play developer registration | $25 one-time *(verify)* |
| Domain (for email sender, bundle IDs, optional custom API domain) | Typically $10–20/year *(estimate)* |
| Supabase custom domain (only if ADR-009 contingency needed) | Paid add-on, price **not verified** |
| CI minutes | GitHub Actions free allowance may be exceeded by macOS (iOS) builds. Building iOS on the owner's Mac avoids that. *(verify the account's allowance)* |
| Design (logo and app icon, DD-02), legal review (§7.3 of the data model), native Sorani review (DD-04) | **Not estimated.** Owner sourcing. |
| Development time | Not estimated in money (team capacity unknown) |

## 6. Messaging costs after the pilot (P1)
- **Telegram:** no platform fee found.
- **Instagram and Messenger:** no per-message fee found *(verify)*. The cost is app review effort.
- **WhatsApp:** per delivered message by category for Iraq. With 1,000 free service messages per number per month, a pilot seller sending about 25 conversations × 3 replies per day (about 2,250 per month) would exceed the free tier. **The cost cannot be estimated until the Iraq rate card is obtained.**

## 7. What would improve this estimate
1. Real `ai_runs` token counts from the Phase 8 evaluation (thinking tokens at low versus medium effort).
2. Real pilot volumes (conversations per seller per day) from M0 interviews.
3. A direct read of the Supabase pricing page and of staging-project billing in a Pro organisation.
4. WhatsApp's rate card for Iraq.
5. The quote from the chosen SMTP provider.

## 8. Cost controls
**Implement early (cheap and protective):**
- per-store AI rate limits and daily caps;
- idempotent AI requests (no duplicate runs);
- one structured call per update (not several);
- prompt caching with stable prefixes;
- `ai_usage_daily` alerts;
- provider-console spend limits *(verify)*;
- the Supabase spend cap left on;
- client-side image compression.

**Premature now:** multi-model cascades, batch processing (replies are interactive), custom caching layers, reserved capacity, moving off managed services.
