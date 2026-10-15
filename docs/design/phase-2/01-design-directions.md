# 01 — Design direction exploration

**Phase 2, Deliverable 1** · Status: **Proposed — pending owner approval**
Related: [Index](README.md) · [02 Visual identity and tokens](02-visual-identity-and-tokens.md) · [Concept board (HTML)](artifacts/concept-board.html) · [Concept board (PNG)](artifacts/concept-board.png)

> The concept board is a static HTML/CSS design reference rendered in headless Chromium. It is **not** the Flutter app and does not show working software. All names, prices, phones and stock values on it are **sample data**. Sorani strings on it are machine-drafted and **must be reviewed by a native speaker**.

Every concept is shown on the same screen, an **AI order draft under review**. That is the hardest and most business-critical screen in the product (Phase 1 §7 Journey E), so it is the fairest test of a visual direction.

---

## Concept A — "Ledger" (pencil and ink)

**Philosophy.** Aisellia is a precise working tool, like a well-kept merchant's ledger. Sophistication comes from typography, alignment and restraint, not decoration. One idea carries the brand: **the AI writes in pencil; the seller signs in ink.**

- Anything the AI proposes (draft orders, suggested replies, inferred fields) is drawn in the *pencil* treatment: a graphite tone, dashed or dotted strokes, and a warm-grey sheet.
- Anything committed (approved orders, saved catalog data, sent messages) is drawn in *ink*: solid strokes and full contrast.
- Approval is the moment pencil becomes ink.

This metaphor directly enforces the Phase 1 rule that a draft must never look like a confirmed order (BR-01–05). It also gives Aisellia a recognisable signature that does not depend on colour.

| Aspect | Definition |
|---|---|
| Emotional impression | Calm, competent, trustworthy, "my business is in order" |
| Brand personality | A meticulous, quiet assistant; precise rather than playful; respectful of the seller's authority |
| Colour | Warm paper neutrals (`#F6F4EF`), ink near-black (`#1A1C20`), one brand colour: **Signature Blue** (`#1F3F8F`, the colour of a signing pen). Semantic green, amber and red appear only for status. |
| Typography | Inter (Latin and Western digits, tabular numerals) paired with Vazirmatn Non-Latin (Arabic script). Hierarchy comes from weight and size steps, not colour. |
| Hierarchy | Section labels, then hairline-separated rows, then right-aligned tabular numbers. Totals are the strongest numeric element. |
| Surfaces | Paper background with white "sheets"; 1 px hairline rules; no gradients; shadows only for floating layers |
| Containers | Grouped row lists (one container per section), not one card per fact |
| Buttons and inputs | 10 px radius; filled Signature Blue for the single primary action; outlined secondary; destructive actions in red text or outline, never a filled red default |
| Iconography | 1.5–1.75 px stroke outline icons; filled versions for active navigation only |
| Navigation | Bottom bar on phones (4 destinations), navigation rail on tablets; plain labels |
| Imagery | The seller's product photos are the only imagery; neutral placeholders; no stock illustrations |
| Motion personality | Short, precise, settling. One signature moment: the **ink settle** on approval (dashed border resolves to solid) |
| Daily-use fit | Excellent: dense, legible, quiet; works in sunlight (light default) and at night (dark theme) |

- **Strengths:** highest information density without clutter; the AI-versus-verified distinction is built into the visual language and not only into colour; easy to keep consistent; cheap to implement and to render on low-end Android; mirrors cleanly in RTL.
- **Weaknesses:** can feel austere if executed carelessly; less immediately "wow" in screenshots than B or C; relies on typographic craft, so font rendering and spacing must be exact.
- **Accessibility risks:** dashed or dotted strokes alone are too subtle. They must always be paired with a text label ("Draft — not confirmed", "From customer"). Tertiary text on paper is near the 4.5:1 limit (measured at 4.53:1), so it must not be used for essential information.
- **Implementation complexity:** **Low–medium.** Standard Flutter widgets plus a small custom painter for dashed borders. No blur, no gradients, no illustration pipeline.

## Concept B — "Bazaar" (warm, expressive)

**Philosophy.** Celebrate the merchant culture of the region. Warm terracotta and saffron, kilim-inspired geometric bands, large photo-first rounded cards, enthusiastic copy ("Nzar wants 2 Beige Abayas!").

| Aspect | Definition |
|---|---|
| Emotional impression | Friendly, energetic, local, celebratory |
| Personality | An excited shop helper |
| Colour | Terracotta `#B5492A`, saffron `#E8B03A`, cream `#FBF3E6`, deep brown text |
| Typography | Heavy display weights for headlines; rounded body |
| Surfaces | Coloured hero headers, patterned dividers, 24 px radius cards with warm shadows |
| Buttons | Pill-shaped, shadowed, full-width |
| Imagery | Large product photos; illustrated empty states and decorative patterns |
| Motion | Bouncy, springy entrances; celebratory confetti-like success |

