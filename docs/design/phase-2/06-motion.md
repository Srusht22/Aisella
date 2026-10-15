# 06 — Motion design specification

**Phase 2, Deliverable 6** · Status: **Proposed — pending owner approval**
Tokens: `motion` block in [tokens/aisellia-tokens.json](tokens/aisellia-tokens.json) · Components: [05](05-components.md)

## 1. Motion principles

Aisellia's motion is **precise and settling**, like ink drying: short, decisive, and quiet once finished.

1. **Motion explains state, never decorates.** Every animation answers one question: what changed, where did it come from, or what can I do now?
2. **Data first, motion second.** The new state is applied to the data and is interactive immediately. The animation is a visual transition over correct data and **never delays an action or input**.
3. **Success only after confirmation.** Celebratory or settling motion (the ink settle) plays only after the server confirms. No optimistic success animation.
4. **Stillness is the default.** No perpetual animation except progress indicators while work is in flight. No idle shimmer, pulsing badges or animated backgrounds.
5. **Interruptible and reversible.** Every animation can be interrupted; a new state wins; animations reverse from their current value rather than jumping.
6. **Reduced motion is a first-class mode.** It is honoured from the OS setting **and** from the in-app setting (ST-06).

## 2. Tokens

| Token | Value | Typical use |
|---|---|---|
| `motion.duration.instant` | 0 ms | Focus rings, reduced-motion swaps |
| `motion.duration.xs` | 100 ms | Press feedback in |
| `motion.duration.sm` | 160 ms | Fades, colour changes, badge swaps, press release |
| `motion.duration.md` | 200 ms | Expand and collapse, list insert and remove, dialogs |
| `motion.duration.lg` | 260 ms | In-flow step transitions, product image hero |
| `motion.duration.xl` | 300 ms | Full-screen modal enter, scroll-to-top |
| `motion.duration.sheetEnter` / `sheetExit` | 280 / 200 ms | Bottom sheets |
| `motion.duration.numberRoll` | 240 ms | Stock, counts |
| `motion.duration.inkSettle` | 480 ms total (sequenced) | Approval success |
| `motion.easing.standard` | cubic-bezier(0.2, 0.0, 0.0, 1.0) | On-screen changes |
| `motion.easing.enter` | cubic-bezier(0.05, 0.7, 0.1, 1.0) | Elements entering (decelerate) |
| `motion.easing.exit` | cubic-bezier(0.3, 0.0, 0.8, 0.15) | Elements leaving (accelerate) |
| `motion.easing.linear` | linear | Determinate progress only |
| `motion.spring.sheet` | mass 1, stiffness 400, damping 40 (critically damped; no bounce) | Sheet drag release and snap-back |
| `motion.stagger` | 40 ms per item, max 4 items | First-load section entrance only |
| `motion.distance.small` / `medium` | 8 dp / 30 dp | Fade-and-slide offsets / shared-axis offsets |

Durations are fixed and never scale with content length. Content taller than 600 dp uses a crossfade instead of a size animation, so long sweeps never happen.

## 3. Navigation motion

| Transition | Purpose | Trigger | Spec | Interruption | Reduced motion |
|---|---|---|---|---|---|
| **Push / pop** (list → detail, detail → sub-screen) | Hierarchy | Navigate or back | **Platform-native route transitions**: Android uses the predictive-back-compatible system transition; iOS uses the Cupertino slide with edge swipe. This keeps gesture parity and platform familiarity. | Gesture-driven back follows the finger; cancelling returns smoothly | Crossfade, `sm` |
| **Product image hero** | Continuity from list thumbnail to detail gallery | Opening a product | Shared-element transition of the thumbnail into the gallery, `lg`, `standard` | Pop mid-flight reverses | Disabled (plain push) |
| **Tab switch** | Peer destinations, no hierarchy | Bottom nav or rail | Fade-through: outgoing fades out over 80 ms, incoming fades in and scales from 0.98 to 1 over 120 ms after it | Rapid switching cancels in-flight transitions; the last tab wins | Instant |
| **Full-screen modal** (editors, import) | A separate task layered on top | Open or close | Enter: slides up from the bottom 100% → 0 with `xl` `enter`. Exit: `md` `exit`. | Closing during enter reverses | Crossfade, `sm` |
| **In-flow steps** (store setup, welcome panels) | Sequence | Continue / Back / swipe | Shared axis X: 30 dp slide plus fade, `lg`, **direction follows reading order** (next enters from the end edge) | — | Crossfade |
| **List–detail pane** (tablets) | Selection change | Tap a row | The detail pane crossfades `sm`; no slide | Latest selection wins | Instant |
| **Language direction change** | Avoid a disorienting mirror flip | Changing app language | Whole-screen crossfade `md` | — | Instant |
| **Immediate (no animation)** | Avoid fake continuity | Deep-link entry (intermediate routes are built without animation); error state replacing content uses a crossfade `sm` only; re-selecting the active tab pops to root instantly and then animates scroll-to-top `xl` | — | — | — |

