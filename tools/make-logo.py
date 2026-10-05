#!/usr/bin/env python3
"""Draws the PACMAN logo and writes logo-hd.txt and logo.txt.

The A's are the Arch Linux logo's mark, rasterised from the copy the
filesystem package installs (/usr/share/pixmaps/archlinux-logo.svg), which
needs rsvg-convert (librsvg) to run this.

The console's own characters can't go finer than logo.txt: half blocks, two
pixels per character cell. Here every cell holds 2 x 4 pixels, so the logo is
144 x 28 pixels in the same 72 x 7 cells. Cells that are empty, full or a
top or bottom half use those characters; any other pattern is the private-use
character U+E100 + its bit pattern (bit 0 top-left, bit 1 top-right, then
row by row), which tools/make-console-fonts.py draws into the console fonts.
lib/ui.sh shows this logo only on the console, where those fonts are loaded,
and logo.txt everywhere else: the same drawing at half the resolution, in
half blocks only, which every font has.

Run it again only to change the drawing; the output is committed:
  tools/make-logo.py
"""
import math
import pathlib
import re
import struct
import subprocess
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
ARCH_SVG = pathlib.Path("/usr/share/pixmaps/archlinux-logo.svg")
WIDTH, HEIGHT = 144, 28        # pixels: 72 x 7 cells of 2 x 4
CELL_W, CELL_H = 2, 4
PUA = 0xE100                   # + the cell's bit pattern

STROKE = 4
LETTER = 20                    # letters are 20 x 20, Pac-Man 24 x 24
GAP = 4
TOP = (HEIGHT - LETTER) // 2   # letters' top row; Pac-Man is centred on them


def rounded_rect(u, v, x0, y0, x1, y1, radii):
    """Inside a rectangle whose corners (top-left, top-right, bottom-right,
    bottom-left) are rounded with the given radii."""
    if not (x0 <= u <= x1 and y0 <= v <= y1):
        return False
    tl, tr, br, bl = radii
    for r, cx, cy, left, top in ((tl, x0 + tl, y0 + tl, True, True), (tr, x1 - tr, y0 + tr, False, True),
                                 (br, x1 - br, y1 - br, False, False), (bl, x0 + bl, y1 - bl, True, False)):
        beyond = (u < cx if left else u > cx) and (v < cy if top else v > cy)
        if r and beyond and (u - cx) ** 2 + (v - cy) ** 2 > r * r:
            return False
    return True


def near_segment(u, v, x0, y0, x1, y1, half):
    dx, dy = x1 - x0, y1 - y0
    t = max(0.0, min(1.0, ((u - x0) * dx + (v - y0) * dy) / (dx * dx + dy * dy)))
    return math.hypot(u - (x0 + t * dx), v - (y0 + t * dy)) <= half


# Letters in their own 0..20 square.
def letter_p(u, v):
    stem = 0 <= u <= STROKE and 0 <= v <= 20
    bowl = rounded_rect(u, v, 0, 0, 20, 13, (0, 6.5, 6.5, 0)) and not \
        rounded_rect(u, v, STROKE, STROKE, 20 - STROKE, 13 - STROKE, (0, 2.5, 2.5, 0))
    return stem or bowl


