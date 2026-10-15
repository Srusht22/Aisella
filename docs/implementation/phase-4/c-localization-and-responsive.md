# C. Localization, RTL and responsive behaviour

## 1. Languages

| Locale | Direction | Status |
|---|---|---|
| `ckb` (Kurdish Sorani) | RTL | Primary. All 136 keys translated. **Machine-drafted; native review is pending (DD-04)**, marked `@@x-review-status` in `app_ckb.arb` |
| `en` | LTR | Complete; it is the template ARB, and every key has a description |
| `ar` | RTL | Not shipped. Adding `app_ar.arb` is enough: the Global delegates already cover Arabic |

- On first launch the device locale is used as a *suggestion*: `ckb` or `ku` → Sorani, `en` → English, anything else → Sorani.
- The language screen is bilingual and previews the selected language live before Continue.
- The choice is stored, and can be changed later in Store → Language and display. The change applies instantly, including the text direction (tested).

## 2. Verified gap: Flutter has no `ckb` localizations

This was checked on Flutter 3.47.7 and intl 0.20.3:
- `GlobalMaterialLocalizations`, `GlobalCupertinoLocalizations` and `GlobalWidgetsLocalizations` do not support `ckb`;
- intl has no `ckb` date or number data.

Without custom delegates, a `ckb` app would fall back to LTR with English system strings. `core/l10n/ckb_localizations.dart` therefore provides:

| Delegate | Behaviour |
|---|---|
| `CkbWidgetsLocalizations` | Complete and **RTL**, covering all 16 strings |
| `CkbMaterialLocalizations` | Extends the English Material bundle and overrides every string reachable from the current UI in Sorani (back, close, menus, text-selection toolbar, sheets, dialogs, search, licences, and so on). It uses Arabic-script `scriptCategory` (tall) and Saturday as the first day of the week |
| `CkbCupertinoLocalizations` | Same approach for Cupertino (text-selection toolbar and similar) |

Delegate order is: `AppLocalizations`, then the three ckb delegates, then the Global delegates.

**Bug found and fixed in this phase:** the ckb delegates build English `DateFormat`s, but intl's date data is loaded only by the Global delegates, which never run for `ckb`. A cold start in Sorani threw `LocaleDataException`. The delegates now load intl's local date data themselves; this is idempotent and synchronous. The bug was caught by the Sorani widget test.

**Remaining gap:** strings in widgets Phase 4 does not use (date and time pickers, the full calendar) stay English. These must be translated before any date picker ships (see [E](e-known-limitations.md)).

## 3. Bidi, digits, money, phones, dates (`core/formatting`)

| Concern | Rule (Phase 2 §07, DD-07) | Implementation |
|---|---|---|
| Mixed-direction content | User and customer text is isolated so it cannot reorder its surroundings | `Bidi.auto()` wraps text in FSI…PDI (first-strong direction) |
| Always-LTR values | Phone numbers, order numbers and amounts are isolated LTR | `Bidi.ltr()` wraps in LRI…PDI |
| Literal control characters | Never typed literally in source | A test scans `lib`, `test` and `tool` for literal U+202A–E and U+2066–9; `\u` escapes only |
| Digits | Western by default; Eastern Arabic is optional in settings | `Digits.display()`, `Digits.normalize()` (accepts Western, Eastern Arabic and Persian digits on input) |
| Phones | **Always Western digits**, `+964 750 123 4567` | `PhoneNumbers.normalizeIraqMobile()` → E.164, or null; `display()` |
| Money | `35,000 IQD` (en), `35,000 د.ع` (ckb), `$25`; whole units | `Money.format()`; the number is LTR-isolated |
| Dates | Weekday, day and month in the UI language | `Dates.weekdayDayMonth()` with English and Sorani month names (Sorani names pending DD-09) |
| Section labels | English overlines are uppercase and tracked; Sorani is never uppercased or tracked | `AppTypography.overlineText()`; tested |

The RTL test results:
- the layout mirrors;
- directional icons mirror, and object icons do not;
- text uses `start` and `end` alignment;
- **`tool/check_directional.dart` rejects physical left/right geometry in `lib/`**.

## 4. Responsive layout

| Window class (`WindowClass`) | Width | Navigation | Content |
|---|---|---|---|
| compactSmall | < 360 dp wide **or** < 640 dp tall | Bottom bar | Single column, 12 dp gutter; field rows stack below 360 dp |
| compact | 360–599 | Bottom bar | Single column, 16 dp gutter |
| medium | 600–839 | **Rail** | Centred column (`ContentWidth`), 24 dp gutter |
| expanded | 840–1199 | Rail | Today uses two columns; sheets become dialogs; 24 dp gutter |
| large | ≥ 1200 | Rail | As expanded, 32 dp gutter |

- The large page title is a content row inside `ContentWidth`, so it aligns with the content column on tablets.
- The compact pinned title and store button use the same inset. Material's large app bar fixes its title at 16 dp, which the visual review showed misaligned on tablets.
- Each tab keeps its own navigation stack. Re-selecting the active tab returns to its root. System back on a non-Today tab root goes to Today.

## 5. Text scaling and accessibility

- Key flows are tested at 200% text in both languages on 320–360 dp phones with the real fonts, with no overflow (widget tests and goldens).
- At text scale ≥ 1.3:
  - `FieldRow` and `NavRow` stack their value under the label;
  - `StickyActionBar` stacks its buttons with the primary on top.
- Navigation bar and rail labels cap their text scale at 1.3. Labels always sit next to an icon and are announced in full by screen readers. Page content is never clamped.
- The Sorani Orders tab label is "داواکاری". The page title keeps "داواکارییەکان".
- Touch targets are at least 48 dp (tested with `androidTapTargetGuideline`).
- Semantics:
  - large titles are headers;
  - disabled buttons report a disabled state;
  - danger banners are live regions;
  - status badges always have text, never colour alone;
  - the compact title copy is excluded from semantics to avoid announcing the title twice.
- Reduced motion: see [B §5](b-design-system-mapping.md#5-motion-phase-2-06).
