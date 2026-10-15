# 02 — Visual identity and design tokens

**Phase 2, Deliverable 2** · Status: **Proposed — pending owner approval** · Direction: *Ledger: pencil and ink* ([01](01-design-directions.md))

**Machine-readable source:** [tokens/aisellia-tokens.json](tokens/aisellia-tokens.json). If this document and the JSON disagree, the JSON wins and this document must be corrected.
**Validation:** [tools/contrast_check.py](tools/contrast_check.py) checks 32 declared colour pairs in both themes (64 checks). The latest run is recorded in §2.6.

---

## 1. Brand expression

| Element | Specification |
|---|---|
| **Core idea** | *The AI writes in pencil; you sign in ink.* AI proposals look provisional; committed business data looks permanent. Approval turns pencil into ink. |
| **Personality** | Precise, calm, respectful, quietly confident. Never hype, never cute, never alarmist. |
| **Wordmark (direction)** | Latin: `aisellia` in lowercase Inter SemiBold, tracking −1%, with the dot of the second *i* set in Signature Blue as an "ink dot". Sorani: `ئایسێلیا` in Vazirmatn SemiBold. **The final logo, app icon and Sorani wordmark spelling require a designer and owner approval (DD-02).** |
| **App icon (direction)** | A Signature Blue square with a single white mark: a lowercase "a" whose final stroke ends like a pen nib. No gradient, no sparkle. |
| **Voice** | Short, plain sentences in the seller's language. Use verbs that state facts ("Approved", "Couldn't save"). Never say the AI did something it did not do (BR-49). Avoid exclamation marks and celebratory copy on business actions. |
| **What Aisellia never looks like** | Gradients on UI surfaces, glass or blur, glowing borders, sparkle icons for the AI, confetti, stock illustrations, emoji in the UI, a different card style per screen. |

### 1.1 The pencil-and-ink system (core rule set)

| Treatment | Meaning | Visual | Where used |
|---|---|---|---|
| **Pencil** | Proposed by the AI and not yet committed | `bg.pencil` sheet; 1.5 px **dashed** `border.pencil` (4 on, 3 off); pencil icon; text label naming the state | Draft order banner; AI-suggested reply; "Suggested" chips |
| **Pencil underline** | A single value that the AI filled in | 1.5 px **dotted** underline in `border.pencil` under the value, plus a provenance caption ("From customer") | AI-filled fields on drafts |
| **Ink** | Committed: saved by the seller, from the catalog or settings, approved, or sent | Solid surfaces, solid borders, full-contrast text, no pencil icon | Everything else |
| **Attention (warning)** | Needs the seller's check; may block | `warning.*` colours, triangle icon, text label | Inferred values, price changed, low stock |
| **Attention (danger)** | Blocks the action or reports a failure | `danger.*` colours, circle-x or alert icon, text label | Missing required field, conflict, out of stock, failed operation |

**Rules**
1. The pencil treatment is **always** accompanied by a text label. Dashes or dots alone never carry meaning (accessibility; [07](07-localization-and-accessibility.md)).
2. Committed data never uses the pencil treatment. AI proposals never use ink styling.
3. Signature Blue *fills* are reserved for the single primary action on a screen and for selected or active indicators. A draft is never shown with a blue-filled status.
4. When an approval succeeds, the draft's pencil treatment animates into ink (the "ink settle", [06 §4](06-motion.md#4-business-status-changes)). It happens **only after** the server confirms.

---

## 2. Colour system

### 2.1 Light theme (default)

