# Icon font subset

**Phase 2 decision DD-05 (pending owner approval): vendor a curated Phosphor subset.** This is implemented provisionally in Phase 4.

The `phosphor_flutter` package was last published on 2024-05-10, so instead of depending on it the app bundles a subset of the official Phosphor icon fonts:

- **Source:** the npm package `@phosphor-icons/web` 2.1.2. It is MIT-licensed; the licence ships at `assets/fonts/phosphor/LICENSE.txt`.
- **Fonts:** about 15 KB each:
  - `Phosphor-subset.ttf` (Regular weight)
  - `Phosphor-Fill-subset.ttf` (Fill weight)
- **Constants:** `lib/design_system/icons/app_icons.dart`. Directional icons set `matchTextDirection: true`, so they mirror automatically in RTL.

## Adding an icon

1. Add the icon's name to `ICONS` in `subset_phosphor.py`.
2. Run the script against the unpacked npm package:
   ```
   python3 tool/icons/subset_phosphor.py <path>
   ```
3. Regenerate the constants: `python3 tool/icons/gen_app_icons.py && dart format lib/design_system/icons`.
4. If the new icon is directional, add it to `MIRRORED` in `gen_app_icons.py` (Phase 2 [07 §2](../../docs/design/phase-2/07-localization-and-accessibility.md#2-rtl-layout-rules)).
