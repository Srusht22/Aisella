#!/usr/bin/env python3
"""Renders the Aisellia app icon (the "A" mark with a spark) into every platform file.

    python3 tool/icons/render_app_icon.py

Same geometry as AppLogo (lib/design_system/brand/app_logo.dart), in a
100-unit box. Drawn 4x larger and scaled down for clean edges.
"""
import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOP = (0x2C, 0x4F, 0xA6)     # brand indigo, lifted
BOTTOM = (0x16, 0x2C, 0x66)  # brand indigo, deepened
INK = (255, 255, 255)


def gradient(size):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
    return img


A_LEGS = [(28, 77), (50, 25), (72, 77)]
A_STROKE = 11
SPARKS = [((50, 61), 8.5), ((73, 25), 5.5)]


def spark_points(cx, cy, r, steps=24):
    """Four-point star with pinched sides (quadratic curves, as in the app)."""
    k = r * 0.22
    corners = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
    controls = [(cx + k, cy - k), (cx + k, cy + k), (cx - k, cy + k), (cx - k, cy - k)]
    pts = []
    for i in range(4):
        (x0, y0), (x2, y2), (x1, y1) = corners[i], corners[(i + 1) % 4], controls[i]
        for s in range(steps):
            t = s / steps
            pts.append(((1 - t) ** 2 * x0 + 2 * (1 - t) * t * x1 + t * t * x2,
                        (1 - t) ** 2 * y0 + 2 * (1 - t) * t * y1 + t * t * y2))
    return pts


def glyph(draw, ox, oy, u):
    def p(x, y):
        return (ox + x * u, oy + y * u)

    w = round(A_STROKE * u)
    legs = [p(*q) for q in A_LEGS]
    draw.line(legs, fill=INK, width=w, joint="curve")
    for cx, cy in legs:
        draw.ellipse([cx - w / 2, cy - w / 2, cx + w / 2, cy + w / 2], fill=INK)
    for (x, y), r in SPARKS:
        cx, cy = p(x, y)
        draw.polygon(spark_points(cx, cy, r * u), fill=INK)


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