| Token | Hex | Use | Do not use for |
|---|---|---|---|
| `bg.canvas` | `#F6F4EF` | App background ("paper") | Inputs, sheets |
| `bg.surface` | `#FFFFFF` | Row groups, inputs, app bars, sticky bars | Full-screen backgrounds |
| `bg.raised` | `#FFFFFF` | Sheets, dialogs, menus (with level 2–3 shadow) | — |
| `bg.sunken` | `#EFECE5` | Search field fill, image placeholders, skeletons | Text containers needing high contrast |
| `bg.pencil` | `#F1EEE6` | AI proposal sheets | Any committed data |
| `bg.brandWeak` | `#E8EDF8` | Selected chip or segment, selected list row, info banner | Large areas |
| `text.primary` | `#1A1C20` | Primary text, values, totals | — |
| `text.secondary` | `#555A63` | Labels, supporting text | Values the seller acts on |
| `text.tertiary` | `#6B7079` | Metadata: timestamps, provenance captions | Essential information (only 4.53:1 on canvas) |
| `text.disabled` | `#9EA2A9` | Disabled labels | Anything the user needs to read |
| `text.brand` | `#1F3F8F` | Links, tertiary buttons, selected labels | Body text |
| `text.pencil` | `#4A4F59` | Text inside AI proposal sheets | — |
| `border.hairline` | `#E4E0D7` | Dividers, row-group outlines (decorative) | Input outlines, sole boundary of a control |
| `border.control` | `#80848C` | Input and checkbox outlines (≥ 3:1) | Dividers |
| `border.pencil` | `#7A7F88` | Dashed proposal outline, dotted AI underline | Committed data |
| `border.focus` | `#1F3F8F` | 2 px focus ring | — |
| `brand.primary` | `#1F3F8F` | **Signature Blue**: primary button fill, active navigation, selection | Status of uncommitted items; large backgrounds |
| `brand.primaryPressed` | `#18326F` | Pressed primary | — |
| `success.fg / .bg` | `#17663F` / `#E6F2EA` | Delivered, in stock, collected, success snackbar | Brand emphasis |
| `warning.fg / .bg` | `#8A4B00` / `#FCEFD6` | Inferred, low stock, price changed, delivery failed | Errors |
| `danger.fg / .fgOnBg / .bg / .onFill` | `#B42318` / `#A21D14` / `#FBE9E7` / `#FFFFFF` | Blocking issues, errors, destructive actions; `.onFill` is the label on a filled danger button | Optional missing fields, decoration |
| `info.fg / .bg` | `#1F3F8F` / `#E8EDF8` | Neutral informational banners | — |
| `neutral.badgeFg / .badgeBg` | `#3F434A` / `#ECE9E2` | Neutral statuses (Draft, Preparing, Cancelled) | — |
| `scrim` | `#101216` at 48% | Behind sheets and dialogs | — |

### 2.2 Dark theme

Dark is a full theme, not an inversion. It is selectable (System, Light, Dark) and defaults to **System**. Surfaces step up in lightness instead of using shadows. Signature Blue lightens to `#9DB4F2` and its label colour becomes `#0F1B3D`.

| Token | Hex | Token | Hex |
|---|---|---|---|
| `bg.canvas` | `#121417` | `text.primary` | `#ECEDEF` |
| `bg.surface` | `#1B1E23` | `text.secondary` | `#A9AEB8` |
| `bg.raised` | `#22262C` | `text.tertiary` | `#8C929D` |
| `bg.sunken` | `#0E1013` | `text.disabled` | `#5D626B` |
| `bg.pencil` | `#1F2228` | `text.pencil` | `#B9BDC6` |
| `bg.brandWeak` | `#1D2740` | `text.brand` / `brand.primary` | `#9DB4F2` |
| `border.hairline` | `#2A2E35` | `text.onBrand` | `#0F1B3D` |
| `border.control` | `#707682` | `border.pencil` | `#7A808B` |
| `success.fg/.bg` | `#6CCB97` / `#15291F` | `warning.fg/.bg` | `#F0B35B` / `#2E2414` |
| `danger.fg/.bg/.onFill` | `#F28B80` / `#33191A` / `#3A0D09` | `scrim` | `#000000` at 60% |

### 2.3 Order status colour mapping

Status is never communicated by colour alone: every badge has text and an icon (BR-46; [07](07-localization-and-accessibility.md)).

