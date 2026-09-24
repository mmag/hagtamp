#!/usr/bin/env python3
"""Draws Hagtamp's logo as pixel art and builds the app icon from it.

The logo is a gold "H" with a lightning bolt across its bar, over a
bevelled silver diamond. It is drawn here pixel by pixel (no scaling or
anti-aliasing), in two sizes:

- art/logo-46.png: the full logo, for icon sizes 64-1024 (scaled x1-x16);
- art/logo-13.png: a simplified one for 16/32 px icons;
- art/logo-skin.png: 24 px in the base skin's colours, for the main
  window's about button (scripts/retitle_base_skin.py puts it into MAIN.BMP).

The app icon sits the logo on a dark rounded square (the macOS icon
shape): App/Assets.xcassets/AppIcon.appiconset.

Usage: scripts/make_logo.py  (from the repository root)
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

# Palette, sampled from the concept art.
OUTLINE = (12, 12, 16)
SILVER = {"white": (246, 246, 240), "light": (200, 200, 204), "mid": (141, 141, 146), "dark": (98, 96, 100)}
INTERIOR = [(28, 28, 32), (18, 18, 22), (8, 8, 10)]  # top to bottom
RED = (104, 6, 0)
RED_DARK = (62, 0, 0)
GOLD = {
    "white": (255, 252, 226),
    "pale": (250, 226, 120),
    "yellow": (255, 236, 64),
    "gold": (246, 192, 28),
    "amber": (253, 168, 4),
    "orange": (252, 138, 0),
    "deep": (232, 84, 4),
}


def diamond(size, ring, img, silver=SILVER, interior=INTERIOR, outline=OUTLINE):
    """Silver diamond: `size` px across, `ring` px of silver inside a 1 px outline.

    Pixel (x, y) is inside when |x + .5 - c| + |y + .5 - c| <= c, which gives
    rows 2, 4, ... size, size, ... 4, 2 pixels wide for an even size.
    """
    c = size / 2
    px = img.load()
    for y in range(size):
        for x in range(size):
            u = abs(x + 0.5 - c) + abs(y + 0.5 - c)
            if u > c:
                continue
            depth = c - u  # 0 at the edge, grows inwards
            left, top = x + 0.5 < c, y + 0.5 < c
            if depth < 1:
                px[x, y] = outline + (255,)
            elif depth < 1 + ring:
                # Raised bevel lit from the top left: bright outer edge on the
                # top-left side, bright inner edge on the bottom-right side.
                step = int(depth - 1) * 4 // ring  # 0..3 across the ring
                if left and top:
                    shades = ["white", "white", "light", "mid"]
                elif not left and not top:
                    shades = ["dark", "mid", "light", "white"]
                elif left:
                    shades = ["mid", "light", "white", "light"]
                else:
                    shades = ["light", "white", "light", "mid"]
                px[x, y] = silver[shades[min(step, 3)]] + (255,)
            else:
                band = min(2, int(y * 3 / size))
                px[x, y] = interior[band] + (255,)


def h_letter(img, x0, y0, w, h, leg, bar_top, bar_h, gold=GOLD, red=RED, red_dark=RED_DARK):
    """A bevelled gold H with a 1 px red outline, top-left corner at (x0, y0)."""
    def inside(x, y):
        if not (x0 <= x < x0 + w and y0 <= y < y0 + h):
            return False
        in_leg = x < x0 + leg or x >= x0 + w - leg
        in_bar = y0 + bar_top <= y < y0 + bar_top + bar_h
        return in_leg or in_bar

    px = img.load()
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w):
            if not inside(x, y):
                continue
            edge = [not inside(x + dx, y + dy) for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1))]
            if any(edge):
                # Outline, darker on the bottom and right.
                px[x, y] = (red_dark if (edge[1] or edge[3]) and not (edge[0] or edge[2]) else red) + (255,)
                continue
            left_open = not inside(x - 2, y)
            right_open = not inside(x + 2, y)
            top_open = not inside(x, y - 2)
            bottom_open = not inside(x, y + 2)
            t = (y - y0) / (h - 1)
            if top_open and left_open:
                color = gold["white"]
            elif top_open:
                color = gold["yellow"]
            elif bottom_open:
                color = gold["deep"]
            elif right_open:
                color = gold["orange"] if t < 0.6 else gold["deep"]
            elif left_open:
                color = gold["pale"]
            elif t < 0.45:
                color = gold["gold"]
            elif t < 0.75:
                color = gold["amber"]
            else:
                color = gold["orange"]
            px[x, y] = color + (255,)


def sprite(img, x0, y0, rows, colors, outline=None):
    """Draws `rows` (one character per pixel, "." = none) at (x0, y0); `outline` rings it."""
    px = img.load()
    cells = {(x0 + i, y0 + j) for j, row in enumerate(rows) for i, ch in enumerate(row) if ch != "."}
    if outline:
        for x, y in cells:
            for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                if (x + dx, y + dy) not in cells:
                    px[x + dx, y + dy] = outline + (255,)
    for j, row in enumerate(rows):
        for i, ch in enumerate(row):
            if ch != ".":
                px[x0 + i, y0 + j] = colors[ch] + (255,)


BOLT_COLORS = {"w": GOLD["white"], "y": GOLD["yellow"], "o": GOLD["orange"]}
BOLT = [
    ".....wyy",
    "....wyo.",
    "...wyo..",
    "..wyo...",
    ".wwwwyyy",
    "yyyyyyo.",
    "...wyo..",
    "..wyo...",
    ".wyo....",
    ".yo.....",
    "yo......",
    "o.......",
]


def logo46():
    img = Image.new("RGBA", (46, 46), (0, 0, 0, 0))
    diamond(46, 4, img)
    h_letter(img, 9, 9, 28, 28, leg=10, bar_top=11, bar_h=6)
    sprite(img, 19, 17, BOLT, BOLT_COLORS, outline=RED_DARK)
    return img


# The small logo, for 16 and 32 px icons: the H fills it, the diamond peeks
# out at the tips and between the legs, and the bolt is the H's bar.
MINI_COLORS = {
    "k": OUTLINE, "W": SILVER["white"], "L": SILVER["light"], "D": SILVER["dark"], "i": INTERIOR[1],
    "R": RED, "r": RED_DARK, "w": GOLD["white"], "p": GOLD["pale"], "y": GOLD["yellow"], "g": GOLD["gold"],
    "a": GOLD["amber"], "o": GOLD["orange"], "e": GOLD["deep"],
}
MINI = [
    "......k......",
    ".RRRRkWkRRRR.",
    ".RwyRWiLRyoR.",
    ".RpgRiiiRgoR.",
    ".RpgRiiyRgoR.",
    ".RpaRiwyRaoR.",
    "kRpayywyyaoRk",
    ".RpaRwyiRaoR.",
    ".RpoRyiiRooR.",
    ".RpoRiiiRooR.",
    ".ReeRLiDReeR.",
    ".rrrrkDkrrrr.",
    "......k......",
]

# The skin's about button, where Winamp's bolt was (MAIN.BMP, bottom right):
# the full design at 24 px, as much as fits between the repeat button and the
# frame, in the base skin's muted golds and greys. No bolt: at 1x it reads as
# a notch in the H's bar.
SKIN_SILVER = {"white": (200, 202, 208), "light": (173, 175, 181), "mid": (143, 144, 146), "dark": (100, 100, 110)}
SKIN_INTERIOR = [(30, 30, 42), (22, 22, 32), (14, 14, 20)]
SKIN_GOLD = {
    "white": (236, 216, 150), "pale": (214, 180, 96), "yellow": (212, 172, 70), "gold": (190, 140, 50),
    "amber": (172, 110, 36), "orange": (150, 88, 26), "deep": (120, 64, 20),
}


def skin_logo():
    img = Image.new("RGBA", (24, 24), (0, 0, 0, 0))
    diamond(24, 3, img, SKIN_SILVER, SKIN_INTERIOR, (20, 20, 27))
    h_letter(img, 4, 4, 16, 16, leg=6, bar_top=6, bar_h=4, gold=SKIN_GOLD, red=(84, 30, 12), red_dark=(52, 18, 8))
    return img


def drawn(rows, colors):
    img = Image.new("RGBA", (len(rows[0]), len(rows)), (0, 0, 0, 0))
    sprite(img, 0, 0, rows, colors)
    return img


def icon(size, big, mini):
    """The app icon at `size` px: the logo on a dark rounded square (Apple's
    grid: an 824/1024 square with 22.5% corners), logo scaled by whole pixels."""
    plate = round(size * 824 / 1024)
    offset = (size - plate) // 2
    # The plate is drawn 4x larger and reduced, for smooth corners.
    k = 4
    layer = Image.new("RGBA", (size * k, size * k), (0, 0, 0, 0))
    mask = Image.new("L", layer.size, 0)
    box = (offset * k, offset * k, (offset + plate) * k - 1, (offset + plate) * k - 1)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=round(plate * 0.225 * k), fill=255)
    gradient = Image.new("RGBA", layer.size)
    top, bottom = (58, 58, 78), (18, 18, 26)
    draw = ImageDraw.Draw(gradient)
    for y in range(layer.height):
        t = min(1, max(0, (y - offset * k) / (plate * k)))
        draw.line([(0, y), (layer.width, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    layer.paste(gradient, mask=mask)
    if size >= 128:
        # A thin light rim along the top, like the skin's bevels.
        rim = Image.new("L", layer.size, 0)
        ImageDraw.Draw(rim).rounded_rectangle(box, radius=round(plate * 0.225 * k), outline=255, width=max(k, size * k // 256))
        rim = Image.composite(rim, Image.new("L", layer.size, 0), Image.linear_gradient("L").rotate(180).resize(layer.size))
        layer.paste(Image.new("RGBA", layer.size, (140, 140, 170, 255)), mask=rim.point(lambda v: v * 0.35))
    canvas = layer.resize((size, size), Image.LANCZOS)
    if size >= 128:
        shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        shadow_mask = mask.resize((size, size), Image.LANCZOS).point(lambda v: v * 0.45)
        shadow.paste((0, 0, 0, 255), (0, round(size * 0.012)), shadow_mask)
        shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.012))
        shadow.alpha_composite(canvas)
        canvas = shadow
    art = big if size >= 64 else mini
    scale = max(1, plate // art.width) if art is mini else {64: 1, 128: 2, 256: 4, 512: 8, 1024: 16}[size]
    logo = art.resize((art.width * scale, art.height * scale), Image.NEAREST)
    canvas.alpha_composite(logo, ((size - logo.width) // 2, (size - logo.height) // 2))
    return canvas


def main():
    os.makedirs("art", exist_ok=True)
    big, mini = logo46(), drawn(MINI, MINI_COLORS)
    big.save("art/logo-46.png")
    mini.save("art/logo-13.png")
    skin_logo().save("art/logo-skin.png")
    big.resize((46 * 8, 46 * 8), Image.NEAREST).save("art/logo.png")

    folder = "App/Assets.xcassets/AppIcon.appiconset"
    os.makedirs(folder, exist_ok=True)
    with open("App/Assets.xcassets/Contents.json", "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    images = []
    for size in (16, 32, 64, 128, 256, 512, 1024):
        icon(size, big, mini).save(f"{folder}/icon_{size}.png")
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}", "filename": f"icon_{points * scale}.png"})
    with open(f"{folder}/Contents.json", "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)


if __name__ == "__main__":
    main()
