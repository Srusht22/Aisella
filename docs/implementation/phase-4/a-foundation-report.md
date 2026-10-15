# A. Foundation report

## 1. What exists

| Area | Delivered |
|---|---|
| Project | Flutter app `aisellia` 0.1.0+1. Android and iOS scaffolds from `flutter create --org app`, application ID `app.aisellia` (provisional, AD-10) |
| Architecture | Phase 3 layout: `app/`, `core/`, `design_system/`, `features/<name>/{data,presentation}`, `l10n/`. Layer boundaries are enforced by `tool/check_imports.dart` |
| State | Riverpod 3 (`Notifier`, `FutureProvider`), hand-written, with no provider code generation |
| Navigation | go_router 18 `StatefulShellRoute.indexedStack` (four tabs with independent stacks), a language gate redirect, a not-found route and honest "deferred feature" routes |
| Design system | Generated tokens, light and dark themes, two-script typography, about 30 components, loading, empty and error patterns, and motion primitives |
| Localization | Sorani (`ckb`, RTL, primary) and English. Custom `ckb` Widgets, Material and Cupertino delegates. Bidi isolation, digit, money, phone and date formatting |
| Screens | Language selection (AU-01), Today (TD-01), Products (PR-01), Inbox and Orders (honest deferred states), Draft review **preview** (OR-02/OR-03), Store menu (ST-01), Language and display (ST-06), Licences, debug component gallery |
| Tests | 58 unit and widget tests plus 19 goldens, all passing (see [D](d-test-results.md)) |
| Tooling | `tool/gen_tokens.dart`, `tool/check_imports.dart`, `tool/check_directional.dart`, `tool/icons/subset_phosphor.py` |

## 2. Project layout

```
lib/
  main.dart                      → bootstrap()
  app/                           bootstrap, App widget, router, shell, environment pill, startup error app
  core/
    config/app_config.dart       AppConfig from --dart-define; prod + sample data refuses to start
    settings/                    KeyValueStore (SharedPreferencesWithCache allow-list), SettingsController
    l10n/                        supported locales, ckb delegates, context.l10n
    formatting/                  bidi, digits, money, phone, dates
  design_system/
    tokens/tokens.g.dart         generated, do not edit
    theme/                       buildAppTheme, AppTypography, context.palette / context.type
    icons/app_icons.dart         Phosphor subset (generated codepoints)
    components/                  buttons, rows, status, pencil, feedback, inputs, overlays, media
    motion/                      MotionScope, Motion.reduced, PressScale, FadeSlideIn, ExpandSection, NumberRoll
    layout/responsive.dart       WindowClass, ContentWidth
    gallery/                     debug-only component gallery (route not registered in prod)
  features/
    common/                      TopLevelPage, DeferredFeatureScreen, NotFoundScreen
    onboarding/ today/ inbox/ orders/ products/ settings/
  l10n/app_en.arb, app_ckb.arb   136 keys, every key described; gen/ is generated and git-ignored
assets/fonts/                    Inter, Vazirmatn NL (OFL), Phosphor subset (MIT) + licence files
config/                          dev.example.json, README.md (real *.json files are git-ignored)
tool/                            generators and checks
test/                            unit, widget, golden (test/goldens/goldens/*.png)
```

## 3. Dependencies

These are the only runtime dependencies. Each one is required by the Phase 3 decisions.

| Package | Resolved | Why |
|---|---|---|
| `flutter_riverpod` | 3.4.3 | State and dependency injection (Phase 3 §4) |
| `go_router` | 18.1.0 | Navigation with per-tab stacks (Phase 3 §5) |
| `shared_preferences` | 2.5.6 | Local display settings only, behind an allow-list (language, digits, theme, motion) |
| `intl` | 0.20.3 (pinned by the SDK) | Date and number formatting used by the localization delegates |
| `flutter_localizations` | SDK | Global delegates for `en` (and later `ar`) |

Dev: `flutter_lints` 6.0.0 plus stricter analyzer options (`strict-casts`, `strict-raw-types`, and about 15 extra rules).

**Not added, deliberately:**
- `supabase_flutter` and `sentry_flutter`: no backend or monitoring in Phase 4.
- `freezed` and `json_serializable`: no DTOs yet.
- `phosphor_flutter`: stale package; a vendored subset is used instead (DD-05).
- `google_fonts`: it fetches fonts at runtime, so the fonts are bundled.

## 4. Configuration and secrets

- `AppConfig` reads `ENV_NAME` and `SAMPLE_DATA` from `--dart-define(-from-file)`:
  - an empty `ENV_NAME` means `dev`;
  - sample data defaults to **on in dev only**;
  - **`prod` with sample data throws at startup** and shows a plain-language error screen instead of the app.
- Non-production builds show a small **DEV / STAGING pill** at the top centre. It ignores pointers.
- `config/*.json` is git-ignored; only `config/dev.example.json` is committed. **No keys, tokens or URLs of any service exist in the repository.** Privileged credentials are never placed in the client (Phase 3 §9).
- Local storage holds display preferences only (four allow-listed keys). It stores no business or personal data.

## 5. Honesty rules as implemented

| Rule | Implementation |
|---|---|
| No fake login | No auth screens. The app opens on language selection, then Today. |
| No fake data presented as real | Sample repositories only when `SAMPLE_DATA` is true. Every sample screen shows a "Sample data" banner. Without sample data, Today says "No store connected yet" and Products shows its first-use empty state. |
| No fake approval, stock deduction or delivery | Draft review is labelled a preview. "Confirm approval" returns **"Not connected yet — Nothing was approved…"**, and the draft stays "Needs approval" with its pencil treatment. Reject says the same. The ink-settle motion is shown only in the gallery, labelled "motion preview — not a real approval". |
| No fake AI | Provenance labels ("From customer", "Inferred") are static sample content. Nothing is generated. |
| Deferred features | The Store menu rows marked "Later release" and the product rows open a "… isn't available yet" screen. Inbox and Orders say so on their tab. |

## 6. How to run

```sh
export PATH=/opt/flutter/bin:$PATH        # in this environment
flutter pub get                            # also runs gen-l10n (lib/l10n/gen, git-ignored)
flutter run --dart-define-from-file=config/dev.example.json
# Without sample data (what a real dev build with no backend shows):
flutter run --dart-define=ENV_NAME=dev --dart-define=SAMPLE_DATA=false
```

After editing `docs/design/phase-2/tokens/aisellia-tokens.json`, run `dart run tool/gen_tokens.dart` to regenerate the tokens. After adding icons, follow `tool/icons/README.md`.