## 4. Business status changes

### 4.1 Ink settle (approval success): the signature motion
**Purpose:** show that the draft has become a committed order, and that stock changed, without obscuring any data.
**Trigger:** the server confirms approval (never on the tap).

| t (ms) | Element | Animation |
|---|---|---|
| 0 | Confirmation sheet | Exits (`sheetExit`, `exit`) |
| 0 | Underlying data | **Already swapped** to the approved order (status, ink styling, stock values) |
| 80–320 | Draft banner | The dashed outline's gaps close until it is solid (dash gap 3 → 0, `enter`). The background crossfades `bg.pencil` → `bg.brandWeak`. The content crossfades to "Approved · Stock updated · Copy confirmation message ›". |
| 160–360 | Status badge | Crossfade "Needs approval" → "Approved"; the `SealCheck` icon scales 0.9 → 1.0 with opacity 0 → 1 (`standard`) |
| 200–440 | Stock values on lines | Number roll (old → new) |
| 200 | Haptics | One *medium impact* (respects the system haptics setting) |
| ≤ 480 | Done | Static; no lingering effects |

**Interruption:** navigating away or scrolling completes it instantly (jump to end).
**Reduced motion:** a single crossfade of the changed elements (`sm`), no scale, no roll; the haptic is still played (non-visual).

### 4.2 Other status transitions
| Change | Animation | Reduced motion |
|---|---|---|
| Fulfilment step (preparing, out for delivery, delivered) | Badge crossfade `sm`; tracker line fills from the previous node to the next (`numberRoll`, `enter`); the node fills `sm` | Crossfade |
| Branch state (delivery failed, returned, cancelled) | The remaining tracker nodes collapse into the branch node: crossfade `md` | Crossfade |
| Rejected | Banner and badge crossfade to neutral; **no** settling or success motion (rejection is not a success) | Crossfade |
| **Number roll** (stock, counts, issue counter) | Changed digits slide vertically 8 dp with fade, `numberRoll`; up for an increase, down for a decrease. Tabular figures prevent width jitter. Values with more than 6 digits (amounts) crossfade instead. | Instant |
| Issue resolved on a draft | The issue row collapses `md`; the counter rolls | Instant |
| Today attention count reaching 0 | The row collapses `md`; when all reach 0, "All caught up" fades in `sm` | Instant |

## 5. Micro-interactions

| Interaction | Spec | Reduced motion |
|---|---|---|
| Button press | Scale 1 → 0.98 and overlay in over `xs`; release over `sm` (`standard`) | Overlay only |
| Row press | Overlay 6% in over `xs`, out over `sm`; no scale | Same |
| Chip / segment selection | Background colour `sm`; the check icon grows in (width 0 → 16) `sm`; haptic *selection click* | No width animation |
| Switch | Platform switch animation | Platform |
| Focus ring | Instant (accessibility: focus must be immediately visible) | Instant |
| Copy reply | Label crossfade to "Copied" with a check `sm`, hold 1,200 ms, return `sm` | Crossfade |
| Quantity stepper | The value uses a number roll | Instant |
| FAB shrink and extend on scroll | Width animation `md` | Instant |
| Haptics | Only for: approval confirmed (medium), delivery recorded (light), selection controls (selection). Never on errors (vibrating an error is alarming on shared devices), never on routine navigation. | Unchanged |

## 6. Content transitions

