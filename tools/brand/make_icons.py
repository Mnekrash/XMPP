"""Generates the app icon and launch logo (working brand; replace when the final brand is chosen).

Design: blue diagonal gradient, white rounded speech bubble with a tail, blue padlock inside.
Run: python tools/brand/make_icons.py   (needs Pillow)
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "ios", "App", "Resources", "Assets.xcassets")
TOP, BOTTOM, LOCK = (64, 153, 255), (23, 84, 209), (23, 84, 209)


def gradient(size):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    return img


def glyph(draw, s, ox=0, oy=0):
    """Bubble + padlock drawn in an s×s box."""
    bx0, by0, bx1, by1 = ox + s * 0.19, oy + s * 0.23, ox + s * 0.81, oy + s * 0.68
    draw.rounded_rectangle([bx0, by0, bx1, by1], radius=(by1 - by0) * 0.42, fill="white")
    draw.polygon([(ox + s * 0.30, by1 - 2), (ox + s * 0.24, oy + s * 0.80), (ox + s * 0.44, by1 - 2)], fill="white")
    cx, cy = ox + s * 0.50, oy + s * 0.47
    w, h = s * 0.17, s * 0.125
    body_top = cy - h / 2 + s * 0.02
    # Shackle: an outer rounded rectangle in the lock colour with a white inner cut-out, then the body on top.
    sw, so = w * 0.66, s * 0.026
    draw.rounded_rectangle([cx - sw / 2, body_top - s * 0.10, cx + sw / 2, body_top + s * 0.03], radius=sw / 2, fill=LOCK)
    draw.rounded_rectangle([cx - sw / 2 + so, body_top - s * 0.10 + so, cx + sw / 2 - so, body_top + s * 0.03],
                           radius=sw / 2 - so, fill="white")
    draw.rounded_rectangle([cx - w / 2, body_top, cx + w / 2, body_top + h], radius=s * 0.022, fill=LOCK)


def app_icon():
    big = 2048
    img = gradient(big)
    glyph(ImageDraw.Draw(img), big)
    img.resize((1024, 1024), Image.LANCZOS).save(os.path.join(ROOT, "AppIcon.appiconset", "AppIcon-1024.png"))


def launch_logo():
    for scale in (2, 3):
        pt = 104
        big = pt * scale * 4
        tile = gradient(big).convert("RGBA")
        mask = Image.new("L", (big, big), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=big * 0.28, fill=255)
        tile.putalpha(mask)
        glyph(ImageDraw.Draw(tile), big)
        tile.resize((pt * scale, pt * scale), Image.LANCZOS).save(
            os.path.join(ROOT, "LaunchLogo.imageset", f"LaunchLogo@{scale}x.png"))


if __name__ == "__main__":
    app_icon()
    launch_logo()
    print("icons written to", os.path.abspath(ROOT))
