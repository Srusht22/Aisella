#!/usr/bin/env python3
"""Validate Aisellia design-token colour pairs against WCAG 2.1 contrast ratios.

Usage: python3 docs/design/phase-2/tools/contrast_check.py [path/to/aisellia-tokens.json]

Reads `contrastPairs` from the token file and checks each pair in both the
light and dark themes. Exits with status 1 if any pair is below its minimum.
Standard library only; no third-party dependencies.
"""
import json
import pathlib
import sys

DEFAULT = pathlib.Path(__file__).resolve().parent.parent / "tokens" / "aisellia-tokens.json"


def luminance(hex_colour: str) -> float:
    h = hex_colour.lstrip("#")
    channels = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    lin = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def ratio(a: str, b: str) -> float:
    hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def main() -> int:
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    tokens = json.loads(path.read_text(encoding="utf-8"))
    failures = 0
    for theme, palette in tokens["color"].items():
        print(f"\n== {theme} ==")
        for pair in tokens["contrastPairs"]:
            fg, bg = palette[pair["fg"]], palette[pair["bg"]]
            r = ratio(fg, bg)
            ok = r >= pair["min"]
            failures += not ok
            print(f"{'PASS' if ok else 'FAIL'}  {r:5.2f} (min {pair['min']:.1f})  "
                  f"{pair['fg']:<22} on {pair['bg']:<20} {pair['use']}")
    print(f"\n{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
