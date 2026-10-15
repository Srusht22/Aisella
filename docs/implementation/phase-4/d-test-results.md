# D. Test results and visual review

The commands below were run on 2026-10-15 in the Phase 4 environment: Linux, Flutter 3.47.7, Dart 3.13.5. The results are copied from the terminal output, not estimated.

## 1. Gates (all run before each commit)

| Command | Result |
|---|---|
| `dart format --output=none --set-exit-if-changed lib test tool` | `Formatted 65 files (0 changed)` |
| `flutter analyze` (flutter_lints + strict options) | `No issues found!` |
| `dart run tool/gen_tokens.dart --check` | `lib/design_system/tokens/tokens.g.dart is up to date.` |
| `dart run tool/check_imports.dart` | `Import boundaries OK (51 files).` |
| `dart run tool/check_directional.dart` | `Directional geometry OK (51 files).` |
| `flutter test -x golden` | **58 passed, 0 failed** |
| `flutter test --tags golden` | **19 passed, 0 failed** |

The import and directional checkers were each tested against deliberate violations. The import checker caught a relative design_system → features import, a `package:` design_system → app import, and a cross-feature `data/` import. The directional checker caught `Alignment.centerLeft` and `EdgeInsets.only(left:)`. Both exited 1, and the violations were then removed.

## 2. What the 58 unit and widget tests cover

| File | Tests | Covers |
|---|---|---|
| `test/core/foundation_test.dart` | 18 | `AppConfig`: env parsing, prod with sample data refused. Digits (normalisation and Eastern display), money (IQD, د.ع, USD, isolation), Iraqi phone normalisation and display, bidi isolation, dates (en and ckb), settings persistence and restore, ARB key parity, no literal bidi characters in `ckb` strings |
| `test/app/navigation_test.dart` | 9 | Language gate on first launch; tab switching and selected state; per-tab stacks and re-select to root; system back to Today; store menu → honest deferred screen → back; not-found route; repeated taps don't stack pages; **gallery route absent in prod**; **no screen (including Licences) renders an icon from an unbundled font** |
| `test/app/localization_test.dart` | 5 | Sorani is RTL with Sorani system strings (custom delegate); English is LTR with uppercase overlines; Sorani labels are never uppercased or tracked; switching language flips direction at once; directional icons mirror and object icons don't |
| `test/app/responsive_test.dart` | 7 | 320×568, 390×844 (bottom bar), 768×1024 and 1280×800 (rail): every tab with no overflow; 200% text at 360×640 in en and ckb through to the draft review with no overflow; navigation labels cap at 1.3× while content is not clamped |
| `test/design_system/components_test.dart` | 11 | Button enabled, disabled (semantics) and loading (keeps width, ignores taps); 48 dp target guideline; badges always show icon and text; palette in light and dark; reduced motion from setting or OS; `NumberRoll` animates normally and is instant when reduced; pencil stays dashed until settled and survives interruption; discard dialog defaults to keep; sticky bar stacks at 200% |
| `test/features/screens_test.dart` | 8 | Sample data always labelled; **without sample data Today shows "No store connected yet" and no counts**; product search and filters, and clear filters; empty catalogue plus honest "Add product"; **Approve disabled until the quantity is confirmed**; the reason line scrolls the control into view; **400 ms input guard → "Not connected yet", "Nothing was approved", and the draft stays "Needs approval" (no "Approved" anywhere)**; no literal bidi controls in `lib`, `test` or `tool` |

**Do the honesty tests actually discriminate?** They were checked with temporary mutations:
- making Approve always enabled failed the gating test;
- making the disabled button report "enabled" to semantics failed the semantics test;
- adding a Material icon to the Store menu failed the icon-font test.

Each mutation was reverted afterwards.

## 3. Coverage (`flutter test --coverage -x golden`)

| Area | Lines hit / total | % |
|---|---|---|
| `lib/core/formatting/` | 59 / 60 | **98.3** (the Phase 3 target is ≥ 90) |
| `lib/core/config/` | 18 / 22 | 81.8 |
| `lib/core/settings/` | 43 / 56 | 76.8 (the uncovered lines are the real `SharedPreferences` adapter, which needs a platform channel) |
| `lib/core/l10n/` | 57 / 112 | 50.9 (Material and Cupertino string overrides that no test reads) |
| `lib/design_system/` | 959 / 1014 | 94.6 (the gallery is now exercised by the icon-font test) |
| `lib/features/` | 805 / 835 | 96.4 |
| `lib/` total | 2319 / 2594 | **89.4** |

