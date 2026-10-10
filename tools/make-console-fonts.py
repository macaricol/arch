#!/usr/bin/env python3
"""Builds assets/consolefonts/: the three console fonts lib/ui.sh picks
from, each with two glyphs redrawn as Pac-Man.

  ᗧ (U+15E7)  Pac-Man, mouth open to the right: the spinner's
  ⬤ (U+2B24)  Pac-Man, mouth closed: the same circle, for its chomp
  U+E010         a round bullet, for typed passwords (the fonts' own •
                 ranges from a square to a diamond), and the login screen's
  ▂ (U+2582)     the lower quarter of a cell, and U+E011 the upper one (the
                 console maps no characters beyond U+FFFF, which the
                 standard upper quarter is): the installer's text box, a
                 quarter row taller above and below its text (lib/prompt.sh's
                 field)
  U+E100 + n     the cells of assets/logo/logo-hd.txt (tools/make-logo.py)
                 and assets/tux/tux-hd.txt (tools/make-tux.py): each a 2 x 4
                 grid of blocks, bit n set for each one filled
  ▏▎▍▌▋▊▉        left eighths of a cell, for the progress bar's leading edge
                 (lib/ui.sh's draw_progress); the fonts that already have
                 one (▌) keep theirs

The console can't show emoji or colour glyphs, and no stock console font has
any of them, so they take over the slots of glyphs the installer never
prints (old DOS and box-drawing symbols like ☺ ♀ ╬, or Hebrew and Arabic
letters in the 512-glyph font).
The two Pac-Men are as tall as the font's capital O and centred on it, so
they sit in a line of text like a letter. The login screen's padlock is
drawn here too (draw_lock), but for tools/make-sddm-theme.py, not kept in
the fonts: it's the shape of Omarchy's (default/plymouth/lock.png in
basecamp/omarchy), redrawn from its measurements; like there, it's 80% as
tall as the 3-row password box beside it and centred on it.

Run it again only to change the drawing; the output is committed:
  tools/make-console-fonts.py
"""
import gzip
import math
import pathlib
import struct

FONTS = ("default8x16", "sun12x22", "latarcyrheb-sun32")
SOURCE = pathlib.Path("/usr/share/kbd/consolefonts")
OUT = pathlib.Path(__file__).resolve().parent.parent / "assets" / "consolefonts"

PACMAN, CLOSED = "ᗧ", "⬤"
LOCK_COLS, LOCK_ROWS = 5, 3
LOCK = [chr(0xE000 + i) for i in range(LOCK_COLS * LOCK_ROWS)]   # row by row
DOT = "\ue010"
LOWER_QUARTER, UPPER_QUARTER = "\u2582", "\ue011"
EIGHTHS = "▏▎▍▌▋▊▉"   # 1/8 to 7/8 of a cell, filled from the left
MOUTH_DEGREES = 38   # half the opening, measured from the horizontal
# The drawings whose cells are glyphs here.
ART = [pathlib.Path(__file__).resolve().parent.parent / "assets" / p for p in ("logo/logo-hd.txt", "tux/tux-hd.txt")]
# Slots to give up, in order of preference.
# (Not •, ·, ↑, ↓ or the single-line box drawing: the installer prints those.)
SPARE = (list("☺☻♀♂♪♫☼♥♦♣♠◘○◙►◄↕‼▬↨∟↔▲▼⌂")
         + list("╔╗╚╝═║╠╣╦╩╬╒╓╕╖╘╙╛╜╞╟╡╢╤╥╧╨╪╫")
         + list("αΓπΣστΦΘδ∞φε∩≡≥≤⌠⌡≈√ⁿ░▒▓")
         + list("ƒ₧¢¥")                               # CP437 currency relics
         + list("⌐¬½¼²÷")                             # and maths ones
         + [chr(c) for c in range(0x5D0, 0x5EB)]     # Hebrew and Arabic letters, in the
         + [chr(c) for c in range(0x600, 0x700)])    # 512-glyph font only