- **Strengths:** distinctive and emotionally warm; strong local character; attractive in marketing screenshots.
- **Weaknesses:**
  - It is decorative at the expense of density: the board fits about 40% of the information A shows.
  - Celebratory tone is wrong for a business-critical approval ("Approve · 75,000 IQD" invites tapping before checking).
  - A draft looks like good news rather than something to verify.
  - Cultural motifs risk cliché and need a specialist illustrator.
  - Terracotta conflicts with semantic red for errors.
- **Accessibility risks:** saffron on cream measured **2.22:1**, which fails for any text. Terracotta buttons with white text pass (5.31:1) but leave little room for pressed and disabled states. Patterns add visual noise for low-vision users.
- **Implementation complexity:** **Medium–high.** Pattern assets in both directions, illustration library, heavier motion.

## Concept C — "Console" (dark, AI-forward)

**Philosophy.** Present Aisellia as a futuristic AI command centre: dark navy, violet-to-cyan gradients, glass panels, glowing borders, confidence meters.

| Aspect | Definition |
|---|---|
| Emotional impression | High-tech, powerful, "AI inside" |
| Personality | A sci-fi copilot |
| Colour | Night `#0E1220`, violet `#8B7CFF`, cyan `#3FE0D0`, gradients |
| Surfaces | Translucent glass cards with background blur and glow |
| Typography | Large numeric displays, uppercase micro-labels |
| Motion | Shimmering, glowing, perpetual ambient animation |

- **Strengths:** instantly communicates "AI"; striking in screenshots.
- **Weaknesses:**
  - It is the **generic AI-app look** the brief explicitly asks to avoid.
  - A single "82% confident" score invites over-trust and hides *which* field is uncertain, which contradicts Phase 1 §8.5–8.6.
  - "Approve with AI" misrepresents who approves (BR-03).
  - Dark-only is poor in daylight, where sellers often work.
  - Blur and glow are expensive on low-end Android.
- **Accessibility risks:** dim labels measured **4.07:1** on night and **3.52:1** on glass, both failing for body text. Glow and gradients reduce edge clarity, and constant motion is hostile to motion-sensitive users.
- **Implementation complexity:** **High.** `BackdropFilter` cost, gradient tuning in two themes, custom glow effects.

---

## Evaluation

Scores run from 1 (poor) to 5 (excellent). Weights reflect a daily business tool whose critical risk is wrong orders.

| # | Criterion | Weight | A Ledger | B Bazaar | C Console |
|---|---|---|---|---|---|
| 1 | Distinctiveness and brand quality | 2 | 4 (pencil/ink signature) | 5 | 2 (generic AI look) |
| 2 | Daily usability | 3 | 5 | 3 | 3 |
| 3 | Information density and readability | 3 | 5 | 2 | 3 |
| 4 | Accessibility and contrast (measured) | 3 | 5 | 2 | 2 |
| 5 | Phones and tablets | 2 | 5 | 3 | 4 |
| 6 | Kurdish Sorani RTL compatibility | 3 | 5 (mirrors cleanly; verified on board) | 3 (directional patterns need redrawing) | 4 |
| 7 | Order and inventory workflows (draft vs. confirmed clarity) | 3 | 5 | 2 | 2 |
| 8 | Implementation and maintenance cost | 2 | 5 | 3 | 2 |
| 9 | Long-term consistency | 2 | 5 | 3 | 3 |
| | **Weighted total (max 115)** | | **113** | **64** | **64** |

## Recommendation

**Adopt Concept A, "Ledger: pencil and ink"** (status: *proposed, pending owner approval*). It is the only direction where the visual system itself protects the core business rule: the seller can see at a glance what the AI proposed and what is committed. It has the highest measured contrast margin, the highest density and the lowest implementation risk. Its distinctiveness comes from a meaningful idea rather than decoration.

**Borrowed deliberately from the other concepts:**
- **From B:** warmth through the paper palette and respectful, human copy. Product photos are prominent where they help recognition (product list, item rows). No patterns, no celebratory tone on critical actions.
- **From C:** nothing visual. Only the lesson that AI involvement must be *visible*. Ledger achieves this with labelled pencil treatment instead of gradients and glow.

**Things the board review changed in the spec:**
1. The board originally showed an *optional* missing field (landmark) in error red. That is alarming and contradicts the rule that red means blocking. Optional missing fields are now neutral (`text.tertiary`, "— Not provided (optional)").
2. Fixed-width label columns wrapped "Total · COD" in the dark theme. Totals rows now use flexible label width (specified in [05 Components](05-components.md), `PriceRow`).
3. The quote-mark glyph used as a provenance icon read poorly. It is replaced with a dedicated "message" icon (see [02 §5 Iconography](02-visual-identity-and-tokens.md#5-iconography)).

**Not decided here:** the final logo or wordmark. A wordmark direction is proposed in [02 §1](02-visual-identity-and-tokens.md#1-brand-expression). A finished logo should be commissioned or approved separately (decision DD-02 in [10](10-phase-2-report.md)).
