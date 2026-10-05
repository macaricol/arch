#!/usr/bin/env python3
"""Draws the ARCHMAN logo and writes logo-hd.txt and logo.txt.

The style is the classic arcade title: chunky letters over a solid copy of
themselves shifted up and left (the extrusion, in its own colour), set edge
to edge so every letter covers the extrusion of the next. H is pixel art on
a grid of 2 px units, M and N blocks with a notch cut from the top, the R
the original's outline with a dot inside; all are drawn as a thick outline
with a dark inside; the C is a solid Pac-Man with his eye cut out; the A's are the Arch
Linux logo's mark, kept solid, rasterised from the copy the filesystem
package installs (/usr/share/pixmaps/archlinux-logo.svg), which needs
rsvg-convert (librsvg) to run this.

The console's own characters can't go finer than logo.txt: half blocks, two
pixels per character cell. logo-hd.txt holds 2 x 4 pixels a cell, so the
logo is 158 x 28 pixels in 79 x 7 cells. Cells that are empty, full or a top
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
WIDTH, HEIGHT = 158, 28        # pixels: 79 x 7 cells of 2 x 4 (the console has 80)
CELL_W, CELL_H = 2, 4
PUA = 0xE100                   # + the cell's bit pattern
# At most this many distinct patterns, which is what the 256-glyph console
# fonts have room for besides tools/make-console-fonts.py's other glyphs.
# Beyond it, the rarest are drawn with their nearest neighbour instead.
MAX_PATTERNS = 62

# The two versions' proportions. Full: 2 px units, 24 px letters, a 3 px
# extrusion, 2 px outlines. Plain (half the resolution) has no room for
# outlines, so its letters are solid over a 2 px extrusion.
FULL = dict(unit=2, top=4, shadow=3, outline=2, width=WIDTH, height=HEIGHT)
PLAIN = dict(unit=1, top=2, shadow=2, outline=0, width=WIDTH // 2, height=HEIGHT // 2)
OUTLINE_A = False              # True: the A's outlined like the rest
# Extra space before a letter, in units: H and M would touch without it.
SPACE_BEFORE = {"M": 2}


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


# H: 12 units tall, 4-unit stems and a 6-unit bar, as in the arcade original.
ART = {
    "H": ["####..####"] * 3 + ["##########"] * 6 + ["####..####"] * 3,
}



def from_art(rows, unit):
    return [[rows[y // unit][x // unit] == "#" for x in range(len(rows[0]) * unit)]
            for y in range(len(rows) * unit)]


def sample(inside, w, h, coverage=0.5):
    """inside(u, v) as a w x h grid, a pixel on if enough of it is covered."""
    return [[sum(inside(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4) for sy in range(4) for sx in range(4))
             >= 16 * coverage for x in range(w)] for y in range(h)]


def in_triangle(u, v, a, b, c):
    """(u, v) inside the triangle a b c."""
    def side(p, q):
        return (q[0] - p[0]) * (v - p[1]) - (q[1] - p[1]) * (u - p[0])
    d1, d2, d3 = side(a, b), side(b, c), side(c, a)
    return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))


def notched(w, h, *triangles):
    """M and N as in the arcade original: a w x h block with triangles cut
    out (corners in fractions of w and h), which the outline then traces.
    Sampled per pixel, so the cuts' sides step one pixel at a time."""
    tris = [[(x * w, y * h) for x, y in t] for t in triangles]
    return sample(lambda u, v: 0 <= u < w and 0 <= v < h
                  and not any(in_triangle(u, v, *t) for t in tris), w, h)


def letter_r(unit):
    """The arcade R's outline: a full-height stem, the bowl's right side one
    half-circle (a D) from the top down to the waist, and the leg's outer
    edge running from the waist out to the bottom-right corner."""
    w, h = 10 * unit, 12 * unit
    bowl = 0.56 * h                                 # the waist's height
    r = bowl / 2                                    # the D's radius
    cx = w - r                                      # its centre's x (and where the leg starts)

    def inside(u, v):
        if not (0 <= u < w and 0 <= v < h):
            return False
        if v < bowl:                                # the bowl: square on the left, round on the right
            return u <= cx or (u - cx) ** 2 + (v - r) ** 2 <= r * r
        return u <= cx + (w - cx) * (v - bowl) / (h - bowl)        # the leg, widening to the corner
    return sample(inside, w, h)


