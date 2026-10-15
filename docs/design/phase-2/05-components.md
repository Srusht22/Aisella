# 05 — Component specification

**Phase 2, Deliverable 5** · Status: **Proposed — pending owner approval**
Tokens: [02](02-visual-identity-and-tokens.md) · Motion: [06](06-motion.md) · Screens using them: [04](04-screen-specifications.md)

**Principles**
- **One component per job.** There is a single row-group pattern, not a card per screen. Variants exist only where behaviour differs, not just appearance.
- **States are part of the component.** Every interactive component defines default, pressed, focused, disabled, loading (if it triggers work), error and success behaviour.
- **No false success.** A component never shows a completed state for work the server has not confirmed.
- **Direction-agnostic.** Components are specified with *start* and *end*, never left and right.

---

## 1. Actions

### CMP-Button
**Anatomy:** container, optional 20 px leading icon, label (style `button`), optional trailing spinner slot.
**Sizes:** height 48 (all window classes), horizontal padding 16 (icon side 12), `radius.md`. Full width inside sheets and sticky bars on compact screens.

| Variant | Fill / border / label | Use | Never use for |
|---|---|---|---|
| `primary` | `brand.primary` / none / `text.onBrand` | The single most important action on a screen or sheet (Approve, Save, Copy reply) | More than one per surface; uncommitted status display |
| `secondary` | `bg.surface` / 1 px `border.control` / `text.primary` | Alternatives of equal weight (Create order next to Copy reply) | Destructive actions |
| `tertiary` | none / none / `text.brand` | Low-emphasis actions, links in rows (See summary, Resend) | Primary flows |
| `dangerOutline` | `bg.surface` / 1 px `border.hairline` / `danger.fg` | **Triggers** for destructive or negative outcomes (Reject, Cancel order, Delete) | Final confirmation |
| `danger` | `danger.fg` / none / `danger.onFill` | **Final confirmation** of an irreversible action, only inside its confirmation dialog or sheet (Delete account, Cancel order confirm) | Triggers; anything reversible |
| `warning` | `bg.surface` / 1 px `warning.fg` / `warning.fg` | Recording a problem state (Mark delivery failed) | — |

**States**

| State | Visual | Behaviour |
|---|---|---|
| Default | As above | — |
| Pressed | Primary: `brand.primaryPressed`. Others: overlay `text.primary` at 6% (light) or 10% (dark). Scale 0.98 (100 ms). | Activates on release; cancelled if the finger slides off |
| Focused (keyboard or switch access) | 2 px `border.focus` ring, 2 px offset | Enter or Space activates |
| Disabled | Primary: fill at 40% opacity, label unchanged. Others: label `text.disabled`. | **Must** be accompanied by a visible reason when the user would expect it to work (reason line above the action bar or a helper under the button). Tapping a disabled critical button (Approve) scrolls to the cause. |
| Loading | Label becomes the progress label ("Approving…"), with a 16 px spinner at the start; width locked to its pre-loading width; non-interactive | Repeated taps are ignored (debounce plus idempotency key) |
| Success | **No button-level success for business writes.** The outcome shows on the record (status, number). Exception: clipboard copy morphs the label to "Copied" with a check icon for 1.2 s. | — |
| Failure | Button returns to its default state; the error shows in P-ERR-ACTION | Retry is the same button |

**Group rules:**
- In a sticky bar, the primary goes at the **end** and the secondary or danger trigger at the **start**.
- When the localized labels do not fit side by side at the current text scale, the buttons stack vertically with the primary on top.
- Never place two `primary` buttons together.

### CMP-IconButton
48 × 48 hit area, 24 px icon, a localized tooltip on long-press or hover, and a semantics label. Pressed: circular overlay. Used for back, close, more, search, copy, retry. Never used for Approve, Reject or any destructive action without a label.

### CMP-Fab.extended
Phones only; sits above the bottom bar at the end side; `brand.primary`, 56 high, `radius.md` (not pill), icon plus label ("Import message", "New order", "Add product"). It shrinks to icon-only when the list scrolls down and expands on scroll up (200 ms). On medium+ windows it becomes a primary button in the app bar. **One per screen.**

### CMP-StickyActionBar
`bg.surface` with a top hairline; padding 12/16, plus the bottom safe area. An optional **reason line** above the buttons (`caption`, warning or info colour with an icon) explains a disabled primary. It hides under the keyboard. On medium+ windows it is anchored to the detail pane, not the full window.