| Order status (Phase 1 §6.4) | Badge style | Icon (Phosphor name) |
|---|---|---|
| `draft` | Pencil (dashed outline, `bg.pencil`, `text.pencil`) | `PencilSimple` |
| `pending_approval` | Pencil with warning text "Needs approval" | `PencilSimple` + label |
| `approved` | `info` (brand weak) | `SealCheck` |
| `processing` | neutral | `Package` |
| `dispatched` | neutral, brand text | `Truck` |
| `delivered` | success | `CheckCircle` |
| `delivery_failed` | warning | `WarningCircle` |
| `returned` | neutral | `ArrowUUpLeft` (mirrored in RTL) |
| `cancelled` | neutral, strikethrough-free | `XCircle` |
| `rejected` | neutral | `Prohibit` |
| Test order (flag) | Additional outlined neutral badge "Test" | `Flask` |

### 2.4 Inventory indicators

| State | Text | Colour | Icon |
|---|---|---|---|
| In stock (> threshold) | "12 in stock" | `text.secondary` (calm; not green, to avoid noise) | none |
| Low (≤ threshold, > 0) | "Low · 2 left" | warning | `TrendDown` |
| Out (0) | "Out of stock" | danger | `Prohibit` |
| Untracked, available | "Available" | `text.secondary` | none |
| Untracked, unavailable | "Unavailable" | danger | `Prohibit` |

Stock *within an order line* uses success colour when it is sufficient ("4 in stock"), because there it answers the yes-or-no question "can I approve?"

### 2.5 Forbidden combinations
- `text.disabled` for anything informative; `border.hairline` as an input outline.
- Saffron, terracotta or other brand-adjacent warm hues: not in the palette. Do not add them ad hoc.
- Warning text on danger backgrounds, or the reverse.
- Brand-blue fill behind uncommitted (draft) content.
- Pure black `#000` or pure white text in dark mode (use `#ECEDEF`).
- Gradients on any UI surface. A gradient is allowed only inside product photography.

### 2.6 Contrast validation (actually run)
`python3 docs/design/phase-2/tools/contrast_check.py` gave **64 checks, 0 failures** (32 pairs × 2 themes) after two corrections. The first run failed `border.control` on canvas (2.84:1) and `border.pencil` on pencil (2.80:1); both were darkened. Key results:

| Pair | Light | Dark |
|---|---|---|
| Primary text on canvas | 15.52 | 15.75 |
| Tertiary text on canvas | 4.53 (metadata only) | 5.90 |
| Primary button label | 9.70 | 8.23 |
| Danger text on surface | 6.57 | 6.99 |
| Warning on warning bg | 5.98 | 8.20 |
| Input outline on canvas | 3.41 | 4.04 |
| Pencil outline on pencil sheet | 3.47 | 4.01 |

---

## 3. Typography

### 3.1 Font choice (evidence-based)

Candidate fonts were downloaded from npm and inspected with fontTools and HarfBuzz in this environment. The test set was the Sorani-specific letters ڕ ڵ ۆ ێ ە ڤ پ چ ژ گ ک ی ھ ئ, the Arabic-Indic digits, the presence of positional shaping features, and shaping of 8 Sorani test words without `.notdef` glyphs:

| Font | Sorani letters | Arabic-Indic digits | Tabular figures | Shaping test | Licence |
|---|---|---|---|---|---|
| **Vazirmatn 33.0.3** | all | yes | yes | 8/8 | OFL 1.1 |
| Noto Sans Arabic 5.3.0 | all | yes | yes | 8/8 | OFL 1.1 |
| Noto Kufi / Noto Naskh Arabic | all | yes | yes | 8/8 | OFL 1.1 |
| IBM Plex Sans Arabic | all | yes | **no** | 8/8 | OFL 1.1 |
| Readex Pro (fontsource build) | **missing 12** | yes | no | — | OFL 1.1 |
| Rubik | **missing 6** | yes | yes | — | OFL 1.1 |
| Inter 5.3.0 (Latin) | n/a | n/a | yes | n/a | OFL 1.1 |

