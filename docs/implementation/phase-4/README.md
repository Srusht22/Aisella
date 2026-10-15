# Aisellia — Phase 4: Flutter foundation, design system, shell and motion

**Status:** Complete. **Pending owner approval** before Phase 5.
**Baselines:**
- [Phase 1 product spec](../../product/phase-1-product-specification.md): D-01–D-15 pending.
- [Phase 2 design spec](../../design/phase-2/README.md): DD-01–DD-13 pending.
- [Phase 3 architecture](../../architecture/phase-3/README.md): AD-01–AD-12 pending.

All three are used as the working baseline.

Phase 4 delivers a runnable Flutter application. It contains no backend, authentication, AI, messaging, billing or deployment. Every screen that would need those either shows clearly labelled **sample data** or says honestly that the feature is not available yet.

| # | Document | Contents |
|---|---|---|
| A | [Foundation report](a-foundation-report.md) | What was built, project layout, dependencies, configuration, how to run |
| B | [Design-system mapping](b-design-system-mapping.md) | Phase 2 tokens, components, patterns and motion → code |
| C | [Localization, RTL and responsive behaviour](c-localization-and-responsive.md) | Sorani/English, custom `ckb` delegates, bidi, digits, breakpoints, text scaling |
| D | [Test results and visual review](d-test-results.md) | Exact commands and results, coverage, golden review findings and fixes |
| E | [Known limitations](e-known-limitations.md) | What is not done, not verified or deviates from Phase 3, and why |
| F | [Completion report](f-phase-4-completion-report.md) | Summary, commits, decisions needed, readiness for Phase 5 |

## Quick start

```sh
flutter pub get
flutter run --dart-define-from-file=config/dev.example.json   # sample data, DEV pill
flutter test                                                  # 58 unit/widget + 19 golden tests
dart run tool/gen_tokens.dart --check                         # tokens.g.dart is current
dart run tool/check_imports.dart                              # layer boundaries
dart run tool/check_directional.dart                          # no physical left/right geometry
```

The toolchain is Flutter 3.47.7 (stable) with Dart 3.13.5. `flutter run` on a device or emulator was **not** performed in this environment; see [E](e-known-limitations.md).