### CMP-InlineLink
`text.brand`, underlined only on focus or hover (and always underlined inside running text, for accessibility). It opens in-app viewers for legal pages.

---

## 2. Inputs

### CMP-TextField
**Anatomy:** label (above the field, `label`, always visible: no floating placeholders as labels), field container (`bg.surface`, 1 px `border.control`, `radius.md`, height 48 for single line), optional leading icon, input text (`body`), optional trailing affordance (clear, show/hide, unit suffix), helper or error text below (`caption`), character counter (shown when > 80% of the limit).

| Variant | Specifics |
|---|---|
| `text` | Direction **detected from content** (first strong character); alignment follows. |
| `multiline` | Grows from 3 to 8 lines, then scrolls; used for descriptions, policies and imported messages. |
| `email`, `password` | Always LTR; autofill hints; password show/hide toggle. |
| `phone` | Always LTR; accepts `07…`, `+964…`, `00964…`, spaces, dashes and Eastern digits; normalises on blur to `+964 7XX XXX XXXX` display. |
| `money` | Numeric keyboard; integer only; thousands separators formatted while typing; currency unit as a non-editable suffix (localized); LTR digits, end-aligned. |
| `quantity` | See CMP-QuantityStepper. |

| State | Visual |
|---|---|
| Focused | 2 px `border.focus` |
| Error | 2 px `danger.fg` border plus an error message with a `WarningCircle` icon; the message replaces the helper text (both are never shown together) |
| Disabled / read-only | `bg.sunken` fill, `text.secondary` value, no border change on focus; read-only text is still selectable and copyable |
| Pencil (AI-filled, in edit sheets) | Value shown with the provenance caption under the field; the caption changes to "Edited by you" after the first change |

**Validation timing:** validate on submit. After the first submit, validate each field live (on change after a 300 ms pause). Never show an error on first focus or for a field the user has not touched.

### CMP-SearchField
48 high, `bg.sunken` fill, no border, `radius.md`, `MagnifyingGlass` at the start, clear button at the end when it has text. The placeholder states the scope ("Search orders by number, name or phone"). Results filter after a 250 ms debounce. Eastern digits and phone formats are normalised. Direction follows the typed content.

### CMP-SelectRow (dropdown replacement)
A row showing the label and current value with a chevron, opening a **bottom sheet list** (single or multi select) with search when there are more than 8 options. Native dropdown menus are not used, because they behave inconsistently in RTL and with large text.

### CMP-SegmentedControl
2–4 options, equal width, 40 high, `bg.sunken` track and `bg.surface` selected segment with a hairline. Used for exclusive modes (IQD/USD, Add/Remove/Set, period). With more than 4 options, or labels that do not fit, use CMP-SelectRow.

### CMP-Switch / CMP-SelectionRow
- **Switch:** a platform-adaptive switch inside a full-width row (the label is tappable); used for immediate on/off settings.
- **SelectionRow:** a radio or checkbox inside a 48+ high row with the label and an optional description.
- A switch that saves to the server shows an inline spinner in place of the switch while saving, and reverts with an error message on failure. It never stays flipped on failure.

### CMP-Chip / CMP-FilterChipRow / CMP-ReasonChips
- **Chips:** 32 high (with a 48 hit area through padding), `radius.sm`, `label` style. Unselected: hairline border. Selected: `bg.brandWeak`, `text.brand` and a check icon.
- **FilterChipRow:** single-select status groups; horizontally scrollable with an end fade; the selected chip scrolls into view.
- **ReasonChips:** single-select preset reasons; selecting "Other" reveals a required text field.

### CMP-QuantityStepper
`[−] value [+]`, buttons 40 × 40 (48 hit area), `radius.sm`. The value is tappable for direct numeric entry. Bounds 1–999. A soft warning above 20 ("Large quantity — check"). When the value would exceed stock (tracked items), the value shows a danger outline and the message "Only 4 in stock". `+` and `−` keep their meaning in RTL: their *positions* mirror (− at start, + at end in reading order), but the glyphs never do.

---

## 3. Rows and lists

### CMP-RowGroup and CMP-FieldRow
- **RowGroup:** `bg.surface`, 1 px hairline border, `radius.md`, rows separated by hairlines. This is the default container for all detail content.
- **FieldRow:** label column (`label`, `text.secondary`, flexible width 30–40%) and value column (`body`, `text.primary`), with an optional provenance caption under the value and an optional trailing chevron or action. Minimum height 48.
- **Below 360 dp, or at text scale ≥ 1.3,** label and value stack (label above value).