**Recommendation:** **Inter** for Latin text and Western digits, plus **Vazirmatn NL** (the official *Non-Latin* build with no Latin glyphs) for Arabic script.
- Because Vazirmatn NL has no Latin glyphs, every Latin run (product names, SKUs, prices, phone numbers) renders in Inter in *both* locales, so mixed content looks consistent.
- Vazirmatn is a contemporary, open-counter sans whose proportions pair well with Inter: x-height 1082 vs 1118 units per 2048 em, measured.
- **Fallback alternative:** Noto Sans Arabic (equivalent coverage, more conservative style).
- **Licensing:** both fonts are SIL OFL 1.1, which permits bundling in a commercial app. OFL text must ship with the app (licences screen) and fonts must not be sold separately.
- **Delivery:** fonts are **bundled as app assets**, not fetched at runtime (Phase 1 L-06). Variable-font files (`Vazirmatn-NL[wght]`, Inter) are preferred if Phase 4 confirms Flutter renders variable weights correctly on both platforms; otherwise static 400/500/600 weights are used.
- **Native-speaker review of the Sorani rendering is still required** (DD-04).

### 3.2 Type scale

Script-specific values: Sorani styles are one step larger and have more line height, because Arabic-script letterforms read smaller and need room for dots and diacritics. **Letter-spacing in Arabic script is always 0**, because tracking breaks cursive joining. Overlines are not uppercased (Arabic script has no case).

| Style | English size/line/weight | Sorani size/line/weight | Use |
|---|---|---|---|
| `title.large` | 24/32/600 | 24/38/600 | Top-level screen titles (collapses to `title` on scroll) |
| `title` | 18/26/600 | 19/30/600 | App bar, sheet and dialog titles |
| `heading` | 16/24/600 | 17/28/600 | Section headings inside content, list group titles |
| `overline` | 12/16/600, +6% tracking, uppercase | 13/20/600, no tracking | Section labels above row groups |
| `body.large` | 16/24/400 | 17/28/400 | Message bubbles, long reading text |
| `body` | 15/22/400 | 16/26/400 | Default text, values in rows |
| `body.strong` | 15/22/600 | 16/26/600 | Product names in lists, emphasised values |
| `label` | 13/18/500 | 14/22/500 | Field labels, chips, badges, tab labels |
| `caption` | 12/16/400 | 13/20/400 | Provenance, timestamps, helper text (minimum size) |
| `button` | 15/20/600 | 16/24/600 | Buttons |
| `numeric.body` | 15/22/500, tabular | 15/26/500, tabular | Prices, quantities, stock in rows |
| `numeric.total` | 20/28/600, tabular | 20/30/600, tabular | Order totals |
| `numeric.metric` | 28/34/600, tabular | 28/36/600, tabular | Single key number on a focused surface: the stock-adjustment result preview (PR-05). Not used for dashboards or metric cards. |

