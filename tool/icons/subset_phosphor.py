#!/usr/bin/env python3
"""Rebuilds the Phosphor icon-font subsets and codepoint map.

Requires: python3 with fontTools (`pip install fonttools`), and the npm package
`@phosphor-icons/web` 2.1.2 unpacked somewhere (npm pack @phosphor-icons/web).

    python3 tool/icons/subset_phosphor.py <path-to-unpacked-package>

Then regenerate lib/design_system/icons/app_icons.dart from
tool/icons/phosphor_codepoints.json (see tool/icons/README.md).
"""
import json
import pathlib
import re
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

# Keep in sync with Phase 2 §6 (core icon set) plus shell needs.
ICONS = """house chats-circle receipt package plus minus magnifying-glass funnel-simple
dots-three x caret-left caret-right caret-down caret-up arrow-left arrow-right copy
pencil-simple trash archive camera image image-broken arrow-clockwise check seal-check
check-circle warning-circle warning x-circle prohibit truck arrow-u-up-left flask
chat-text book-open gear question user-circle storefront phone map-pin money trend-down
clock-counter-clockwise cloud-slash info translate circle-half flag download-simple
sign-out users scales lock-key wrench sparkle""".split()

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main(pkg: str) -> None:
    pkg_dir = pathlib.Path(pkg) / "package" / "src"
    out = {}
    for weight, sub, fname, prefix in [
        ("regular", "regular", "Phosphor", r"\.ph"),
        ("fill", "fill", "Phosphor-Fill", r"\.ph-fill"),
    ]:
        css = (pkg_dir / sub / "style.css").read_text()
        cps = {}
        for name in ICONS:
            m = re.search(prefix + r"\.ph-" + re.escape(name) + r':before\s*\{\s*content:\s*"\\([0-9a-fA-F]+)"', css)
            if not m:
                sys.exit(f"missing {weight} icon {name}")
            cps[name] = int(m.group(1), 16)
        opts = subset.Options()
        opts.layout_features = ["*"]
        opts.notdef_outline = True
        opts.name_IDs = ["*"]
        font = TTFont(pkg_dir / sub / f"{fname}.ttf")
        s = subset.Subsetter(opts)
        s.populate(unicodes=list(cps.values()))
        s.subset(font)
        font.save(ROOT / "assets/fonts/phosphor" / f"{fname}-subset.ttf")
        out[weight] = cps
    (ROOT / "tool/icons/phosphor_codepoints.json").write_text(json.dumps(out, indent=1))
    print({k: len(v) for k, v in out.items()})


if __name__ == "__main__":
    main(sys.argv[1])