**When not to use:** a single value with no label (use plain text), or long prose (use a text block).

### CMP-SectionHeader
`overline` text, 8 above its RowGroup, 24 from the previous section. An optional trailing tertiary action ("+ Add item").

### List rows
| Component | Content (start → end) | Height | Notes |
|---|---|---|---|
| `ProductRow` | 56 thumbnail · name (2 lines) + price or variant summary · stock indicator | 72 min | Archived: name in `text.secondary` with an "Archived" badge |
| `OrderRow` | Order number + status badge / customer · item summary · total (tabular) + relative time | 72 min | Test orders carry the outlined Test badge |
| `ConversationRow` | Initials avatar · name + source label / 2-line preview · time + status | 72 min | Unread or needs-reply: name in `body.strong` plus a brand dot with text "Needs reply" |
| `CustomerRow` | Avatar · name / phone (LTR) · order count | 64 | — |
| `AttentionRow` | 20 icon · label · count or amount (tabular) · chevron | 56 | Hidden when the count is 0 |
| `SummaryRow` | Label · value (tabular) | 48 | Tappable to its list |
| `ChecklistRow` | Check-circle or open-circle · task · chevron | 56 | Completed rows: `text.secondary` with a check |

All rows: the entire row is tappable; pressed state uses a 6% overlay; long-press does nothing in P0 (no hidden gestures); swipe actions are **not used** (they are hidden, hard to discover and risky in RTL).

### CMP-OrderLineRow
44 thumbnail · product name (`body.strong`, 2 lines) / variant label · stock indicator / quantity (or inferred-value box) · unit price and line total (tabular, end).

| State | Treatment |
|---|---|
| Resolved | Ink |
| Choose product | Danger outline; up to 3 candidate chips; "Customer said: 'the black one'" |
| Variant needed | Warning; the available values as chips |
| Out of stock / insufficient | Danger caption "Requested 2 · 1 in stock" with fix actions |
| Price changed | Warning caption with a two-option choice |
| Archived / unavailable | Danger caption; Replace or Remove |

