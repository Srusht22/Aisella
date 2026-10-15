# F. Phase 4 completion report

**Phase:** 4. Flutter foundation, premium design system, app shell and motion infrastructure (roadmap milestone R1, Flutter part).
**Status:** Complete. **Waiting for owner approval. Phase 5 has not started.**
**Branch:** `S.H_Branch`.

## 1. Summary

Aisellia now has a runnable Flutter application that implements the Phase 2 design system and the Phase 3 client architecture:
- tokens are generated from the design JSON;
- light and dark themes, and Inter plus Vazirmatn NL typography;
- about 30 components and motion primitives that respect reduced motion;
- a responsive shell (bottom bar on phones, rail on tablets) with per-tab stacks;
- Sorani-first localization with custom `ckb` delegates that Flutter lacks;
- representative screens.

The app stays honest:
- sample data is always labelled;
- without sample data, screens say "No store connected yet";
- nothing can be approved, sent, stored or deducted.

Quality evidence (details in [D](d-test-results.md)):
- **58 unit and widget tests plus 19 goldens pass**;
- `flutter analyze` reports no issues;
- token, import-boundary and RTL-geometry checks pass;
- line coverage is 89.4% overall and 98.3% for `core/formatting`;
- a release-mode compile succeeded (as a web build in a scratch copy).

The visual review of the goldens found 12 issues, including a real crash on a cold start in Sorani. All 12 are fixed.

## 2. Commits

| Commit | Message |
|---|---|
| `77ae1a8` | feat(flutter): foundation, design system, shell and representative screens |
| `c5566c7` | test(flutter): unit and widget tests for foundation, navigation and screens |
| `22b1c19` | fix(ui): visual review fixes and golden screenshots |
| `10b04e9` | chore(flutter): RTL geometry check and production-only routes |
| `e306474` | test(flutter): assert no screen renders an unbundled icon font |
| *(this commit)* | docs(phase-4): foundation, design-system mapping, localization, test results, limitations and completion report |

Each commit was validated before it was pushed. Each push was verified by fetching and comparing the local and remote hashes.

## 3. Scope check against the Phase 4 instructions

| Requirement | Result |
|---|---|
| Runnable Flutter foundation following the Phase 3 architecture | ✅ ([A](a-foundation-report.md)); deviations listed in [E §2](e-known-limitations.md#2-deviations-from-the-phase-3-architecture) |
| Design tokens, themes, typography, reusable components | ✅ ([B](b-design-system-mapping.md)) |
| Responsive shell and navigation | ✅ (bottom bar < 600 dp, rail ≥ 600 dp; tested at 4 sizes) |
| Localization and RTL | ✅ ([C](c-localization-and-responsive.md)); Sorani wording pending native review |
| Motion with reduced-motion support | ✅ (single source: app setting or OS; tested) |
| Representative screens on honest sample data | ✅ (Language, Today, Products, Draft review preview, Store, Language and display) |
| Loading, empty and error patterns | ✅ (skeleton after 300 ms, empty states, error state with Retry) |
| Tests and visual review | ✅ ([D](d-test-results.md)) |
| No fake login, approval, stock deduction, delivery or AI | ✅ (asserted by tests) |
| No production auth, database, AI, messaging, billing or deployment | ✅ (no such code or dependencies) |
| No unnecessary dependencies | ✅ (4 runtime packages plus SDK localizations) |
| No secrets committed | ✅ (only `config/dev.example.json`; real config is git-ignored; files scanned before each commit) |
| Device builds | ❌ **Not possible here** (no Android SDK or iOS toolchain); see [E §1](e-known-limitations.md#1-not-verified-in-this-environment) |

## 4. Decisions and inputs needed from the owner

| ID | Decision | Needed by |
|---|---|---|
| **AD-10** | Domain and final app identifiers (`app.aisellia` is provisional); then flavors `dev` / `staging` / `prod` | Flavors (Phase 5) and the first store upload |
| **DD-04** | Native Sorani review of `app_ckb.arb` (136 strings plus system strings in `ckb_localizations.dart`) | Before any user testing |
| **DD-05** | Confirm the Phosphor icon set (vendored subset) | Before more icons are added |
| **DD-09** | Sorani month names and date style | Before dates matter in orders |
| Build environment | Android SDK and a device or emulator; macOS with Xcode for iOS (R0) | To verify on real devices |
| CI | Approval to add a GitHub Actions workflow running the documented gates | Start of Phase 5 |
| Deviations | Accept the deviations in [E §2](e-known-limitations.md#2-deviations-from-the-phase-3-architecture) (layering, flavors deferral, patterns folder, theme extensions) | Phase 5 planning |
| Brand assets | App icon and splash (Flutter defaults today) | Before any external build |

Phase 1, 2 and 3 decisions (D-01–D-15, DD-01–DD-13, AD-01–AD-12) are still pending and are used as the working baseline.

## 5. Readiness for Phase 5 (R2: auth and store setup)

Ready:
- the shell, router (with a redirect hook for a session gate), settings, formatting, the design system, l10n and the test harness are in place;
- sample repositories can be swapped for real ones through provider overrides without screen changes.

Phase 5 needs:
- owner authorization;
- AD-10 for flavors and identifiers;
- a Supabase project or local stack, with authorization to create it;
- SMTP and domain for auth email (roadmap R2);
- ideally a device build environment.

Proposed first steps:
1. add CI;
2. add the `domain/` and `application/` layers and tighten the import rule;
3. create the Supabase repository skeleton and the RLS baseline deferred from R1;
4. build auth and store setup.

**Phase 5 will not start without explicit approval.**