These figures were measured on the final test set. `coverage/` is git-ignored.

## 4. Release compilation check

No Android SDK or iOS toolchain is available here (see [E](e-known-limitations.md)). As a release-mode compile check, a **scratch copy** of the repository was given a temporary web platform and built:

```
flutter build web --release --dart-define=ENV_NAME=dev --dart-define=SAMPLE_DATA=true
✓ Built build/web   (Phosphor fonts tree-shaken: 15620 → 15128 and 12904 → 12408 bytes)
```

Web is **not** a target platform, and nothing from that copy was committed. The build warned that framework code references the Material and Cupertino icon fonts, which the app does not bundle. Our code uses none of the widgets that draw them. A widget test now opens every reachable screen, including the Licences page, and asserts that only Phosphor glyphs are rendered.

## 5. Visual review (goldens)

`test/goldens/screens_golden_test.dart` renders the real app with the bundled Inter, Vazirmatn NL and Phosphor fonts and real shadows, at 2× pixel density. There are 19 images in `test/goldens/goldens/`:

- language selection;
- Today and Draft review in en and ckb, each in light and dark;
- Products in en and ckb, plus English at 320 dp;
- Language and display in en and ckb;
- tablet (1280×800) Today in en and ckb;
- Draft review full length in ckb;
- Draft review at 200% text in ckb;
- Today at 320 dp with 200% text in ckb.

Every image was inspected. These issues were found and **fixed**:

| # | Finding | Fix |
|---|---|---|
| 1 | Cold start in Sorani threw `LocaleDataException` (found by the RTL widget test) | ckb delegates load intl date data |
| 2 | The DEV corner ribbon covered the store button (top-level screens) and the back button | Replaced by a small top-centre pill that ignores pointers |
| 3 | The Today date subtitle was centred; `ContentWidth` centred narrow children | `ContentWidth` fills its column; children start-align |
| 4 | On tablets the large title sat at 16 dp while content was centred (Material's large app bar fixes the padding) | Large title rendered in `ContentWidth`; compact title and store button use the same inset |
| 5 | The "Needs approval" badge in the app bar truncated "داواکاری #1042" and was itself clipped in English | Badge moved to the top of the body |
| 6 | The inferred-quantity badge repeated "— confirm" next to the Confirm button | Shortened to "Inferred" / "مەزەندەکراوە" |
| 7 | The quantity Confirm control was below the fold while the reason line said to confirm it | The reason line is tappable and scrolls to it (tested) |
| 8 | At 200% the Sorani Orders tab label wrapped and was clipped | Navigation labels capped at 1.3×; Sorani tab label shortened to "داواکاری" with a separate page title key |
| 9 | `NavRow` values could squeeze labels at large text | Values stack under the label at ≥ 1.3 |
| 10 | Products' FAB could hide the last row | List clearance added when a FAB is present |
| 11 | (Regression introduced while fixing 9 and caught on re-review) A flexible trailing value took half the row and wrapped short labels | Trailing value is rigid again; stacking handles large text |
| 12 | The FAB showed a black outline | Test artefact (`debugDisableShadows`); goldens now render real shadows |

Confirmed correct in review:
- RTL mirroring of rows, chevrons, segmented controls, rail position and bottom-bar order (Today rightmost in Sorani);
- money isolation ("420,000 د.ع");
- Western-digit phone numbers;
- Sorani labels not uppercased;
- dark-theme contrast of text and banners;
- the pencil underline and dashed draft border;
- the disabled Approve with its reason;
- sample-data labelling on every sample screen.

**Golden portability:** text antialiasing differs between operating systems. Goldens are tagged `golden` and should be compared on Linux (CI). Use `flutter test -x golden` elsewhere, and regenerate with `--update-goldens` only after reviewing the diff.

## 6. Not run (and why)

| Check | Status |
|---|---|
| `flutter run` on an Android or iOS device or emulator | **Not run**: no Android SDK (dl.google.com blocked), no iOS toolchain, no KVM |
| `flutter build apk` / `ipa` | **Not run**, for the same reason |
| `integration_test` | None yet. Phase 3 defines integration journeys against the local Supabase stack, which arrives in Phase 5 |
| TalkBack, VoiceOver, Switch Access on hardware | **Not run**; semantics are covered by widget tests only |
| Performance profiling (jank, startup) | **Not run**; needs a device in profile mode |
| Native Sorani review of strings | **Pending (DD-04)** |