### CMP-PriceRow / CMP-TotalBlock
- **PriceRow:** label (flexible, wraps) and amount (tabular, end-aligned, **never truncated**).
- **TotalBlock:** Subtotal, Delivery, Discount (shown with a minus sign, never colour-coded red) and **Total** (`numeric.total`) with the payment method in the label ("Total · Cash on delivery").
- Amounts use the store currency format ([07 §3](07-localization-and-accessibility.md#3-numbers-currency-dates)).
- *(Fix from the concept-board review: label width must be flexible.)*

---

## 4. Status and AI provenance

### CMP-StatusBadge
24 high, `radius.sm`, 8 horizontal padding, 16 icon plus `label` text. Colours and icons per [02 §2.3](02-visual-identity-and-tokens.md#23-order-status-colour-mapping). **Always icon plus text.** The pencil variant (draft, needs approval) uses a dashed border. Never truncated; badges wrap below the title if needed.

### CMP-StockIndicator
Text plus optional icon, per [02 §2.4](02-visual-identity-and-tokens.md#24-inventory-indicators). The number is tabular and LTR-isolated.

### CMP-ProvenanceCaption
`caption` style, 16 icon plus text ("From customer", "Catalog price", "From your settings", "Inferred — confirm", "Edited by you"). It is tappable for "From customer" (opens the source-excerpt sheet showing the quoted customer message and its time). Colour is `text.tertiary` except inferred (warning) and conflict or missing (danger).

### CMP-InferredValue
The value inside a 1.5 px dotted warning-coloured box (`radius.sm`), plus an inline **Confirm** tertiary button. Confirming converts it to "Edited by you" (ink).

### CMP-DraftBanner
Pencil sheet (`bg.pencil`, dashed `border.pencil`, `radius.md`), `PencilSimple` icon, title **"Draft — not confirmed"** (`body.strong`), a description of the source ("Prepared by Aisellia from an imported Instagram chat") with a **View chat** link. For test orders, a "Test" badge is appended. **Mandatory** at the top of every draft or pending order. It cannot be dismissed.

### CMP-IssueSummary
Shown under the DraftBanner when issues exist. Danger tone if any issue blocks approval, otherwise warning tone. The title states the count ("2 things to check"); one row per issue, each linking to and focusing its field. It collapses as issues resolve.

### CMP-ProgressTracker (order)
4 nodes (Approved, Preparing, Out for delivery, Delivered) joined by a 2 px line. Completed nodes are filled `brand.primary` with a check; the current node is a filled ring; future nodes are outlined `border.control`. Labels sit below (`caption`, wrapping to 2 lines). A branch state (Delivery failed, Returned, Cancelled) replaces the remaining nodes with a single labelled state node in its semantic colour. Mirrored in RTL.

### CMP-CountBadge
On navigation icons: `danger.fg`-free, using a `brand.primary` fill with `text.onBrand` digits (counts mean "work to do", not "error"), 18 high, capped at "99+".

---

## 5. Conversation components

### CMP-MessageRow
| Part | Spec |
|---|---|
| Bubble | Max width 80% (phones) or 560 (tablets); `radius.md` with the corner nearest the sender's edge reduced to `radius.sm`; inbound: `bg.surface` with a hairline; outbound (seller): `bg.brandWeak` |
| Text | `body.large`; direction detected from content; links not auto-clickable in P0 (untrusted input) |
| Caption | Time (localized) + `MessageStateCaption` |
| Placement | Inbound at the **start** side, outbound at the **end** side |

### CMP-MessageStateCaption
Exact wording, required by BR-45 and BR-46:

| State | Caption | Icon |
|---|---|---|
| `imported` | "Imported {time}" | `DownloadSimple` |
| `copied` | "Copied — not confirmed as sent" | `Copy` |
| `marked_sent` | "Marked as sent by you" | `UserCircle` |
| `sent` (P1 only) | "Sent" | `Check` |
| `failed` (P1) | "Not sent — Retry" (danger) | `WarningCircle` |
| `unknown` (P1) | "Sending status unknown — Check" (warning) | `Question` |

### CMP-SuggestionComposer
| Part | Spec |
|---|---|
| Container | Pencil sheet, pinned above the action row; collapsible to a one-line summary ("Suggested reply ready") |
| Header | `PencilSimple` + **"Suggested reply — not sent"**, plus a Regenerate icon button |
| Body | Editable text (tap to edit; the keyboard opens and the sheet expands); edits remove nothing from the sources list |
| `SourcesDisclosure` | "Uses: Beige Abaya price · Erbil delivery fee", expandable to a list of each data item used, linked to its record |
| `MissingInfoChips` | Warning chips such as "Needs: colour", "Needs: phone" |
| States | Loading (skeleton lines + Cancel) · Ready · Edited ("Edited by you" caption) · Failed (inline error + Try again + Write it yourself) · Unavailable (manual mode: an empty text field labelled "Write your reply") · Escalated (the suggestion is a *holding reply*, labelled "Suggested holding reply") |

### CMP-EscalationBanner
`Flag` icon, **"Needs you — {reason}"** (danger tone), and a **Mark handled** tertiary action. It cannot be dismissed any other way.

### CMP-LinkedDraftChip
A pencil-styled row "Draft order #1042 · 1 to check ›". It switches to ink ("Order #1042 · Approved ›") when the order is committed.

---

## 6. Identity elements

| Component | Spec |
|---|---|
| `Avatar` | 36 circle, `neutral.badgeBg`, initials in `label` 600; Unknown: `UserCircle`; no colour per person |
| `StoreButton` | 40, `radius.md`, logo or initials on `bg.brandWeak`; semantics label "Store menu, {store name}" |
| `ProductThumbnail` | Sizes 40/44/56, `radius.sm`, 1:1; placeholder, loading and failed states per [02 §7](02-visual-identity-and-tokens.md#7-photography-and-product-media) |

---

## 7. Feedback and overlays

### CMP-Banner (inline)
Full width inside the content gutter, `radius.md`, 12 padding, 20 icon, title (`body.strong`) and optional description, one optional action (tertiary).

| Tone | Use |
|---|---|
| `info` | Verify email, imported-manually note, sandbox |
| `warning` | Issues to check |
| `danger` | Blocking issues, failed actions |
| `success` | Rare: "Email verified" when shown inline |
| `neutral-offline` | Offline |

A banner is dismissible only when it is informational and non-blocking.

### CMP-Snackbar
Bottom, above the sticky bar or bottom nav, level 2, `radius.md`. Message (1–2 lines) plus at most one action (Undo or View).
- Duration: 4 s; 8 s when it has an action; it stays while touched or focused by assistive technology.
- Announced as a polite live region.
- **Not used for errors that need action, for approval outcomes, or as the only confirmation of a critical action.**
- Undo is offered only when the operation can be truly reversed server-side within the window (P0: none of the order transitions; stock adjustments use history-based correction, not Undo). P0 has no Undo snackbars at all, which avoids false promises.

### CMP-Dialog
Centred, max width 400 (phones: gutter 24), `radius.lg`, level 3 with scrim. Title (`title`), body (`body`), actions at the end (stacked when they do not fit). The default focus is the **safe** option. Used only for: discard changes, destructive confirmation, sign out, blocking errors. Dismissed by the scrim tap only when non-destructive.

### CMP-BottomSheet
`bg.raised`, top corners `radius.lg`, a drag handle (32 × 4, `border.control`), title, content, then a sticky action area. Max height 90%; content scrolls. Drag-to-dismiss and scrim tap dismiss it, **except while an action is in flight or the sheet has unsaved input** (it then asks GL-06 or resists with an elastic snap-back). On expanded windows it presents as a centred dialog of max width 560.

### CMP-Tooltip
For icon buttons only (long-press or hover), level 2, `caption`. Never used for essential information.

### CMP-EmptyState / CMP-ErrorState / CMP-Skeleton / CMP-Spinner
- **EmptyState** and **ErrorState:** as defined in [04 §1](04-screen-specifications.md#1-shared-state-patterns) (P-EMPTY, P-ERR-LOAD).
- **Skeleton:** `bg.sunken` blocks matching the content geometry; `radius.sm`; one slow pulse (static under reduced motion).
- **Spinner:** 16 (inline) or 24 (page, used only when a skeleton is not meaningful); 2 px stroke in the current text colour.

---

## 8. Navigation chrome

| Component | Spec |
|---|---|
| `AppBar.large` | Tab roots: `title.large` that collapses into a 56 dp `title` bar on scroll; the store button at the end |
| `AppBar.standard` | 56 dp, back (mirrored) at the start, title (1 line), up to 2 actions plus overflow at the end; a hairline appears when content scrolls under it |
| `BottomNav` | 64 dp, 4 items, 24 icon (Regular when inactive, **Fill** when active) plus `label`; the active item has a 32 × 64 `bg.brandWeak` pill behind the icon; count badges per [03 §1](03-information-architecture.md#1-primary-navigation) |
| `NavRail` | 72 dp wide, same items, store button at the top, active pill as above |
| `Pager` + `PageIndicator` | Dots, 8 px, active dot widened to 20 px; mirrored order in RTL |
| `Stepper header` | "Step 2 of 3" plus a 4 px linear progress bar (`brand.primary` on `bg.sunken`) |

---

## 9. Interaction behaviours

| Behaviour | Rule |
|---|---|
| **Keyboard and focus** | Next/Done IME actions move through fields in visual order (mirrored in RTL); Done on the last field submits only if the form is valid; tapping outside closes the keyboard; focused fields scroll above the keyboard and the sticky bar; on submit with errors, focus moves to the first invalid field. Hardware keyboards (tablets): Tab order matches the reading order; Enter activates buttons; Esc closes sheets and dialogs (with the unsaved guard). |
| **Pull-to-refresh** | On tab-root lists and Today only. It shows the platform indicator, then refetches. It is never the only way to recover from an error (an explicit Retry always exists). |
| **Long-running operations** | > 300 ms: a loading state on the trigger. > 10 s: "Still working…". Timeout (writes: 30 s; AI: 30 s): P-ERR-UNKNOWN for writes or the failure state for AI. Navigation away is allowed for reads and blocked during critical writes. |
| **Forms with unsaved changes** | Dirty tracking per editor; GL-06 on exit; Save is disabled until something changes (edit mode) and stays enabled in create mode, to show validation. |
| **Destructive operations** | Trigger in `dangerOutline` → confirmation (dialog or sheet) restating the consequence in plain words → `danger` confirm button → the safe option is the default focus. Typed confirmation is used **only** for account deletion. |
| **Confirmation policy** | Confirm: approve, reject, cancel, mark returned, delete image, delete customer, delete account, sign out, discard changes. **Do not** confirm: saving forms, status steps forward (preparing, out for delivery, delivered: each opens a sheet with its own inputs anyway), copy, filters. |
| **Retry** | Every load or action failure offers Retry on the same surface; retries reuse the idempotency key for writes. |
| **Double-submission** | All write triggers are debounced (500 ms) **and** send an idempotency key (server-enforced, Phase 1 BR-22). |