def load(path):
    data = gzip.open(path).read()
    assert data[:4] == b"\x72\xb5\x4a\x86", f"{path}: not a PSF2 font"
    _, header, flags, count, size, height, width = struct.unpack("<7I", data[4:32])
    assert flags & 1, f"{path}: no Unicode table"
    glyphs = [bytearray(data[header + i * size: header + (i + 1) * size]) for i in range(count)]
    # Unicode table: per glyph, UTF-8 characters, 0xFE starts a sequence,
    # 0xFF ends the glyph's entry.
    table, pos = [], header + count * size
    for _ in range(count):
        end = data.index(b"\xff", pos)
        table.append(data[pos:end])
        pos = end + 1
    return dict(width=width, height=height, size=size, glyphs=glyphs, table=table, header=data[:header])


def save(font, path):
    body = b"".join(font["glyphs"]) + b"".join(t + b"\xff" for t in font["table"])
    path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wb") as f:
        f.write(font["header"] + body)


def chars_of(entry):
    """Single characters a glyph is mapped to (sequences after 0xFE ignored)."""
    return entry.split(b"\xfe")[0].decode("utf-8")


def pixel(font, glyph, x, y):
    row = (font["width"] + 7) // 8
    return bool(glyph[y * row + x // 8] & (0x80 >> (x % 8)))


def cap_rows(font):
    """First and last row of the capital O."""
    o = font["glyphs"][next(i for i, t in enumerate(font["table"]) if "O" in chars_of(t))]
    rows = [y for y in range(font["height"]) if any(pixel(font, o, x, y) for x in range(font["width"]))]
    return rows[0], rows[-1]


def lock_shape(u, v):
    """Omarchy's padlock, in its own 84x96 pixel coordinates: a body with
    rounded corners over the lower 60%, a shackle 54 wide and 12 thick with
    a round top, and a pill-shaped keyhole."""
    def rounded_rect(x0, y0, x1, y1, r):
        cx, cy = min(max(u, x0 + r), x1 - r), min(max(v, y0 + r), y1 - r)
        return (u - cx) ** 2 + (v - cy) ** 2 <= r * r
    if 37 <= v <= 96:
        return rounded_rect(0, 37, 84, 96, 10) and not rounded_rect(36, 54, 48, 78, 6)
    if 0 <= v < 37:   # shackle: a ring around (42, 27), radii 15 to 27, with straight legs below it
        d = math.hypot(u - 42, v - 27) if v < 27 else abs(u - 42)
        return 15 <= d <= 27
    return False


def draw_lock(font):
    """The padlock's 15 tiles, row by row: the shape scaled to 80% of three
    rows' height and centred in a 5x3 block of cells."""
    w, h, row = font["width"], font["height"], (font["width"] + 7) // 8
    block_w, block_h = LOCK_COLS * w, LOCK_ROWS * h
    lock_h = block_h * 0.8
    scale = lock_h / 96
    x0, y0 = (block_w - 84 * scale) / 2, (block_h - lock_h) / 2
    tiles = [bytearray(font["size"]) for _ in LOCK]
    for y in range(block_h):
        for x in range(block_w):
            hits = sum(lock_shape((x + (sx + 0.5) / 4 - x0) / scale, (y + (sy + 0.5) / 4 - y0) / scale)
                       for sy in range(4) for sx in range(4))
            if hits >= 8:
                tile = tiles[(y // h) * LOCK_COLS + x // w]
                tx, ty = x % w, y % h
                tile[ty * row + tx // 8] |= 0x80 >> (tx % 8)
    return tiles


def draw_dot(font):
    """A filled circle about half as tall as the capital O and centred on
    it. Its diameter is odd and its centre on a pixel, so it comes out
    symmetric: an even one, or one between rows, rasterises as a square or
    a rounded rectangle at these sizes."""
    w, h, row = font["width"], font["height"], (font["width"] + 7) // 8
    top, bottom = cap_rows(font)
    diameter = max(3, round((bottom - top + 1) / 2)) | 1
    r = diameter / 2
    cx, cy = (w - 2) // 2, math.floor((top + bottom) / 2 + 0.5)
    glyph = bytearray(font["size"])
    for y in range(h):
        for x in range(w):
            hits = sum((x + (sx + 0.5) / 4 - 0.5 - cx) ** 2 + (y + (sy + 0.5) / 4 - 0.5 - cy) ** 2 <= r * r
                       for sy in range(4) for sx in range(4))
            if hits >= 8:
                glyph[y * row + x // 8] |= 0x80 >> (x % 8)
    return glyph


def draw_eighth(font, k):
    """The left k/8 of the cell, full height: one pixel column an eighth in
    the 8-wide font, as near as whole pixels go in the others."""
    w, h, row = font["width"], font["height"], (font["width"] + 7) // 8
    glyph = bytearray(font["size"])
    for y in range(h):
        for x in range(round(w * k / 8)):
            glyph[y * row + x // 8] |= 0x80 >> (x % 8)
    return glyph


def draw_rows(font, top, bottom):
    """Rows top to bottom (exclusive) filled, full width."""
    w, row = font["width"], (font["width"] + 7) // 8
    glyph = bytearray(font["size"])
    for y in range(top, bottom):
        for x in range(w):
            glyph[y * row + x // 8] |= 0x80 >> (x % 8)
    return glyph


def draw_cell(font, bits):
    """A logo cell: the glyph split into 2 columns and 4 rows of blocks, on
    the same boundaries as the font's own ▌▐ and ▀▄, filled where bits says."""
    w, h, row = font["width"], font["height"], (font["width"] + 7) // 8
    xs, ys = (0, w // 2, w), [round(h * k / 4) for k in range(5)]
    glyph = bytearray(font["size"])
    for n in range(8):
        if bits >> n & 1:
            for y in range(ys[n // 2], ys[n // 2 + 1]):
                for x in range(xs[n % 2], xs[n % 2 + 1]):
                    glyph[y * row + x // 8] |= 0x80 >> (x % 8)
    return glyph


def draw(font, mouth):
    """A filled circle as tall as the capital O and centred on it; mouth > 0
    cuts a wedge open to the right."""
    w, h, row = font["width"], font["height"], (font["width"] + 7) // 8
    o = font["glyphs"][next(i for i, t in enumerate(font["table"]) if "O" in chars_of(t))]
    rows = [y for y in range(h) if any(pixel(font, o, x, y) for x in range(w))]
    diameter = min(rows[-1] - rows[0] + 1, w - 1)
    cy = (rows[0] + rows[-1]) / 2
    cx = (w - 2) / 2 if diameter == w - 1 else (w - 1) / 2   # keep the last column as a gap
    r = diameter / 2 + 0.25   # a little fuller: rounder rows at the top and bottom
    glyph = bytearray(font["size"])
    for y in range(h):
        for x in range(w):
            # 4x4 samples per pixel; on if most of the pixel is covered
            inside = 0
            for sy in range(4):
                for sx in range(4):
                    dx, dy = x + (sx + 0.5) / 4 - 0.5 - cx, y + (sy + 0.5) / 4 - 0.5 - cy
                    if dx * dx + dy * dy > r * r:
                        continue
                    if mouth and dx > 0 and abs(math.degrees(math.atan2(dy, dx))) < mouth:
                        continue
                    inside += 1
            if inside >= 8:
                glyph[y * row + x // 8] |= 0x80 >> (x % 8)
    return glyph


def main():
    for name in FONTS:
        font = load(SOURCE / f"{name}.psfu.gz")
        spare = [i for c in SPARE for i, t in enumerate(font["table"]) if chars_of(t) == c]
        glyphs = [(PACMAN, draw(font, MOUTH_DEGREES)), (CLOSED, draw(font, 0))]
        glyphs += [(DOT, draw_dot(font))]
        # The quarters on the same boundaries as the logo's cells (draw_cell).
        h = font["height"]
        glyphs += [(UPPER_QUARTER, draw_rows(font, 0, round(h / 4))),
                   (LOWER_QUARTER, draw_rows(font, round(h * 3 / 4), h))]
        cells = sorted({c for art in ART for c in art.read_text() if ord(c) >= 0xE100})
        glyphs += [(c, draw_cell(font, ord(c) - 0xE100)) for c in cells]
        have = set("".join(chars_of(t) for t in font["table"]))
        glyphs += [(c, draw_eighth(font, k)) for k, c in enumerate(EIGHTHS, 1) if c not in have]
        assert len(spare) >= len(glyphs), f"{name}: not enough spare glyph slots"
        for slot, (char, glyph) in zip(spare, glyphs):
            font["glyphs"][slot] = glyph
            font["table"][slot] = char.encode()
        save(font, OUT / f"{name}.psfu.gz")
        print(f"{name}: {font['width']}x{font['height']}, {len(glyphs)} glyphs")


if __name__ == "__main__":
    main()
