# 07 — Localization and accessibility specification

**Phase 2, Deliverable 7** · Status: **Proposed — pending owner approval**
Builds on Phase 1 §9.1 (L-01–L-13) and §9.2 (M-01–M-06). Visual tokens: [02](02-visual-identity-and-tokens.md).

> Sorani wording in this document is a machine draft for design purposes. **All Sorani strings, month names, currency labels and punctuation conventions require review by a native Sorani-speaking reviewer before Phase 4 strings are finalised (DD-04).**

---

## 1. Localization foundations

| Locale | Script | Direction | Status |
|---|---|---|---|
| `ckb` (Central Kurdish / Sorani) | Arabic script | RTL | P0, primary |
| `en` | Latin | LTR | P0 |
| `ar` | Arabic script | RTL | Architecture-ready (P1) |

**Recommended Flutter practices** (for Phase 4 to confirm; not implemented here):
- Use ARB-based generated localizations: one key per string, ICU message format for plurals and selects, and a translator description on every key.
- Never concatenate translated fragments; use placeholders ("{count} items in stock").
- Set direction from the locale (`Directionality`), never per screen. Use directional geometry (start and end padding and alignment) everywhere; physical left and right are allowed only for genuinely physical things (none in P0).
- Run **pseudo-localization** builds in CI: (a) expanded English with about +40% length and accented characters; (b) a pseudo-RTL build. These catch hard-coded strings and direction bugs early.
- **Unverified risks for Phase 4:**
  1. Whether Flutter's built-in Material and Cupertino localizations include `ckb`. If they do not, Aisellia must supply its own Material, Cupertino and Widgets localization delegates for `ckb`. English fallback strings inside system widgets (back tooltips, date pickers, text-selection menus) are **not acceptable**.
  2. Whether the date and number formatting library ships `ckb` data.
  3. How the iOS back-swipe gesture behaves under RTL in Flutter.

  Each must be tested on a device, not assumed.
- **Translation keys carry context:** "Approve" (button that commits an order) is a different key from "Approved" (status), so translators can choose the correct grammatical forms.

---

## 2. RTL layout rules

### 2.1 What mirrors
| Element | LTR | RTL |
|---|---|---|
| Reading order of rows, columns, list–detail panes | Start = left | Start = right (list pane on the right) |
| Back button, back gesture | Top-left; swipe from left | Top-right; swipe from right (platform behaviour, to be verified in Phase 4) |
| Chevrons, arrows, "next" icons | Point right | Point left |
| Navigation bar and rail item order | Today first, at the left | Today first, at the right |
| Progress tracker, stepper, pager dots, linear progress | Fill left → right | Fill right → left |
| Message bubbles | Customer left, seller right | Customer right, seller left |
| Sticky action bar | Secondary or danger left, primary right | Secondary or danger right, primary left |
| Sheet titles and close buttons | Title left, close right | Title right, close left |
| Swipeable pagers (welcome) | Next from the right | Next from the left |
| Text alignment | Left (start) | Right (start) |
| Quantity stepper positions | − left, + right | − right, + left (glyphs unchanged) |

### 2.2 What never mirrors
- Icons depicting real objects or universal symbols: check, close, plus, minus, search, camera, image, phone, clock, warning, info, store, package, truck, flask, seal.
- Media playback icons; brand marks and the Aisellia logo; channel brand names; product photos.
- **Numbers, phone numbers, prices, SKUs, order numbers, URLs and email addresses.** These are LTR runs isolated inside RTL text.
- The return-arrow icon `ArrowUUpLeft` **does** mirror (it is directional).
- The `ClockCounterClockwise` (history) icon **does not** mirror: it depicts a clock, and clock direction is universal.

