#!/usr/bin/env python3
"""Draws the ARCHMAN logo and writes logo-hd.txt and logo.txt.

The style is the classic arcade title: chunky letters over a solid copy of
themselves shifted up and left (the extrusion, in its own colour), set edge
to edge so every letter covers the extrusion of the next. R, H, M and N are
pixel art on a grid of 2 px units, drawn as a thick outline with a dark
inside; the C is a solid Pac-Man with his eye cut out; the A's are the Arch
Linux logo's mark, kept solid, rasterised from the copy the filesystem
package installs (/usr/share/pixmaps/archlinux-logo.svg), which needs
rsvg-convert (librsvg) to run this.

The console's own characters can't go finer than logo.txt: half blocks, two
pixels per character cell. logo-hd.txt holds 2 x 4 pixels a cell, so the
logo is 156 x 28 pixels in 78 x 7 cells. Cells that are empty, full or a top
or bottom half use those characters; any other pattern is the private-use
character U+E100 + its bit pattern (bit 0 top-left, bit 1 top-right, then
row by row), which tools/make-console-fonts.py draws into the console fonts.
Each .txt has a .colors file beside it: a digit a cell, its character's
colour times 3 plus its background's (see DARK, LETTER, SHADE below).
lib/ui.sh shows logo-hd.txt only on the console, where those fonts are
loaded, and logo.txt everywhere else: the same design at half the
resolution, in half blocks only, which every font has, with solid letters
(there's no room for outlines).

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
WIDTH, HEIGHT = 156, 28        # pixels: 78 x 7 cells of 2 x 4 (the console has 80)
CELL_W, CELL_H = 2, 4
PUA = 0xE100                   # + the cell's bit pattern

# The two versions' proportions. Full: 2 px units, 24 px letters, a 3 px
# extrusion, 2 px outlines. Plain (half the resolution) has no room for
# outlines, so its letters are solid over a 2 px extrusion.
FULL = dict(unit=2, top=4, shadow=3, outline=2, width=WIDTH, height=HEIGHT)
PLAIN = dict(unit=1, top=2, shadow=2, outline=0, width=WIDTH // 2, height=HEIGHT // 2)
OUTLINE_A = False              # True: the A's outlined like the rest


def near_segment(u, v, x0, y0, x1, y1, half):
    dx, dy = x1 - x0, y1 - y0
    t = max(0.0, min(1.0, ((u - x0) * dx + (v - y0) * dy) / (dx * dx + dy * dy)))
    return math.hypot(u - (x0 + t * dx), v - (y0 + t * dy)) <= half


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


# R, H and M: 12 units tall, 4-unit strokes, small counters, as in the
# arcade original. N is generated: its diagonal has to be as thick as its
# stems, or the outline leaves nothing of it.
ART = {
    "R": ["#########.",
          "##########",
          "####..####",
          "####..####",
          "##########",
          "#########.",
          "####.####.",
          "####..####",
          "####..####",
          "####..####",
          "####..####",
          "####..####"],
    "H": ["####..####"] * 4 + ["##########"] * 3 + ["####..####"] * 5,
    "M": ["####...####",
          "#####.#####",
          "###########",
          "###########",
          "####.#.####",
          "####...####"] + ["####...####"] * 6,
}
ART["N"] = ["".join("#" if c < 4 or c > 7 or round(r * 8 / 11) <= c < round(r * 8 / 11) + 4 else "."
                    for c in range(12)) for r in range(12)]


def from_art(rows, unit):
    return [[rows[y // unit][x // unit] == "#" for x in range(len(rows[0]) * unit)]
            for y in range(len(rows) * unit)]


def sample(inside, w, h, coverage=0.5):
    """inside(u, v) as a w x h grid, a pixel on if enough of it is covered."""
    return [[sum(inside(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4) for sy in range(4) for sx in range(4))
             >= 16 * coverage for x in range(w)] for y in range(h)]


def arch_a(w=20, h=24):
    """The Arch mark at w x h. At this size it comes out lighter than the
    letters, so it's taken at a quarter coverage and thickened a pixel; its
    two slivers, thinner than a pixel here, are then cut back in as slits."""
    mh, mw = len(ARCH_MARK), len(ARCH_MARK[0])
    g = sample(lambda u, v: 0 <= u < w and 0 <= v < h and ARCH_MARK[int(v / h * mh)][int(u / w * mw)], w, h, 0.25)
    g = [[g[y][x] or any(0 <= y + dy < h and 0 <= x + dx < w and g[y + dy][x + dx]
                         for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)))
          for x in range(w)] for y in range(h)]
    for x0, y0, x1, y1 in ((5.6, 6.6, 9.6, 8.6), (18.4, 15.6, 14.6, 13.8)):   # in a 20 x 20 square
        for y in range(h):
            for x in range(w):
                if near_segment(x + 0.5, y + 0.5, x0 * w / 20, y0 * h / 20, x1 * w / 20, y1 * h / 20, 0.55):
                    g[y][x] = False
    return g


def pacman(size=24):
    """A circle with a 35-degree half-opening mouth (the eye goes on later)."""
    c = size / 2

    def inside(u, v):
        du, dv = u - c, v - c
        return du * du + dv * dv <= c * c and not (du > 0 and abs(math.degrees(math.atan2(dv, du))) < 35)
    return sample(inside, size, size)


def erode(g, n):
    """g shrunk by n pixels all round (8-neighbourhood)."""
    h, w = len(g), len(g[0])
    for _ in range(n):
        g = [[g[y][x] and all(0 <= y + dy < h and 0 <= x + dx < w and g[y + dy][x + dx]
                              for dy in (-1, 0, 1) for dx in (-1, 0, 1))
              for x in range(w)] for y in range(h)]
    return g


# Colours: the background, the letters, the extrusion. On the console they
# are palette slots 0, 6 and 2 (lib/ui.sh's logo_lines).
DARK, LETTER, SHADE = 0, 1, 2


def compose(unit, top, shadow, outline, width, height):
    """The logo as colours: every letter's extrusion first, then each letter
    over it. R, H, M and N are outlined, with a dark inside; Pac-Man and the
    A's are solid, Pac-Man with his eye cut out."""
    letters = [("A", arch_a(10 * unit, 12 * unit), OUTLINE_A), ("R", from_art(ART["R"], unit), True),
               ("C", pacman(12 * unit), False), ("H", from_art(ART["H"], unit), True),
               ("M", from_art(ART["M"], unit), True), ("A", arch_a(10 * unit, 12 * unit), OUTLINE_A),
               ("N", from_art(ART["N"], unit), True)]
    placed, left = [], shadow
    for name, body, outlined in letters:
        placed.append((name, body, outlined, left))
        left += len(body[0])
    assert left <= width, f"logo is {left} px wide, the canvas {width}"
    canvas = [[DARK] * width for _ in range(height)]

    def put(y, x, colour):
        if 0 <= y < height and 0 <= x < width:
            canvas[y][x] = colour

    for _, body, _, left in placed:
        for y, row in enumerate(body):
            for x, on in enumerate(row):
                if on:
                    put(top + y - shadow, left + x - shadow, SHADE)
    for name, body, outlined, left in placed:
        h, w = len(body), len(body[0])
        inner = erode(body, outline) if outlined and outline else [[False] * w for _ in range(h)]
        for y in range(h):
            for x in range(w):
                if body[y][x]:
                    put(top + y, left + x, DARK if inner[y][x] else LETTER)
        if name == "C":                                       # Pac-Man's eye
            for y in range(round(2.5 * unit), round(4 * unit)):
                for x in range(5 * unit, round(6.5 * unit)):
                    put(top + y, left + x, DARK)
    return canvas


