#!/usr/bin/env python3
"""Builds assets/consolefonts/: the three console fonts lib/ui.sh picks
from, each with these glyphs added:

  ᗧ (U+15E7)     Pac-Man, mouth open to the right: the spinner's
  ⬤ (U+2B24)     Pac-Man, mouth closed: the same circle, for its chomp
  U+E010         a round bullet, for typed passwords (the fonts' own •
                 ranges from a square to a diamond); the login screen's
                 dot.png too (tools/make-sddm-theme.py)
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
  ←→↑↓           arrows, for the lists' and buttons' key hints (lib/
                 prompt.sh), in the fonts without them (latarcyrheb-sun32,
                 which the console otherwise shows as < and >)

The console can't show emoji or colour glyphs, and no stock console font has
any of them, so they take over the slots of glyphs the installer never
prints (old DOS and box-drawing symbols like ☺ ♀ ╬, or Hebrew and Arabic
letters in the 512-glyph font).
The two Pac-Men are as tall as the font's capital O and centred on it, so
they sit in a line of text like a letter.

Run it again to change the drawing, and after tools/make-logo.py or
tools/make-tux.py (their cells); then tools/make-sddm-theme.py, whose
images use these fonts. The output is committed:
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
DOT = "\ue010"
LOWER_QUARTER, UPPER_QUARTER = "\u2582", "\ue011"
EIGHTHS = "▏▎▍▌▋▊▉"   # 1/8 to 7/8 of a cell, filled from the left
ARROWS = "←→↑↓"
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
         + list("☸№‗‾┗┃┏┣┛━┻┓┫┳╋")                     # heavy box drawing and odds and ends
         + [chr(c) for c in range(0x5D0, 0x5EB)]     # Hebrew and Arabic letters, in the
         + [chr(c) for c in range(0x600, 0x700)])    # 512-glyph font only


def load(path):
    with gzip.open(path) as f:
        data = f.read()
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


def glyph_of(font, char):
    """The glyph char is mapped to."""
    return font["glyphs"][next(i for i, t in enumerate(font["table"]) if char in chars_of(t))]


def ink_rows(font, glyph):
    """The rows with any pixel set."""
    return [y for y in range(font["height"]) if any(pixel(font, glyph, x, y) for x in range(font["width"]))]


def cap_rows(font):
    """First and last row of the capital O."""
    rows = ink_rows(font, glyph_of(font, "O"))
    return rows[0], rows[-1]


def fill(font, on):
    """A glyph with pixel (x, y) set wherever on(x, y)."""
    w, row = font["width"], (font["width"] + 7) // 8
    glyph = bytearray(font["size"])
    for y in range(font["height"]):
        for x in range(w):
            if on(x, y):
                glyph[y * row + x // 8] |= 0x80 >> (x % 8)
    return glyph


def rasterise(font, inside):
    """A glyph of the shape inside(u, v), in pixel coordinates: a pixel on
    if most of it is covered, sampled 4 x 4."""
    return fill(font, lambda x, y: sum(inside(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4)
                                       for sy in range(4) for sx in range(4)) >= 8)


def draw_dot(font):
    """A filled circle about half as tall as the capital O and centred on
    it. Its diameter is odd and its centre on a pixel, so it comes out
    symmetric: an even one, or one between rows, rasterises as a square or
    a rounded rectangle at these sizes."""
    top, bottom = cap_rows(font)
    diameter = max(3, round((bottom - top + 1) / 2)) | 1
    r = diameter / 2
    cx, cy = (font["width"] - 2) // 2, math.floor((top + bottom) / 2 + 0.5)
    return rasterise(font, lambda u, v: (u - 0.5 - cx) ** 2 + (v - 0.5 - cy) ** 2 <= r * r)


def draw_eighth(font, k):
    """The left k/8 of the cell, full height: one pixel column an eighth in
    the 8-wide font, as near as whole pixels go in the others."""
    edge = round(font["width"] * k / 8)
    return fill(font, lambda x, y: x < edge)


def stroke(font):
    """The thickness of the font's horizontal strokes: its hyphen's. (Its
    vertical ones are up to twice that, in latarcyrheb-sun32: too heavy for
    an arrow, whose head then fills in.)"""
    hyphen, x = glyph_of(font, "-"), font["width"] // 2
    return max(1, sum(pixel(font, hyphen, x, y) for y in range(font["height"])))


def draw_arrow(font, char):
    """An arrow, as thick as the font's horizontal strokes: ← and → across
    the cell at the height of the x's middle, their heads as tall as half
    the capital O; ↑ and ↓ the capital O's height, heads as wide as the
    cell allows. Lines drawn by their distance from each point."""
    w = font["width"]
    top, bottom = cap_rows(font)
    xrows = ink_rows(font, glyph_of(font, "x"))
    thickness = stroke(font)
    half = thickness / 2
    if char in "←→":
        cy, left, right = (xrows[0] + xrows[-1] + 1) / 2, 1 + half, w - 1 - half
        arm = min((bottom - top + 1) / 4, (right - left) / 2)
        tip, back = (right, left) if char == "→" else (left, right)
        lean = -arm if char == "→" else arm
        lines = [((back, cy), (tip, cy)), ((tip, cy), (tip + lean, cy - arm)), ((tip, cy), (tip + lean, cy + arm))]
    else:
        # The shaft on whole pixels: an odd stroke centred on one, an even
        # one between two.
        cx = w // 2 if thickness % 2 == 0 else (w - 1) // 2 + 0.5
        arm = min(cx - 1 - half, (bottom - top + 1) / 3)
        tip, back = (top + half, bottom + 1 - half) if char == "↑" else (bottom + 1 - half, top + half)
        lean = arm if char == "↑" else -arm
        lines = [((cx, back), (cx, tip)), ((cx, tip), (cx - arm, tip + lean)), ((cx, tip), (cx + arm, tip + lean))]

    def near(px, py):
        for (x0, y0), (x1, y1) in lines:
            dx, dy = x1 - x0, y1 - y0
            t = max(0, min(1, ((px - x0) * dx + (py - y0) * dy) / (dx * dx + dy * dy)))
            if (px - x0 - t * dx) ** 2 + (py - y0 - t * dy) ** 2 <= half * half:
                return True
        return False
    return rasterise(font, near)


def draw_rows(font, top, bottom):
    """Rows top to bottom (exclusive) filled, full width."""
    return fill(font, lambda x, y: top <= y < bottom)


def draw_cell(font, bits):
    """A logo cell: the glyph split into 2 columns and 4 rows of blocks, on
    the same boundaries as the font's own ▌▐ and ▀▄, filled where bits says."""
    half, ends = font["width"] // 2, [round(font["height"] * k / 4) for k in range(1, 5)]

    def on(x, y):
        row = next(k for k, end in enumerate(ends) if y < end)
        return bits >> (2 * row + (x >= half)) & 1
    return fill(font, on)