def r_inside(unit):
    """What's drawn over the R's dark inside: a dot in the bowl, as in the
    arcade original, and a wedge of outline pushing into the dark at the
    waist, so bowl and leg read as separate. (The original also traces bowl
    and leg with a thin line; at this size it only cluttered.) Pixels, in
    the letter's box."""
    w, h = 10 * unit, 12 * unit
    wedge = [(0.48 * w, 0.52 * h), (0.64 * w, 0.47 * h), (0.64 * w, 0.68 * h)]
    grid = sample(lambda u, v: math.hypot(u - 0.45 * w, v - 0.24 * h) < 1.2
                  or in_triangle(u, v, *wedge), w, h)
    return [(x, y) for y in range(h) for x in range(w) if grid[y][x]]


def letter_m(unit):
    """A V from the top, across the middle half, pointing 60% of the way down."""
    return notched(11 * unit, 12 * unit, [(0.25, -0.01), (0.75, -0.01), (0.5, 0.6)])


def letter_n(unit):
    """From the left stem's top corner down to the right stem, two thirds of
    the way down; the right stem stays full height."""
    return notched(12 * unit, 12 * unit, [(0.33, -0.01), (0.67, -0.01), (0.67, 0.67)])


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
    over it, inside a dark pixel of outline. R, H, M and N are drawn as an
    outline with a dark inside; Pac-Man and the A's are solid, Pac-Man with
    his eye cut out."""
    letters = [("A", arch_a(10 * unit, 12 * unit), OUTLINE_A), ("R", letter_r(unit), True),
               ("C", pacman(12 * unit), False), ("H", from_art(ART["H"], unit), True),
               ("M", letter_m(unit), True), ("A", arch_a(10 * unit, 12 * unit), OUTLINE_A),
               ("N", letter_n(unit), True)]
    placed, left = [], shadow
    for name, body, outlined in letters:
        left += SPACE_BEFORE.get(name, 0) * unit
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
        # A dark pixel of outline round the letter, between it and the
        # extrusions behind it.
        for y in range(-1, h + 1):
            for x in range(-1, w + 1):
                if not (0 <= y < h and 0 <= x < w and body[y][x]) and any(
                        0 <= y + dy < h and 0 <= x + dx < w and body[y + dy][x + dx]
                        for dy in (-1, 0, 1) for dx in (-1, 0, 1)):
                    put(top + y, left + x, DARK)
        for y in range(h):
            for x in range(w):
                if body[y][x]:
                    put(top + y, left + x, DARK if inner[y][x] else LETTER)
        if name == "R" and outline:                           # the R's dot and waist
            for x, y in r_inside(unit):
                put(top + y, left + x, LETTER)
        if name == "C":                                       # Pac-Man's eye
            for y in range(round(2.5 * unit), round(4 * unit)):
                for x in range(5 * unit, round(6.5 * unit)):
                    put(top + y, left + x, DARK)
    return canvas


def limit_patterns(lines, named, bits):
    """Merges the rarest private-use patterns into their nearest (fewest
    pixels apart) remaining one until at most MAX_PATTERNS are left."""
    def pattern(c):
        return ord(c) - PUA if ord(c) >= PUA else next((b for b, n in named.items() if n == c), None)
    counts = {}
    for line in lines:
        for c in line:
            if ord(c) >= PUA:
                counts[c] = counts.get(c, 0) + 1
    while len(counts) > MAX_PATTERNS:
        rare = min(counts, key=counts.get)
        del counts[rare]
        choices = list(counts) + [n for n in named.values() if n != " "]
        near = min(choices, key=lambda c: bin(pattern(c) ^ pattern(rare)).count("1"))
        lines = [line.replace(rare, near) for line in lines]
        if near in counts:
            counts[near] += 1
    return lines


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
            line += named.get(bits, chr(PUA + bits))
            attrs += str(fg * 3 + bg)
        lines.append(line)
        colours.append(attrs)
    lines = limit_patterns(lines, named, cell_w * cell_h)
    used = {ord(c) - PUA for line in lines for c in line if ord(c) >= PUA}
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