**Rules**
- Numbers that are compared or aligned (prices, totals, quantities, stock, counts) always use **tabular figures** and are end-aligned in their column.
- Prices are always shown with a thousands separator and currency: `35,000 IQD` or `$25` (localized unit in Sorani: see [07 §3](07-localization-and-accessibility.md#3-numbers-currency-dates)).
- No font sizes outside this scale. No weights other than 400, 500 and 600 (700 only in the wordmark).
- Hierarchy is created with size and weight first, then colour. Never colour alone.

### 3.3 Truncation rules

| Content | Rule |
|---|---|
| Product name in lists | Up to 2 lines, then ellipsis; full name on detail and in the order review |
| Variant label | 1 line, ellipsis at end; full text in pickers |
| Customer name | 1 line in lists; wraps in detail |
| Address | 2 lines in lists; full in detail and review |
| Message preview (inbox) | 2 lines |
| Prices, totals, quantities, order numbers, phone numbers | **Never truncated.** The adjacent label wraps instead. On very narrow screens the row stacks vertically. |
| Button labels | Never truncated. Long localized labels wrap to two lines or the button group stacks vertically. |
| Screen titles | 1 line with ellipsis (full title read by screen readers) |

---

## 4. Spacing, layout and responsiveness

### 4.1 Spacing scale (4-point base)
`space.0 = 0`, `2`, `4`, `8`, `12`, `16`, `20`, `24`, `32`, `40`, `48`, `64` (token names equal the value). No arbitrary values.

| Context | Value |
|---|---|
| Horizontal screen gutter | 16 (compact), 12 (compact-small), 24 (medium+), 32 (large) |
| Between sections | 24 |
| Section label to its row group | 8 |
| Row internal padding | 12 vertical, 12–16 horizontal; minimum row height 48 |
| Icon to text | 8 (12 for 24 px icons) |
| Between buttons in a group | 8 (12 for full-width stacked buttons) |
| Sheet internal padding | 16 sides, 24 top (below the handle), 16 bottom + safe area |

### 4.2 Window classes and adaptive layouts

| Class | Width (dp) | Navigation | Layout |
|---|---|---|---|
| Compact-small | < 360, or height < 640 | Bottom bar, labels shown | Gutter 12; large titles always collapsed; sticky action bars stay; two-column rows (label | value) switch to stacked |
| Compact (phones) | < 600 | Bottom bar (4 destinations) | Single pane |
| Medium (tablet portrait, foldables, large phones in landscape) | 600–839 | Navigation rail with labels | Single pane, content max 680 centred; forms in two columns where groups are independent (for example product images next to fields) |
| Expanded (tablet landscape) | 840–1199 | Navigation rail | **List–detail**: list pane 380, detail fills the rest (max 840). Applies to Inbox, Orders, Products, Customers. |
| Large | ≥ 1200 | Navigation rail | List–detail. **Draft review gains a third column** showing the source conversation next to the draft, so the seller can verify without switching. |

- **Safe areas:** content respects all insets; sticky action bars add the bottom inset below their buttons; landscape phones respect display cut-outs on both sides.
- **Do not stretch phone layouts:** at medium and above, text columns never exceed `maxWidth.reading` (680) and forms never exceed 560.
- **Dense information:** prefer grouped rows with label and value over cards. Use one row group per section. Long lists use virtualised lists with fixed-height rows where possible.

---

## 5. Shapes, borders and elevation

| Token | Value | Use |
|---|---|---|
| `radius.sm` | 6 | Badges, chips, thumbnails, quantity stepper buttons |
| `radius.md` | 10 | Buttons, inputs, row groups, banners, snackbars, menus |
| `radius.lg` | 16 | Bottom sheet top corners, dialogs |
| `radius.full` | — | Avatars, switches, the bottom-bar selection indicator |

Only these four radii exist. Nested containers use a *smaller* radius than their parent.

| Elevation | Light | Dark | Use |
|---|---|---|---|
| Level 0 | No shadow; hairline border on row groups | Same | Content |
| Level 1 | No shadow; hairline edge appears when content scrolls under | Same | App bar, sticky action bar, bottom bar |
| Level 2 | `0 1 2 rgba(16,18,22,.08)`, `0 4 12 rgba(16,18,22,.12)` | `bg.raised` plus hairline | Menus, snackbars, tooltips |
| Level 3 | `0 12 32 rgba(16,18,22,.18)` plus scrim | `bg.raised` plus hairline plus scrim | Bottom sheets, dialogs |

---

## 6. Iconography

- **Style:** Phosphor icon family (MIT; `@phosphor-icons/core` 2.1.1 verified on npm). Its *Regular* weight (about 1.5 px stroke at 24 px) is used by default and its *Fill* weight only for **active navigation** and selected toggles. Phosphor is chosen because every icon has matching Regular and Fill weights, which is what the active/inactive navigation rule needs. Lucide, for example, has no filled set.
- **Delivery:** the Flutter wrapper `phosphor_flutter` 2.1.0 was last published 2024-05-10, and pub.dev reports 55/160 points. Phase 4 should either vendor a curated subset of the MIT SVGs as an icon font or assets, or use the package after evaluation (**DD-05**).
- **Sizes:** 16 (inline with captions), 20 (rows, buttons, fields), 24 (app bar, navigation, empty-state glyph inside a 64 circle).
- **Colour:** icons inherit the text colour of their context. Semantic icons use semantic foreground colours. Icons are never the only carrier of meaning: always pair them with a label or provide a semantic label.
- **Icon-only buttons:** allowed only for universally understood actions (back, close, search, more, copy). Each has a 48 × 48 hit area and a localized tooltip and semantics label.
- **RTL mirroring:** mirror *directional* icons (back, forward, chevrons, arrows, send, reply, undo, redo, return arrow, list-indent and text-alignment icons). **Never mirror** check, close, search, camera, phone, clock, warning, info, plus or minus, play or pause, brand marks, or icons depicting real objects (truck, package, store, image), and never mirror numbers. Full list in [07 §2](07-localization-and-accessibility.md#2-rtl-layout-rules).
- **No emoji** anywhere in the UI chrome.

**Core icon set (P0):**

| Area | Icons |
|---|---|
| Navigation | `House`, `ChatsCircle`, `Receipt`, `Package` |
| Actions | `Plus`, `MagnifyingGlass`, `FunnelSimple`, `DotsThree`, `X`, `CaretLeft`/`CaretRight`, `ArrowLeft`, `Copy`, `PencilSimple`, `Trash`, `Archive`, `Camera`, `Image`, `ArrowClockwise` (retry), `Check` |
| Status | `SealCheck`, `CheckCircle`, `WarningCircle`, `Warning`, `XCircle`, `Prohibit`, `Truck`, `ArrowUUpLeft`, `Flask` |
| Provenance | `ChatText` (from customer), `BookOpen` (from catalog), `Gear` (from settings), `Question` (inferred), `UserCircle` (edited by you) |
| Commerce | `Storefront`, `Phone`, `MapPin`, `Money`, `TrendDown`, `ClockCounterClockwise` (history), `CloudSlash` (offline) |

---

## 7. Photography and product media

| Asset | Specification |
|---|---|
| Product images | **1:1** everywhere in P0. Centre-crop on upload with a crop adjuster. Detail gallery is full-width 1:1 with a page indicator. Thumbnails are 56 (product list), 44 (order and conversation rows) and 40 (pickers), with `radius.sm`. |
| Loading | Flat `bg.sunken` box with no shimmer, then the image fades in (150 ms). Decoding is sized to the display size (no full-resolution thumbnails). |
| Missing image | `bg.sunken` box with a centred `Package` icon in `text.tertiary`. It never looks like an error. |
| Failed to load | Same placeholder plus a small `ImageBroken` icon. Detail view adds the caption "Image unavailable" and a retry. |
| Upload in progress or failed | Thumbnail with a progress ring overlay, or a danger overlay "Not uploaded — Retry" (Phase 1 US-012) |
| Store logo | Optional, 40 × 40, `radius.md` (a rounded square distinguishes businesses from people). Fallback: store initials on `bg.brandWeak`. |
| Customer avatar | **No photos** (not collected, BR-62). A 36 px circle with up to 2 initials, or 1 Arabic-script letter, on `neutral.badgeBg`. Unknown customer: `UserCircle` icon. Colour does not vary per customer (avoids noise). |
| Illustrations | **None in P0.** Empty states use a single 24 px icon in a 64 px `bg.sunken` circle. Onboarding uses the brand mark and real UI fragments, not illustrations. |
| Imagery tone | Real seller product photos are the only imagery. Sample or demo imagery must be labelled "Sample". |