def draw_pacman(font, mouth):
    """A filled circle as tall as the capital O and centred on it; mouth > 0
    cuts a wedge open to the right."""
    w = font["width"]
    top, bottom = cap_rows(font)
    diameter = min(bottom - top + 1, w - 1)
    cy = (top + bottom) / 2
    cx = (w - 2) / 2 if diameter == w - 1 else (w - 1) / 2   # keep the last column as a gap
    r = diameter / 2 + 0.25   # a little fuller: rounder rows at the top and bottom

    def inside(u, v):
        dx, dy = u - 0.5 - cx, v - 0.5 - cy
        return dx * dx + dy * dy <= r * r and not (mouth and dx > 0 and abs(math.degrees(math.atan2(dy, dx))) < mouth)
    return rasterise(font, inside)


def main():
    for name in FONTS:
        font = load(SOURCE / f"{name}.psfu.gz")
        spare = [i for c in SPARE for i, t in enumerate(font["table"]) if chars_of(t) == c]
        glyphs = [(PACMAN, draw_pacman(font, MOUTH_DEGREES)), (CLOSED, draw_pacman(font, 0))]
        glyphs += [(DOT, draw_dot(font))]
        # The quarters on the same boundaries as the logo's cells (draw_cell).
        h = font["height"]
        glyphs += [(UPPER_QUARTER, draw_rows(font, 0, round(h / 4))),
                   (LOWER_QUARTER, draw_rows(font, round(h * 3 / 4), h))]
        cells = sorted({c for art in ART for c in art.read_text() if ord(c) >= 0xE100})
        glyphs += [(c, draw_cell(font, ord(c) - 0xE100)) for c in cells]
        have = set("".join(chars_of(t) for t in font["table"]))
        glyphs += [(c, draw_eighth(font, k)) for k, c in enumerate(EIGHTHS, 1) if c not in have]
        glyphs += [(c, draw_arrow(font, c)) for c in ARROWS if c not in have]
        assert len(spare) >= len(glyphs), f"{name}: not enough spare glyph slots"
        for slot, (char, glyph) in zip(spare, glyphs):
            font["glyphs"][slot] = glyph
            font["table"][slot] = char.encode()
        save(font, OUT / f"{name}.psfu.gz")
        print(f"{name}: {font['width']}x{font['height']}, {len(glyphs)} glyphs")


if __name__ == "__main__":
    main()