### 2.3 Mixed-direction content
| Content | Rule |
|---|---|
| UI strings | Direction of the UI locale |
| User-entered text (product names, descriptions, policies, customer names, messages, notes) | **Direction detected per paragraph** from the first strong character, so English product names in a Sorani UI render LTR inside their own run, and Sorani customer messages render RTL in an English UI |
| Latin product name inside a Sorani sentence (for example a suggested reply) | The run is bidi-isolated (FSI…PDI or an equivalent separate text span) so neighbouring punctuation does not jump |
| Phone numbers | Always LTR, isolated, formatted `+964 750 123 4567`; never split across lines |
| Order numbers | `#1042` as one LTR isolated run; the "#" stays on the left of the digits in both directions |
| SKUs, emails, URLs | LTR isolated |
| Amount plus currency | The number is LTR-isolated; the currency label is placed per locale (§3) |
| Numeric ranges | **Found in the type-specimen review:** a range like `١–٢` in RTL text is reordered by the bidi algorithm and can be misread. Sorani strings write ranges with a word ("1 بۆ 2 ڕۆژ"), or isolate the whole range as one LTR run. Native review decides (DD-06). |
| Punctuation | Sorani strings use Arabic-script punctuation (، ؛ ؟). Quotation-mark style is chosen by the native reviewer. |

### 2.4 Forms, dialogs, search
- Labels, helper text and error text are **start-aligned** in the UI direction.
- Input text alignment follows the UI direction (start), while its *text direction* follows the content. Example: an LTR phone number in a Sorani form is right-aligned as a block, but its digits read left to right.
- Amount columns (prices, totals, line totals) are **end-aligned** in both directions so digits align vertically.
- In search fields the magnifier sits at the start and the clear button at the end; the typed-text direction is auto-detected.
- In dialogs and sheets the title is at the start and actions at the end. When actions stack, the primary is on top.
- The validation-summary banner lists errors in reading order and focuses the first invalid field.

