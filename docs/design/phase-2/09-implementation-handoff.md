# 09 — Implementation handoff (for Phase 4)

**Phase 2, Deliverable 9** · Status: **Proposed — pending owner approval**

This document tells Phase 4 how to turn the approved design into Flutter code *without* deciding the Phase 3 architecture: state management, routing library, backend and data layer stay open. It names Flutter concepts only where they are the natural carrier of a design rule.

## 1. Sources of truth

| Need | Source |
|---|---|
| Colours, type, spacing, radii, elevation, motion values | [tokens/aisellia-tokens.json](tokens/aisellia-tokens.json). Code must not contain design literals. |
| Rules for using them | [02](02-visual-identity-and-tokens.md), [06](06-motion.md), [07](07-localization-and-accessibility.md) |
| Components and their states | [05](05-components.md) |
| Screens, states and acceptance | [04](04-screen-specifications.md) and Phase 1 user stories |
| Definition of "looks done" | [08](08-design-acceptance-checklist.md) |

When implementation reveals a gap or a contradiction, **update the design document in the same change** rather than inventing a local rule.

## 2. Recommended translation path

1. **Tokens → theme layer.** Map the token file into a light and a dark theme.
   - Standard roles map to the framework's colour scheme and text theme.
   - Aisellia-specific roles map to typed theme extensions: pencil colours, semantic foreground/background pairs, provenance, per-script type styles, spacing, radii and motion.
   - Generating Dart constants from the JSON with a small script is preferred over hand-copying, so the JSON stays authoritative. Phase 4 decides.
2. **Per-script typography.** Two text themes (`en` and `ckb` values from the token file), selected by locale. Inter is first in the family stack with Vazirmatn NL as fallback in **both** locales. Explicit line heights with evenly distributed leading. Tabular-figure styles for numerics.
3. **Primitives first.** Build CMP-Button, TextField, RowGroup/FieldRow, StatusBadge, Banner, BottomSheet, StickyActionBar, Skeleton and EmptyState/ErrorState, plus the **pencil primitives**: a dashed-border painter and a dotted underline.
4. **State patterns as reusable wrappers.** P-LOAD-LIST, P-EMPTY, P-ERR-LOAD, P-ERR-ACTION, P-ERR-UNKNOWN and P-OFFLINE ([04 §1](04-screen-specifications.md#1-shared-state-patterns)) should be one implementation each, used by every screen.
5. **Motion primitives.** Duration and easing constants from the tokens; a single reduced-motion switch (OS setting OR in-app setting) read by every animated component; the ink-settle sequence and number roll as reusable widgets.
6. **App shell.** Bottom bar ↔ rail by window class; per-tab navigation stacks; the store button; global banners (offline, AI unavailable, verify email). The Phase 3 routing choice **must** support per-tab stacks, entity deep links and predictive back.
7. **Representative real screens** (Phase 4 exit criterion: "a small representative set of real screens"). Recommended set, because together they exercise nearly every component and rule:
   - **TD-01 Today** (rows, counts, banners, empty and all-caught-up states)
   - **PR-01 Product list** (search, chips, media, virtualised list)
   - **OR-02 Draft review + OR-03 Approve sheet** (pencil system, provenance, sticky bar, sheet and ink settle)
   - **ST-06 Language and display** (live direction, digit and theme switching)

   Until the Phase 5–8 data layers exist, these screens run on **explicitly labelled sample fixtures** inside the real app, not in a separate mock app.
8. **Design-system gallery.** A debug-only route inside the real app listing every component in every state, in both directions and themes. It is the target of golden tests and of the [08](08-design-acceptance-checklist.md) review. It is excluded from release builds.

## 3. Component mapping guidance

| Component | Suggested basis | Notes |
|---|---|---|
| CMP-Button variants | Framework filled, outlined and text buttons styled from tokens | Loading state locks width; idempotent trigger callback contract |
| CMP-TextField | Framework text field with a custom decoration (label above) | Direction-from-content behaviour; digit normalisation formatter (shared with search) |
| CMP-SegmentedControl | Framework segmented button, restyled | ≤ 4 options |
| CMP-BottomSheet | Framework modal bottom sheet with a custom drag policy | Elastic lock while busy or dirty; dialog presentation on expanded windows |
| BottomNav / NavRail | Framework navigation bar and rail | Fill icons for active; count badges |
| CMP-DraftBanner, InferredValue, pencil underline | **Custom painter** (dashed rounded rectangle, dotted underline) | Dash 4 / gap 3 / 1.5 px; animatable gap for the ink settle |
| CMP-ProgressTracker | Custom widget | RTL-aware; branch states |
| Number roll | Custom widget over tabular text | Falls back to a crossfade for > 6 digits and under reduced motion |
| Message bubbles | Custom | Per-bubble direction detection |

## 4. Assets and dependencies to evaluate in Phase 4

| Item | Status | Action |
|---|---|---|
| Inter (OFL 1.1) | Verified coverage, licence and tabular figures in Phase 2 | Bundle; register the licence in the in-app licence page |
| Vazirmatn NL 33.0.3 (OFL 1.1) | Verified Sorani coverage and HarfBuzz shaping | Bundle; check that variable-weight rendering works in Flutter on both platforms, else use static 400/500/600 |
| Phosphor icons (MIT) | Style chosen; Flutter wrapper maintenance weak (last release 2024-05-10, 55/160 points) | **DD-05:** vendor a curated subset as an icon font or SVGs, *or* adopt the package after review |
| `animations` package (optional) | Not required | Evaluate for shared-axis and fade-through only |
| Lottie / Rive | **Not recommended** | — |

## 5. Verification tasks Phase 4 must perform (not verifiable in Phase 2)

These were impossible to verify here: no Flutter SDK, no Android SDK (its download host is blocked by the environment's network policy) and no devices, per Phase 0.

1. Kurdish Sorani shaping and line metrics in Flutter on Android and iOS (golden tests plus devices).
2. `ckb` availability in Flutter's Material, Cupertino and Widgets localizations and in date and number formatting; build custom delegates if missing ([07 §1](07-localization-and-accessibility.md#1-localization-foundations)).
3. iOS edge-swipe back and Android predictive back under RTL.
4. Sorani text-to-speech output with TalkBack and VoiceOver.
5. Frame timing of the §3–§10 transitions in [06](06-motion.md) on a chosen mid-range Android reference device (profile mode).
6. Re-run `tools/contrast_check.py` after any token change; add any new colour pair to the token file first.

## 6. What Phase 4 must not invent

New colours, radii, type sizes or durations; new card or row styles; new status wording; any "Sent", "Connected" or "Confirmed" wording outside the specified states; swipe actions; Undo affordances; decorative animation; illustrations; emoji. Any need for these is a design change: propose it in the docs, then implement it after approval.
