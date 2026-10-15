#!/usr/bin/env python3
"""Generates lib/design_system/icons/app_icons.dart from phosphor_codepoints.json.

    python3 tool/icons/gen_app_icons.py && dart format lib/design_system/icons

Directional icons (MIRRORED) set matchTextDirection so they flip in RTL
(Phase 2 07 §2); every other icon is a real-world object and never mirrors.
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIRRORED = {"caret-left", "caret-right", "arrow-left", "arrow-right", "arrow-u-up-left", "sign-out"}

HEADER = """// GENERATED from the Phosphor icon subset (tool/icons/README.md). Do not edit by hand.
// Phosphor Icons, MIT licence (assets/fonts/phosphor/LICENSE.txt).
//
// Regular weight is the default; Fill is used only for active navigation and
// selected toggles (Phase 2 §6). Directional icons set matchTextDirection so
// they mirror automatically in RTL; real-object icons never mirror.
import 'package:flutter/widgets.dart';

abstract final class AppIcons {
"""


def camel(name: str) -> str:
    head, *rest = name.split("-")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)


def main() -> None:
    cps = json.loads((ROOT / "tool/icons/phosphor_codepoints.json").read_text())
    out = [HEADER]
    for index, (weight, family, suffix) in enumerate([("regular", "PhosphorRegular", ""), ("fill", "PhosphorFill", "Fill")]):
        if index:
            out.append("\n")
        for name, cp in cps[weight].items():
            out.append(
                f"  static const IconData {camel(name)}{suffix} = IconData(\n"
                f"    0x{cp:x},\n"
                f"    fontFamily: '{family}',\n"
                f"    matchTextDirection: {'true' if name in MIRRORED else 'false'},\n"
                f"  );\n"
            )
    out.append("}\n")
    (ROOT / "lib/design_system/icons/app_icons.dart").write_text("".join(out))


if __name__ == "__main__":
    main()
