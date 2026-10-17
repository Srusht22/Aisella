# C. Provider data terms, model choice and spending

**Sources:** Anthropic's public documentation, read on **2026-10-17**: the pricing page, the data residency page and the data retention / zero-data-retention page.
- The privacy center article on commercial retention could not be fetched from this environment (DNS failure), so it was not reviewed.
- Terms change. The owner should re-read the current pages, and the commercial agreement itself, before deciding.
- **This is not legal advice.** Kurdistan Region and Iraqi data-protection obligations were not assessed.

**No provider setting was changed and no money was spent.**

## 1. What the provider retains and where it processes

| Topic | What the documentation says | Implication for Aisellia |
|---|---|---|
| Retention of API content | Conversation content is not retained by default, except for "Covered Models" (Fable 5 / 5.1, Mythos 5 / 5.1), which require 30-day retention and cannot use zero data retention | Opus 5.5, Sonnet 5.5 and Haiku 5.5 are **not** Covered Models. **Do not switch Aisellia to a Covered Model** without a new privacy decision. |
| Zero data retention (ZDR) | Arranged per organization through Anthropic sales | Optional extra assurance. It needs an agreement, not a setting. |
| Trust and safety | Even under ZDR, content flagged by trust and safety may be kept up to 2 years | Customer messages that trip a safety classifier could be retained. Phone numbers and e-mails are already replaced by tokens; names and addresses are not. |
| Structured outputs | Eligible for ZDR. Only the JSON schema is cached, for up to 24 hours. | The schema holds no customer data. |
| Prompt caching | Caches are held in memory for their lifetime (5 minutes by default) | The cached prefix is the rules and the store's catalog context, not the customer's messages. |
| Training | Retained data is not used for training without permission | — |
| Inference region | Request parameter `inference_geo`: `"global"` (default) or `"us"`. Workspaces can restrict allowed regions and set a default. The response reports where inference ran. | `AI_INFERENCE_GEO` now sets it, and the served region is recorded per run. |
| Price of US-only | 1.1× on all token types | The database now multiplies the cost estimate by 1.1 when a run reports `us` |
| Data at rest | Workspace geography is US only, chosen when the workspace is created | — |
| Availability | `inference_geo` works on the first-party API and Claude Platform on AWS, not on Bedrock or Vertex | Aisellia uses the first-party API |

**What Aisellia sends** (Phase 8 E §1, unchanged):
- one store's catalog context;
- up to 20 recent messages of one conversation, with phones and e-mails tokenised.

Names and free-text addresses are sent because extraction needs them.

## 2. Proposed AD-08 (data terms and geography): owner decision

| Option | Effect | Proposal |
|---|---|---|
| Standard terms, `global` inference | No retention of content by default for the proposed models; lowest cost | **Recommended for staging and the pilot**, provided the owner accepts the trust-and-safety exception |
| Request ZDR | Contractual zero retention, except trust and safety | Recommended **before scaling past the pilot**, or if a seller or regulator requires it |
| US-only inference | Processing stays in the US; +10% cost | Only if a contract or regulation requires a known region. It does not mean "local": no Middle East region exists. |

**Also decide:**
- **The Supabase project region.** It holds all customer data at rest, which matters more than where inference runs. A region close to the users, for example Frankfurt, is a reasonable default.
- **Seller-facing disclosure.** Tell sellers that customer messages they paste are processed by an AI provider, and include it in their privacy notice.

## 3. Proposed AD-07 (model, effort and caps): owner decision

**Model:** keep **`claude-opus-5-5` at effort `low`** for staging and the evaluation.
- The **Sorani quality risk** outweighs the cost difference at pilot volume.
- Run the same 24-scenario set with `AI_MODEL=claude-sonnet-5-5`. Switch to Sonnet 5.5 only if it matches Opus on the deterministic checks **and** a native reviewer rates its Sorani and Arabic replies as equally good.
- Haiku 5.5 only for experiments.

**Estimated cost per suggestion** (assumptions, **not measured**):
- input 4,000–8,000 tokens: rules, schema and store context, of which roughly 70% is cacheable;
- output 300–800 tokens.

| Model | Without cache hits | With typical cache hits |
|---|---|---|
| Opus 5.5 | USD 0.02 – 0.05 | USD 0.011 – 0.03 |
| Sonnet 5.5 | USD 0.01 – 0.025 | USD 0.006 – 0.015 |
| Haiku 5.5 | under USD 0.002 | under USD 0.001 |

Sorani and Arabic text usually takes more tokens per character than English. The evaluation reports real token counts per language and replaces these estimates.

**Request and token caps:**

| Cap | Value | Where | Status |
|---|---|---|---|
| `max_tokens` per call | 8,000 | `AI_MAX_TOKENS` | Unchanged. A normal reply uses under 1,000. Lower it to 4,000 after the evaluation shows the real maximum. |
| Calls per request | At most 2 (one retry on invalid output) | Code | Unchanged |
| Requests per store | 30 per 10 minutes, 300 per day | `app.ai_limits` | Unchanged |
| **Estimated spend per store per 24 h** | **USD 2** (about 70–180 Opus suggestions) | `app.ai_limits.assist_daily_cost_micro_usd_per_store` | **New** |
| **Estimated spend, all stores, per 24 h** | **USD 20** | `app.ai_limits.assist_daily_cost_micro_usd_total` | **New** |
| Evaluation run | USD 5 by default | `--max-cost-usd` | **New** |

Both brakes refuse new requests with `RATE_LIMITED`; the app already shows "try again later" and the manual path. They are based on the database's **estimate** (`app.ai_model_prices`, now including Sonnet 5.5 and Haiku 5.5), so they are a brake, not a billing guarantee. Operators change them in `app.ai_limits`; sellers cannot.

## 4. Spending limits

| Where | Proposal | Who sets it |
|---|---|---|
| Claude Console, staging workspace | **USD 50 per month** limit, with notifications at 50% and 80% | Owner. **Not set in this phase:** no access, and it is a paid-account setting |
| Claude Console, production workspace (later) | Pilot sellers × USD 2 × 30 days, plus 20% margin. For 10 sellers, about USD 720 per month at the cap; expected use is far lower. | Owner, at Phase 9 or the pilot |
| Database brakes | USD 2 per store and USD 20 total per 24 h (above) | Already in the migration; adjustable |
| One evaluation run | USD 5 cap; the 24-scenario set is expected to cost about USD 0.5–1 | Script flag |

The **provider's limit is the real guarantee**: it cannot be bypassed by a bug in Aisellia's estimate. The database brakes stop a runaway loop or an abusive store much earlier.