def cells(canvas, cell_w, cell_h, named):
    """The colour grid as lines of characters and lines of colours, a cell
    each. A cell takes two colours, its character's (fg) and its
    background's (bg), written as the digit fg * 3 + bg. The character is
    named[bits] when there is one, else the private-use character for the
    pattern; bits are the fg pixels. Letter pixels are the fg wherever
    there are any; a third colour in a cell becomes whichever of the other
    two it has more of (a pixel or two, behind a letter's edge)."""
    lines, colours, used = [], [], set()
    for row in range(len(canvas) // cell_h):
        line = attrs = ""
        for col in range(len(canvas[0]) // cell_w):
            px = [canvas[row * cell_h + dy][col * cell_w + dx] for dy in range(cell_h) for dx in range(cell_w)]
            present = set(px)
            if present == {DARK}:
                line, attrs = line + " ", attrs + "0"
                continue
            fg = LETTER if LETTER in present else SHADE
            others = [c for c in px if c != fg]
            bg = max((DARK, SHADE), key=others.count) if others else DARK
            bits = sum(1 << i for i, c in enumerate(px) if c == fg)
            if bits not in named:
                used.add(bits)
            line += named.get(bits, chr(PUA + bits))
            attrs += str(fg * 3 + bg)
        lines.append(line)
        colours.append(attrs)
    while lines and not lines[0].strip():
        lines.pop(0), colours.pop(0)
    while lines and not lines[-1].strip():
        lines.pop(), colours.pop()
    return lines, colours, used


def write(name, lines, colours):
    (ROOT / f"{name}.txt").write_text("\n".join(lines) + "\n")
    (ROOT / f"{name}.colors").write_text("\n".join(colours) + "\n")


def main():
    # Double resolution: 2 x 4 pixels a cell. Only characters every console
    # font has are used as themselves (▌▐ aren't in latarcyrheb).
    hd, colours, used = cells(compose(**FULL), CELL_W, CELL_H, {0xFF: "█", 0x0F: "▀", 0xF0: "▄"})
    write("logo-hd", hd, colours)
    print(f"logo-hd.txt: {len(hd)} rows, {len(used)} cell patterns needing glyphs")
    # Half resolution: 1 x 2 pixels a cell, half blocks only.
    plain, colours, used = cells(compose(**PLAIN), 1, 2, {3: "█", 1: "▀", 2: "▄"})
    assert not used
    write("logo", plain, colours)
    print(f"logo.txt: {len(plain)} rows")


if __name__ == "__main__":
    main()