### 2.5 Truncation and long strings
- Ellipsis is applied at the logical end of the text (left side for RTL text).
- No fixed heights for text containers. Every text container must survive +40% length and 200% text scale without clipping. Where space truly runs out, follow the rules in [02 §3.3](02-visual-identity-and-tokens.md#33-truncation-rules).
- Button labels and badges never truncate (they wrap, or the button group stacks).

### 2.6 Charts and data displays
P0 has no charts. For future charts: the time axis runs in reading direction (right → left in RTL); value axes and number labels stay LTR-isolated. This must be confirmed with native users before any chart ships.

### 2.7 Tablets
List–detail panes mirror (list on the right in RTL). The large-window third column (the source conversation on draft review) sits at the end side (leftmost in RTL).

### 2.8 Keyboard and focus navigation
Focus traversal follows **reading order** (mirrored in RTL). IME next and previous move in reading order. Arrow keys in segmented controls and tab rows move in the *visual* direction, matching platform conventions for RTL.

---

## 3. Numbers, currency, dates

| Item | English | Sorani (proposal: native review required) |
|---|---|---|
| Digits | Western 0–9 | **Default Western 0–9** (Phase 1 D-10). Setting: Eastern Arabic ٠–٩ (U+0660–0669). |
| Digit input | Accept Western, Eastern Arabic (U+0660–0669) and Persian (U+06F0–06F9); normalise on save | Same |
| Digits in phone numbers, SKUs, order numbers | Western | **Always Western**, even with the Eastern setting, because they are copied into other apps and courier slips (**DD-07**) |
| Thousands separator | `35,000` | Western digits: `35,000`. Eastern digits: `٣٥٬٠٠٠` (U+066C) |
| Decimals | Not used (integer currency, Phase 1 BR-12) | Not used |
| IQD amount | `35,000 IQD` | `35,000 د.ع` (unit after the number, separated by a space) — **DD-08** |
| USD amount | `$25` | `$25` (proposal) — **DD-08** |
| Dates (short) | `15 Oct` (current year) / `15 Oct 2025` | Day plus Sorani month name (for example `15ی تشرینی یەکەم` for October); the month-name set is to be confirmed by the native reviewer (**DD-09**) |
| Relative times | "now", "5 min ago", "Yesterday" | Localized equivalents ("ئێستا", "5 خولەک لەمەوبەر", "دوێنێ") |
| Time | 12-hour with AM/PM | 12-hour with localized markers (proposal; DD-09) |
| Calendar | Gregorian | Gregorian |
| Week start (future date pickers) | Saturday, per local business week (to confirm) | Saturday |
| Plurals | ICU `one` / `other` | ICU rules per CLDR for `ckb` (`one` / `other`) |

---

## 4. Typography in Arabic script
- **Fonts:** Vazirmatn NL for Arabic script plus Inter for Latin, bundled ([02 §3](02-visual-identity-and-tokens.md#3-typography)).
- **Sizes and line heights:** Sorani styles are one step larger with taller lines ([02 §3.2](02-visual-identity-and-tokens.md#32-type-scale)). Minimum Sorani text size is 13 (caption).
- **No letter-spacing** on Arabic-script text. No uppercase transforms. No italics (Arabic script has no true italic; emphasis uses weight).
- **Line-height consistency with mixed fonts:** explicit line heights per style (with leading distributed evenly) so that a line containing both Inter and Vazirmatn glyphs does not jump.
- **Rendering check:** the specimen ([artifacts/type-specimen.png](artifacts/type-specimen.png)) shows correct shaping and no clipped dots or hamza at these line heights in Chromium. **Flutter rendering on Android and iOS must be re-verified in Phase 4 with golden tests and on devices.**

---

## 5. Accessibility requirements

| Area | Requirement | Verification |
|---|---|---|
| **Contrast** | WCAG 2.1 AA minimum: 4.5:1 text, 3:1 non-text. Primary text targets AAA (7:1). All token pairs are validated by `tools/contrast_check.py` (64/64 pass). New colour pairs must be added to the token file before use. | Script plus a visual check |
| **Text scaling** | Supports OS text scale up to 200% on key flows (Today, inbox, conversation, draft review, approval sheet, order detail, product editor, stock sheet) without loss of content or function. Rows stack at ≥ 1.3; sticky bars wrap or stack their buttons. | Widget tests at 1.0 / 1.3 / 2.0, plus device check |
| **Readable labels** | Plain-language labels; no icon-only actions except back, close, search, more and copy; every field has a visible label (not placeholder-only) | Review |
| **Screen-reader semantics** | Every interactive element has a role, a label and a state. Rows read as one sentence. Badges and provenance captions are part of the value's label. Decorative icons are excluded. Images have descriptions (product name) or are marked decorative. **Known risk:** the availability and quality of Sorani text-to-speech on Android and iOS is unverified. Labels are still provided in Sorani, and pilot testing must check what TalkBack and VoiceOver actually speak. | Accessibility scanner, manual TalkBack and VoiceOver passes |
| **Focus order** | Matches reading order; on open, focus lands on the screen title (or the issues summary on draft review). Sheets trap focus and return it to the trigger on close. | Manual |
| **Keyboard** (tablets, external keyboards) | All actions are reachable; a visible 2 px focus ring; Esc closes overlays; Enter submits valid forms | Manual |
| **Touch targets** | ≥ 48 × 48 dp, with ≥ 8 dp between adjacent targets in action bars | Widget test (tap-target guideline) |
| **Non-colour indicators** | Status, errors, provenance, stock and AI-proposal state always include text and/or an icon. Dashed or dotted strokes are never the only cue. | Review with a greyscale screenshot |
| **Reduced motion** | Honours the OS setting and the in-app setting; spatial motion is replaced by crossfades ([06](06-motion.md)) | Toggle and review |
| **Announcements** | Errors (assertive), loading start and finish for actions > 1 s (polite), success snackbars (polite), status changes (polite: "Order 1042 approved"), offline and online (polite) | Screen-reader pass |
| **Validation messages** | Specific and actionable ("Enter a price above 0", not "Invalid"); placed under the field; announced; focus moves to the first error | Review plus test |
| **Long localized labels** | Forms use labels above fields (never side-by-side on compact screens) so long Sorani labels wrap | Pseudo-localization build |
| **Destructive actions** | Plain-language consequence text, a danger-styled confirm, safe default focus, typed confirmation for account deletion only | Review |
| **Time limits** | None, except the 400 ms input guard on the approval sheet and the snackbar duration, which pauses while focused | Review |

---

## 6. Responsive and localization test matrix

Each key screen (Today, Inbox, Conversation, Draft review, Approve sheet, Order detail, Product list, Product editor, Stock sheet, Store setup) is checked in:

| Dimension | Values |
|---|---|
| Window | 320×568 (compact-small), 360×640, 390×844, 430×932, 768×1024 (medium portrait), 1024×768 (expanded), 1280×800 (large) |
| Locale and direction | `en` LTR, `ckb` RTL, pseudo-long English, pseudo-RTL |
| Text scale | 1.0, 1.3, 2.0 |
| Theme | Light, dark |
| Motion | Normal, reduced |
| Digits (ckb) | Western, Eastern |

A full cross product is not required. Phase 4 automates golden tests for the 10 screens × {en, ckb} × {light, dark} × {1.0, 2.0} at 390×844, plus targeted checks at the other sizes.

---

## 7. Test cases

### 7.1 Localization and RTL (L10N)
| ID | Case | Expected |
|---|---|---|
| L10N-01 | Switch the app language en → ckb on Order detail | Layout mirrors immediately; same screen and scroll position; no untranslated strings |
| L10N-02 | Product named "Beige Abaya — Size M" shown in a Sorani UI | Name renders LTR as one run; the dash and "M" stay in place; no punctuation jumps |
| L10N-03 | Sorani customer message shown in an English UI | Bubble text RTL, right-aligned within the bubble; the bubble itself sits on the customer side (start, left) |
| L10N-04 | Phone `+964 750 123 4567` in a Sorani row | Rendered exactly in that order, on one line |
| L10N-05 | Order number in a Sorani title ("داواکاری #1042") | "#1042" reads as one LTR run; the title order is correct |
| L10N-06 | Type `٣٥٠٠٠` in the price field | Accepted; saved as 35000; displayed per the digit setting |
| L10N-07 | Eastern-digit setting on; open Today and Order detail | Amounts and counts use ٠–٩ with `٬`; phones and order numbers stay Western |
| L10N-08 | Back gesture and back button in RTL on Android and iOS | Back sits at the right; swipe from the right edge on iOS (verify platform behaviour) |
| L10N-09 | Progress tracker and stepper in RTL | Fill right → left |
| L10N-10 | Long Sorani labels with pseudo +40% | No clipping; buttons wrap or stack; rows stack |
| L10N-11 | System widgets in ckb (text-selection menu, any date and time UI, back tooltips) | Sorani strings, not English (requires the custom delegates if they are missing) |
| L10N-12 | Relative and absolute dates in ckb | Localized month names and relative phrases, as approved by the native reviewer |
| L10N-13 | Range "1–2 days" in a Sorani suggested reply or delivery-time text | Reads correctly per DD-06 |
| L10N-14 | Suggested reply in Sorani containing an English product name and a price | Correct order and isolation; price LTR |

### 7.2 Accessibility (A11Y)
| ID | Case | Expected |
|---|---|---|
| A11Y-01 | TalkBack or VoiceOver on Draft review | Reads the screen title, then the issues summary, then fields with provenance; the disabled Approve reads its reason |
| A11Y-02 | Text scale 200% on Draft review and the Approve sheet | All content reachable; totals not truncated; buttons stack |
| A11Y-03 | Greyscale screenshot of the Order list | Every status is distinguishable by text and icon |
| A11Y-04 | Reduced motion on approval | Crossfade only; no scale or number roll; state correct |
| A11Y-05 | Tap-target audit on all P0 screens | All targets ≥ 48 dp |
| A11Y-06 | Submit the product editor with 3 errors | Focus moves to the first error; errors announced; summary banner lists them |
| A11Y-07 | Offline transition while on Inbox | Banner announced politely; disabled actions announce "You're offline" |
| A11Y-08 | External keyboard on a tablet: complete stock adjustment | Possible without touch; focus visible throughout; Esc closes the sheet |
| A11Y-09 | Sorani screen-reader speech on Android and iOS | Record what is actually spoken; log gaps as known issues (the TTS risk in §5) |

### 7.3 Visual acceptance checks per language
For every screen, in both `en` and `ckb`:
1. Mirrored layout matches §2.1.
2. No physical-direction leftovers (icons pointing the wrong way, misaligned dividers or insets).
3. Arabic-script line heights show no clipped dots or diacritics.
4. Numbers, phones and order numbers isolated correctly.
5. No text truncation of prices or actions.
6. Same visual hierarchy in both languages (the Sorani screen must not look heavier or more cramped).
