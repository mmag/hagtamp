#!/usr/bin/env python3
"""Builds Hagtamp's default skin from the Winamp 2.91 base skin: the
"WINAMP" lettering in the title bars becomes "HAGTAMP" ("PLAYLIST" alone in
the playlist, where the longer name doesn't fit).

Letters are reused from the skin's own lettering (A, M, P from WINAMP; T and
PLAYLIST from the playlist title; EQUALIZER from the equalizer title); H and
G are drawn in the same style. Each letter is an intensity mask composited
over the title background, so colours and anti-aliasing match.

Usage: scripts/retitle_base_skin.py <sheets-dir> <original.wsz> <out.wsz>
where <sheets-dir> comes from `skintool sheets <original.wsz> <sheets-dir>`.
"""
import io
import sys
import zipfile
from PIL import Image

def lum(p):
    return (p[0] * 299 + p[1] * 587 + p[2] * 114) / 1000

TEXT_LUM = 75  # pixels at least this bright belong to the lettering

# ---------------------------------------------------------------- glyphs

def read_mask(im, x0, x1, y0, y1):
    """Intensity mask of lettering in [x0,x1)x[y0,y1), background estimated per row."""
    mask = []
    for y in range(y0, y1):
        row = [lum(im.getpixel((x, y))) for x in range(x0, x1)]
        bg = [v for v in row if v < TEXT_LUM]
        base = sum(bg) / len(bg) if bg else 50
        top = max(row)
        mask.append([max(0.0, min(1.0, (v - base) / (255 - base) * 1.05)) if v >= TEXT_LUM - 10 else 0.0 for v in row])
    return mask  # rows of columns

SYMBOLS = {'#': 1.0, '*': 0.8, '+': 0.55, '-': 0.3, '.': 0.0, ' ': 0.0}

def drawn(rows):
    return [[SYMBOLS[c] for c in row] for row in rows]

# H and G in the style of the skin's lettering (2 px stems with soft edges; G from its O/Q).
H = drawn([
    "+#-.+#",
    "+#-.+#",
    "+####*",
    "+#---#",
    "+#-.+#",
    "+#-.+#",
])
G = drawn([
    ".+###-",
    "-#+...",
    "+#-...",
    "+#-###",
    "-#+.*#",
    ".+###*",
])

def hstack(glyphs, gap=1, height=None):
    height = height or max(len(g) for g in glyphs)
    rows = [[] for _ in range(height)]
    for i, g in enumerate(glyphs):
        if i:
            for r in rows:
                r.extend([0.0] * gap)
        width = len(g[0])
        for y in range(height):
            rows[y].extend(g[y] if y < len(g) else [0.0] * width)
    return rows

# ---------------------------------------------------------------- editing

def clean_text(im, x0, x1, y0, y1):
    """Removes lettering: text pixels become the row's background, interpolated."""
    px = im.load()
    for y in range(y0, y1):
        xs = list(range(x0, x1))
        is_bg = [lum(px[x, y]) < TEXT_LUM for x in xs]
        for i, x in enumerate(xs):
            if is_bg[i]:
                continue
            l = next((j for j in range(i, -1, -1) if is_bg[j]), None)
            r = next((j for j in range(i, len(xs)) if is_bg[j]), None)
            if l is None and r is None:
                continue
            if l is None:
                px[x, y] = px[xs[r], y]
            elif r is None:
                px[x, y] = px[xs[l], y]
            else:
                t = (i - l) / (r - l)
                a, b = px[xs[l], y], px[xs[r], y]
                px[x, y] = tuple(round(a[k] + (b[k] - a[k]) * t) for k in range(3))

def paint(im, mask, x0, y0, color):
    px = im.load()
    for dy, row in enumerate(mask):
        for dx, m in enumerate(row):
            if m <= 0:
                continue
            x, y = x0 + dx, y0 + dy
            b = px[x, y]
            px[x, y] = tuple(round(b[k] + (color[k] - b[k]) * m) for k in range(3))

def move_columns(im, src_x0, src_x1, dst_x0, y0, y1):
    """Moves a block of columns (a bar end cap)."""
    block = im.crop((src_x0, y0, src_x1, y1))
    im.paste(block, (dst_x0, y0))

def fill_columns(im, x0, x1, source_x, y0, y1):
    """Fills columns with copies of one column (bar body or background)."""
    column = im.crop((source_x, y0, source_x + 1, y1))
    for x in range(x0, x1):
        im.paste(column, (x, y0))

def text_color(im, x0, x1, y0, y1):
    return max((im.getpixel((x, y)) for x in range(x0, x1) for y in range(y0, y1)), key=lum)

# ---------------------------------------------------------------- titles