def load_arch_mark(size=600):
    """The Arch logo's mark (its first path; the others are the ™) as a
    size x size grid of booleans, cropped to the mark's bounding box."""
    svg = ARCH_SVG.read_text()
    path = re.search(r'<path d="[^"]*"', svg).group(0)
    with tempfile.TemporaryDirectory() as tmp:
        src, png = pathlib.Path(tmp, "mark.svg"), pathlib.Path(tmp, "mark.png")
        src.write_text('<svg viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg">'
                       f'<g fill="#000">{path}/></g></svg>')
        subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), str(src), "-o", str(png)], check=True)
        data = png.read_bytes()
    # Decode the PNG (8-bit RGBA, as rsvg-convert writes it); keep the alpha.
    pos, idat = 8, b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height = struct.unpack(">II", body[:8])
        elif kind == b"IDAT":
            idat += body
    raw, stride, prev, i, alpha = zlib.decompress(idat), width * 4, bytearray(width * 4), 0, []
    for _ in range(height):
        kind, cur = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a, b = (cur[x - 4] if x >= 4 else 0), prev[x]
            c = prev[x - 4] if x >= 4 else 0
            if kind == 1:
                cur[x] = (cur[x] + a) & 255
            elif kind == 2:
                cur[x] = (cur[x] + b) & 255
            elif kind == 3:
                cur[x] = (cur[x] + (a + b) // 2) & 255
            elif kind == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                cur[x] = (cur[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        alpha.append([cur[x * 4 + 3] > 127 for x in range(width)])
        prev = cur
    rows = [y for y in range(height) if any(alpha[y])]
    cols = [x for x in range(width) if any(alpha[y][x] for y in rows)]
    return [row[cols[0]:cols[-1] + 1] for row in alpha[rows[0]:rows[-1] + 1]]


ARCH_MARK = load_arch_mark()


def letter_a(u, v):
    """The Arch mark, stretched to the letter's square."""
    h, w = len(ARCH_MARK), len(ARCH_MARK[0])
    x, y = int(u / 20 * w), int(v / 20 * h)
    return 0 <= x < w and 0 <= y < h and ARCH_MARK[y][x]


def letter_m(u, v):
    stems = (0 <= u <= STROKE or 20 - STROKE <= u <= 20) and 0 <= v <= 20
    v_shape = near_segment(u, v, 2, 1, 10, 12, 2.3) or near_segment(u, v, 18, 1, 10, 12, 2.3)
    return stems or v_shape


def letter_n(u, v):
    stems = (0 <= u <= STROKE or 20 - STROKE <= u <= 20) and 0 <= v <= 20
    return stems or near_segment(u, v, 2, 1, 18, 19, 2.4)


def pacman(u, v):
    """24 x 24: a circle with a 35-degree half-opening mouth and an eye."""
    cx, cy, r = 12, 12, 12
    du, dv = u - cx, v - cy
    if du * du + dv * dv > r * r:
        return False
    if du > 0 and abs(math.degrees(math.atan2(dv, du))) < 35:
        return False
    return (u - 11.5) ** 2 + (v - 6) ** 2 > 2.2 ** 2


# How much of a pixel a shape must cover to fill it, and how many pixels to
# thicken it by afterwards. The Arch mark is a slim triangle with a wide
# doorway; as drawn, its A's come out much lighter than the 4 px strokes of
# the other letters.
THRESHOLD = {letter_a: 0.25}
THICKEN = {letter_a: 1}
# The mark's two slivers are thinner than a pixel at this size, so they're
# cut back in as 1 px slits after thickening, where the mark has them: one
# from the left edge a third of the way down, one from the right edge near
# the base. Segments in the letter's 0..20 square.
CUTS = {letter_a: [(5.6, 6.6, 9.6, 8.6), (18.4, 15.6, 14.6, 13.8)]}


def shape_at(x):
    """The shape whose box spans column x, with its box's left and top."""
    left = 0
    for shape, size in ((letter_p, LETTER), (letter_a, LETTER), (pacman, 24),
                        (letter_m, LETTER), (letter_a, LETTER), (letter_n, LETTER)):
        if left <= x < left + size:
            return shape, left, TOP - (size - LETTER) // 2, size
        left += size + GAP
    return None, 0, 0, 0


def logo(x, y):
    """The whole logo, in pixel coordinates."""
    shape, left, top, size = shape_at(x)
    return shape is not None and 0 <= y - top <= size and shape(x - left, y - top)


def cells(pixels, cell_w, cell_h, named):
    """The pixel grid as lines of characters, one per cell: named[bits] where
    there is one, else the private-use character for the pattern."""
    lines, used = [], set()
    for row in range(len(pixels) // cell_h):
        line = ""
        for col in range(len(pixels[0]) // cell_w):
            bits = sum(1 << (dy * cell_w + dx)
                       for dy in range(cell_h) for dx in range(cell_w)
                       if pixels[row * cell_h + dy][col * cell_w + dx])
            if bits not in named:
                used.add(bits)
            line += named.get(bits, chr(PUA + bits))
        lines.append(line)
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines, used


def rasterise():
    """The logo as pixels, each on if enough of it is covered (4 x 4 samples;
    half, or the shape's THRESHOLD)."""
    pixels = []
    for y in range(HEIGHT):
        row = []
        for x in range(WIDTH):
            shape = shape_at(x + 0.5)[0]
            hits = sum(logo(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4) for sy in range(4) for sx in range(4))
            row.append(hits >= 16 * THRESHOLD.get(shape, 0.5))
        pixels.append(row)
    for _ in range(max(THICKEN.values())):
        pixels = [[pixels[y][x] or (THICKEN.get(shape_at(x + 0.5)[0], 0) and any(
                       0 <= y + dy < HEIGHT and 0 <= x + dx < WIDTH and pixels[y + dy][x + dx]
                       and shape_at(x + dx + 0.5)[0] is shape_at(x + 0.5)[0]
                       for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1))))
                   for x in range(WIDTH)] for y in range(HEIGHT)]
    for y in range(HEIGHT):
        for x in range(WIDTH):
            shape, left, top, _ = shape_at(x + 0.5)
            if any(near_segment(x + 0.5 - left, y + 0.5 - top, *seg, 0.55) for seg in CUTS.get(shape, [])):
                pixels[y][x] = False
    return pixels


def halve(pixels):
    """Half the resolution, a pixel on if any of the four it replaces is: so
    the plain logo keeps the strokes as heavy as the full one's."""
    return [[any(pixels[2 * y + dy][2 * x + dx] for dy in (0, 1) for dx in (0, 1))
             for x in range(len(pixels[0]) // 2)] for y in range(len(pixels) // 2)]


def main():
    # Double resolution: 2 x 4 pixels a cell. Only characters every console
    # font has are used as themselves (▌▐ aren't in latarcyrheb).
    pixels = rasterise()
    hd, used = cells(pixels, CELL_W, CELL_H, {0: " ", 0xFF: "█", 0x0F: "▀", 0xF0: "▄"})
    (ROOT / "logo-hd.txt").write_text("\n".join(hd) + "\n")
    print(f"logo-hd.txt: {len(hd)} rows, {len(used)} cell patterns needing glyphs")
    # Half resolution: 1 x 2 pixels a cell, half blocks only.
    plain, used = cells(halve(pixels), 1, 2, {0: " ", 3: "█", 1: "▀", 2: "▄"})
    assert not used
    (ROOT / "logo.txt").write_text("\n".join(plain) + "\n")
    print(f"logo.txt: {len(plain)} rows")


if __name__ == "__main__":
    main()
