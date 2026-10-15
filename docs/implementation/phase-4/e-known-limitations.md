# E. Known limitations, deviations and deferred work

## 1. Not verified in this environment

| Item | Impact | What is needed |
|---|---|---|
| No build or run on Android or iOS | Platform issues (fonts, predictive back, keyboard insets, status-bar padding under the DEV pill) are unobserved | An environment with the Android SDK and a device or emulator; a Mac with Xcode for iOS (R0 items in the Phase 3 roadmap) |
| No screen-reader pass on hardware | Semantics are tested in widget tests only | A TalkBack and VoiceOver pass on the draft review and Today |
| No performance profiling | The motion budget (Phase 2 §06 §11) is unmeasured | A profile-mode run on a mid-range Android phone |
| Sorani strings are machine-drafted | Wording may be unnatural or wrong | Native review (DD-04). `app_ckb.arb` is marked `@@x-review-status` |

## 2. Deviations from the Phase 3 architecture

| Phase 3 says | Phase 4 does | Why | When it is resolved |
|---|---|---|---|
| Flavors `dev` / `staging` / `prod` with separate app IDs (§12) | One app ID `app.aisellia`; the environment comes from `--dart-define` | Flavors need the owner's domain (AD-10) and a buildable Android and iOS toolchain to verify; configuring them blind risks broken native projects | Phase 5, once AD-10 is decided and a build environment exists |
| `features/*/{domain,data,application,presentation}` | `data/` (sample and not-connected repositories plus providers) and `presentation/` only | Phase 4 has no mutations or business rules, so empty layers would be ceremony | Phase 5: `domain/` and `application/` arrive with the first real use case |
| `presentation/` never imports `data/` | `presentation/` imports **its own feature's** `data/` provider file; cross-feature `data/` imports are still blocked | Providers currently live next to the repositories | Phase 5 moves providers to `application/` and restores the strict rule in `tool/check_imports.dart` |
| `core/backend`, `errors`, `mutation`, `session`, `connectivity`, `logging` | Not created | No backend, auth or monitoring in Phase 4 (prohibited) | Phase 5+ |
| DTOs with `freezed` / `json_serializable` | Plain immutable classes | No serialization yet | With the first API contract |
| `design_system/patterns/` | Patterns are components in `components/feedback.dart` | See [B §4](b-design-system-mapping.md#4-patterns) | When offline and refresh wrappers are needed |
| Seven ThemeExtensions | Two (palette, typography) plus constants | See [B §1](b-design-system-mapping.md#1-tokens) | No change planned |
| CI grep for hard-coded user-facing strings | Not implemented; no CI exists yet | — | With the CI pipeline (Phase 5) |
| "Still working…" message at 10 s for slow requests (§13) | Not implemented: sample repositories are instant and there is no network | — | With the first real repository |
| Roadmap R1 includes a Supabase repository skeleton (empty schema, RLS and privilege baseline, `require_*` helpers, negative-test harness) | Not created | The Phase 4 instruction excludes database and backend work | Phase 5 (R2 depends on it), with owner authorization |
| Roadmap R1 includes CI stages 1–5 | No CI workflow yet; the same gates run locally and are documented in [D §1](d-test-results.md#1-gates-all-run-before-each-commit) | Adding GitHub Actions workflows was not requested, and workflows run on the owner's account | Proposed first task of Phase 5: one workflow running format, analyze, the three tool checks, tests and goldens on Linux |
| Goldens for every screen in every state | 19 representative goldens; loading, error and offline goldens are not yet generated (they are covered by widget tests) | The scope is representative screens | Grows with each real screen |

## 3. Product and design gaps in the current screens

- **The draft review is a preview.**
  - It is not a real order screen. Editing fields, the approve transaction, stock reservation and the ink settle on a real approval all need the backend.
  - The ink settle is shown only in the gallery, labelled "motion preview — not a real approval".
- **Inbox and Orders** are honest "not available yet" states. Conversations, the order list and order detail come in later phases.
- **Products:** the list, search and filters work on sample data. Product detail and add/edit are deferred screens; "Add product" reports honestly that nothing was created.
- **Store menu:** apart from Language and display and Licences, every row opens a "not available yet" screen.
- **Material and Cupertino `ckb` strings** for date and time pickers, the full calendar and other unused widgets remain English. They must be translated before any picker ships.
- **Sorani month names** are provisional (DD-09).
- **Icons:** the Phosphor subset is provisional (DD-05). New icons need `tool/icons/subset_phosphor.py`.
- **App icon and splash** are still the Flutter defaults; brand assets are not part of Phase 4.
- **At 200% text on short phones**, the draft review's sticky action area (reason line plus stacked buttons) takes about half the screen. The content still scrolls and nothing is lost (spec-compliant), but a device check should confirm it is acceptable. A possible refinement is to make the action bar non-sticky above 1.5× text.
- **Mixed-direction product names** in an English list wrap within an LTR paragraph (each name is FSI-isolated). This is correct per Unicode, but very long Sorani names in English UI may look unusual. Native-speaker review is recommended.

## 4. Environment constraints encountered

- `dl.google.com` is blocked, so the Android SDK cannot be installed.
- There is no KVM and no GTK, so no Android emulator and no Linux desktop build.
- There is no macOS, so no iOS build.
- `flutter` runs as root here and prints a warning. This is harmless.