| Content | Spec | Notes |
|---|---|---|
| Expand / collapse (order sections, sources disclosure, variant summary, zone fields) | Size `md` `standard`; content fades in `sm` delayed 40 ms; chevron rotates 180° `md` | Content > 600 dp crossfades |
| List insert / remove | Size and fade: insert `md`, remove `sm` | Only for single-item changes caused by the user; bulk refreshes do not animate items |
| Filter or period change | Whole-list crossfade `sm`; **no per-item stagger** | — |
| Inline banner appear / disappear | Slide 8 dp from the top edge plus fade (`sm`, `enter`); exit fade `sm` | — |
| Field validation message | Fade plus 4 dp slide, 120 ms | **No shake**: shaking is decorative, ambiguous and an accessibility problem |
| AI suggestion arrives | The pencil sheet expands `md`; text fades in `sm`. **No typewriter or streaming effect**, because suggestions are shown only after validation (Phase 1 §8.7) and a typing effect would imply live generation. | Fade only |
| Skeleton → content | Crossfade `sm` | Instant |

## 7. Loading behaviour

| Element | Spec |
|---|---|
| Skeleton | Appears only after 300 ms. One slow opacity pulse, 1.0 ↔ 0.6 over 1,600 ms (sine), on all blocks in sync. **No shimmer sweep.** Static under reduced motion. |
| Inline spinner (buttons) | Platform indeterminate indicator, 16 px, current text colour |
| Page spinner | Only where structure is unknown (for example the first app-launch auth check); 24 px, centred, after 300 ms |
| Determinate progress (image upload, setup stepper) | Value changes animate linearly over `md` |
| Long waits | At 10 s the label changes ("Still working…"), with no extra animation |

## 8. Success and error feedback

| Situation | Feedback |
|---|---|
| Form saved | Native pop back, then the snackbar enters (slide up 16 dp plus fade, `md` `enter`; exit `sm`) |
| Status updated | §4.2 plus a snackbar |
| Approval | §4.1 only (no snackbar; the change is visible in place) |
| Action failed | Error banner (§6) in the same surface; the trigger returns to its default state; focus moves to the banner; no haptic |
| Recovery after retry | The banner collapses `md`; the content updates per §4 |

## 9. Onboarding and empty states

- **Welcome panels:** shared-axis steps (§3). Panel 2 plays a **one-time** demonstration of pencil → ink on a real draft-banner fragment (≤ 600 ms) when it becomes visible. It does not loop and replays only when the panel is revisited. Reduced motion shows the final state.
- **Setup checklist:** completing an item draws the check stroke `numberRoll` and crossfades the row text to `text.secondary`. When all items are done, the group collapses `lg` after a 600 ms pause.
- **Empty states:** fade in `sm`. No animated illustrations (there are none).

## 10. Sheets and dialogs

| Surface | Enter | Exit | Gestures and interruption |
|---|---|---|---|
| Bottom sheet | Slide from the bottom with `sheetEnter` and `enter`; scrim fades in over `md` | `sheetExit`, `exit` | Drag follows the finger 1:1; release dismisses if dragged > 30% of its height or flung faster than 700 dp/s; otherwise `spring.sheet` snaps back. While an action is in flight or input is dirty, drag has elastic resistance (×0.3) and always snaps back. Dismissing during enter reverses from the current position. |
| Dialog | Fade plus scale 0.96 → 1, `md`, `standard` | Fade `sm` | Scrim tap dismisses only non-destructive dialogs |
| Sheet as centred dialog (expanded windows) | Dialog motion | Dialog motion | — |
| Keyboard | Sheets and sticky bars follow the keyboard inset as the platform animates it, with no extra animation | — | — |

## 11. Performance requirements

- Animate **only opacity and transforms** (translate, scale, rotate) wherever possible. Size animations are limited to small subtrees (a single section or row).
- No `BackdropFilter` or blur. No animated shadows (shadows are static per elevation level). No `Opacity` wrappers around large subtrees: use fade transitions.
- Isolate animated regions with repaint boundaries. Long lists are virtualised, and list items never run independent entrance animations.
- No more than **two concurrent animations** in the same region; staggers are capped at 4 items.
- Animation controllers are disposed with their widgets. Nothing animates off-screen.
- **Target (to verify in Phase 12, profile builds on a mid-range Android reference device):** no frame over 16 ms during the transitions listed in §3–§10, and no layout shift visible after an animation ends.
- Test every expand, collapse and status transition with both minimal and maximal content (1 vs. 30 order lines; short vs. 3-line localized labels; 200% text scale).

## 12. Dependencies

- **No animation package is required for P0.** Flutter's built-in implicit and explicit animations, route transitions and hero transitions cover everything above.
- The Flutter team's `animations` package (shared axis, fade-through) is optional; Phase 4 may evaluate it instead of hand-writing two transitions.
- **Lottie and Rive are not recommended:** no screen needs vector-illustration playback, and both add size and maintenance cost.