def retitle_bar(im, oy, text_rows, old_text, left_cap_end, right_cap_start, mask, gap_x, center=None):
    """Replaces the centred lettering of a title bar at vertical offset `oy`.

    old_text: (x0, x1) of the old lettering; the bars end at left_cap_end
    (inclusive) and start at right_cap_start. Bars are shortened or lengthened
    so the new text keeps the old margins.
    """
    y0, y1 = oy + text_rows[0], oy + text_rows[1]
    color = text_color(im, old_text[0], old_text[1], y0, y1)
    margin_l = old_text[0] - left_cap_end
    margin_r = right_cap_start - old_text[1]
    width = len(mask[0])
    center = center if center is not None else (old_text[0] + old_text[1]) / 2
    new_x0 = round(center - width / 2)
    new_x1 = new_x0 + width
    # Clear the old lettering (rows of the text only).
    clean_text(im, old_text[0], old_text[1], y0, y0 + len(mask))
    # Move the bar caps outwards (text wider) or inwards; caps are 6 px wide.
    # Only the rows between the frame lines move: the frame has its own gradient.
    rows = (oy + 2, oy + 12)
    shift_l = (new_x0 - margin_l) - left_cap_end
    if shift_l != 0:
        cap = (left_cap_end - 5, left_cap_end + 1)
        saved = im.crop((cap[0], rows[0], cap[1], rows[1]))
        if shift_l < 0:
            fill_columns(im, cap[0] + shift_l, cap[1], gap_x, rows[0], rows[1])
        else:
            fill_columns(im, cap[0], cap[0] + shift_l, cap[0] - 1, rows[0], rows[1])
        im.paste(saved, (cap[0] + shift_l, rows[0]))
    shift_r = (new_x1 + margin_r) - right_cap_start
    if shift_r != 0:
        cap = (right_cap_start, right_cap_start + 6)
        saved = im.crop((cap[0], rows[0], cap[1], rows[1]))
        if shift_r > 0:
            fill_columns(im, cap[0], cap[1] + shift_r, gap_x, rows[0], rows[1])
        else:
            fill_columns(im, cap[1] + shift_r, cap[1], cap[1], rows[0], rows[1])
        im.paste(saved, (cap[0] + shift_r, rows[0]))
    paint(im, mask, new_x0, y0, color)

def main():
    sheets, original, out = sys.argv[1:4]
    titlebar = Image.open(f"{sheets}/TITLEBAR.png").convert("RGB")
    eqmain = Image.open(f"{sheets}/EQMAIN.png").convert("RGB")
    pledit = Image.open(f"{sheets}/PLEDIT.png").convert("RGB")

    # Letters from the skin (active title bars, before editing).
    A = read_mask(titlebar, 163, 169, 5, 11)
    M = read_mask(titlebar, 170, 177, 5, 11)
    P = read_mask(titlebar, 178, 184, 5, 11)
    T = read_mask(pledit, 114, 120, 5, 11)
    EQUALIZER = read_mask(eqmain, 138, 188, 139, 146)
    PLAYLIST = read_mask(pledit, 76, 120, 5, 11)
    HAGTAMP = hstack([H, A, G, T, A, M, P])
    SPACE = [[0.0] * 3 for _ in range(7)]
    HAGTAMP_EQUALIZER = hstack([HAGTAMP + [[0.0] * len(HAGTAMP[0])], SPACE, EQUALIZER], gap=1)

    # Main window title bar, active and inactive (sprite x = 27).
    for oy in (0, 15):
        retitle_bar(titlebar, oy, (5, 11), (143, 186), 140, 188, HAGTAMP, gap_x=142)
    # Equalizer title bar, active and inactive.
    for oy in (134, 149):
        retitle_bar(eqmain, oy, (5, 12), (93, 190), 89, 193, HAGTAMP_EQUALIZER, gap_x=91)

    # Main window shade bar: lettering on the left, then a short bar stub
    # (x 91-104) before the visualizer box. HAGTAMP leaves no room for the stub.
    for oy in (29, 42):
        y0 = oy + 5
        color = text_color(titlebar, 47, 86, y0, y0 + 6)
        clean_text(titlebar, 45, 90, y0, y0 + 6)
        new_x0 = 47
        new_x1 = new_x0 + len(HAGTAMP[0])
        fill_columns(titlebar, 89, 105, 88, oy + 2, oy + 12)
        if new_x1 + 5 + 8 <= 105:  # keep a stub if at least 8 px fit
            cap = titlebar.crop((91, oy + 2, 95, oy + 12))
            titlebar.paste(cap, (new_x1 + 5, oy + 2))
        paint(titlebar, HAGTAMP, new_x0, y0, color)

    # Playlist title (100 px, bar caps at both ends): "PLAYLIST" only, centred.
    for oy in (0, 21):
        y0 = oy + 5
        color = text_color(pledit, 33, 120, y0, y0 + 6)
        width = len(PLAYLIST[0])
        new_x0 = 26 + (100 - width) // 2
        clean_text(pledit, 30, 122, y0, y0 + 6)
        # Extend both bars towards the text with their body pattern (from the title tile).
        body_x = 127 + 12  # middle of PLAYLIST_TOP_TILE / _SELECTED at the same rows
        rows = (oy + 2, oy + 12)
        left_cap = pledit.crop((26, rows[0], 30, rows[1]))
        right_cap = pledit.crop((122, rows[0], 126, rows[1]))
        left_end = new_x0 - 4
        fill_columns(pledit, 26, left_end - 4, body_x, rows[0], rows[1])
        pledit.paste(left_cap, (left_end - 4, rows[0]))
        right_start = new_x0 + width + 4
        fill_columns(pledit, right_start + 4, 126, body_x, rows[0], rows[1])
        pledit.paste(right_cap, (right_start, rows[0]))
        paint(pledit, PLAYLIST, new_x0, y0, color)

    # Rebuild the archive with the edited bitmaps.
    edited = {"TITLEBAR.BMP": titlebar, "EQMAIN.BMP": eqmain, "PLEDIT.BMP": pledit}
    with zipfile.ZipFile(original) as src, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as dst:
        for info in src.infolist():
            name = info.filename.split("/")[-1].upper()
            if name in edited:
                buffer = io.BytesIO()
                edited[name].save(buffer, format="BMP")
                dst.writestr(info.filename, buffer.getvalue())
            else:
                dst.writestr(info, src.read(info))
    for name, image in edited.items():
        image.save(f"{sheets}/{name.split('.')[0]}.edited.png")

if __name__ == "__main__":
    main()
