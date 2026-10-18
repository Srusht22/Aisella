#!/usr/bin/env python3
"""Renders the Aisellia app icon (bag with a check) into every platform file.

    python3 tool/icons/render_app_icon.py

Same geometry as AppLogo (lib/design_system/brand/app_logo.dart), in a
100-unit box. Drawn 4x larger and scaled down for clean edges.
"""
import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOP = (0x2C, 0x4F, 0xA6)     # brand indigo, lifted
BOTTOM = (0x16, 0x2C, 0x66)  # brand indigo, deepened
CUT = (0x1F, 0x3F, 0x8F)     # check colour = brand
INK = (255, 255, 255)


def gradient(size):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
    return img


# Bag outline before rounding: slanted sides (wider at the bottom) read as a
# shopping bag, not a padlock. Corners are rounded by stroking the polygon
# with a round join of radius ROUND.
BAG = [(33, 41), (67, 41), (72, 77), (28, 77)]
ROUND = 5
HANDLE = (40, 25, 60, 45)  # circle box; the top half is drawn
CHECK = [(39, 60), (47, 68), (62, 53)]


def glyph(draw, ox, oy, u):
    def p(x, y):
        return (ox + x * u, oy + y * u)

    pts = [p(*q) for q in BAG]
    r = ROUND * u
    draw.polygon(pts, fill=INK)
    draw.line(pts + [pts[0]], fill=INK, width=round(2 * r), joint="curve")
    for cx, cy in pts:
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=INK)
    w = round(4.5 * u)
    (x0, y0), (x1, y1) = p(HANDLE[0], HANDLE[1]), p(HANDLE[2], HANDLE[3])
    # PIL strokes arcs inside their box: grow it by half the stroke.
    draw.arc([x0 - w / 2, y0 - w / 2, x1 + w / 2, y1 + w / 2], 180, 360, fill=INK, width=w)
    for x in (HANDLE[0], HANDLE[2]):
        draw.line([p(x, 35), p(x, 40)], fill=INK, width=w)
    cw = round(6 * u)
    c = [p(*q) for q in CHECK]
    draw.line(c, fill=CUT, width=cw, joint="curve")
    for cx, cy in (c[0], c[2]):
        draw.ellipse([cx - cw / 2, cy - cw / 2, cx + cw / 2, cy + cw / 2], fill=CUT)


def render(size, *, rounded, scale=1.0):
    """rounded: transparent corners (web, Android); else full-bleed (iOS,
    maskable). scale shrinks the glyph inside a full-bleed tile."""
    big = size * 4
    bg = gradient(big).convert("RGBA")
    if rounded:
        mask = Image.new("L", (big, big), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=big * 0.28, fill=255)
        bg.putalpha(mask)
    d = ImageDraw.Draw(bg)
    u = big / 100 * scale
    off = (big - 100 * u) / 2
    glyph(d, off, off, u)
    return bg.resize((size, size), Image.LANCZOS)


def main():
    out = {
        "web/favicon.png": (32, True, 1.0),
        "web/icons/Icon-192.png": (192, True, 1.0),
        "web/icons/Icon-512.png": (512, True, 1.0),
        "web/icons/Icon-maskable-192.png": (192, False, 0.72),
        "web/icons/Icon-maskable-512.png": (512, False, 0.72),
    }
    for d, s in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        out[f"android/app/src/main/res/mipmap-{d}/ic_launcher.png"] = (s, True, 1.0)
    ios = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for f in ios.glob("*.png"):
        out[str(f.relative_to(ROOT))] = (Image.open(f).size[0], False, 0.86)
    for path, (size, rounded, scale) in out.items():
        img = render(size, rounded=rounded, scale=scale)
        if not rounded:
            img = img.convert("RGB")  # iOS icons must have no alpha
        img.save(ROOT / path)
        print(path, size)


if __name__ == "__main__":
    main()
