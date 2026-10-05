#!/usr/bin/env python3
"""Draws the PACMAN logo at double resolution and writes logo-hd.txt.

The console's own characters can't go finer than logo.txt: half blocks, two
pixels per character cell. Here every cell holds 2 x 4 pixels, so the logo is
144 x 28 pixels in the same 72 x 7 cells. Cells that are empty, full or a
top or bottom half use those characters; any other pattern is the private-use
character U+E100 + its bit pattern (bit 0 top-left, bit 1 top-right, then
row by row), which tools/make-console-fonts.py draws into the console fonts.
lib/ui.sh shows this logo only on the console, where those fonts are loaded,
and logo.txt everywhere else.

Run it again only to change the drawing; the output is committed:
  tools/make-logo.py
"""
import math
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "logo-hd.txt"
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


def letter_a(u, v):
    arch = rounded_rect(u, v, 0, 0, 20, 20, (10, 10, 0, 0)) and not \
        rounded_rect(u, v, STROKE, STROKE, 20 - STROKE, 21, (6, 6, 0, 0))
    bar = 0 <= u <= 20 and 10 <= v <= 10 + STROKE
    return arch or bar


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


def logo(x, y):
    """The whole logo, in pixel coordinates."""
    parts, left = [], 0
    for shape, size in ((letter_p, LETTER), (letter_a, LETTER), (pacman, 24),
                        (letter_m, LETTER), (letter_a, LETTER), (letter_n, LETTER)):
        parts.append((shape, left, size))
        left += size + GAP
    for shape, left, size in parts:
        if left <= x < left + size:
            top = TOP - (size - LETTER) // 2
            return 0 <= y - top <= size and shape(x - left, y - top)
    return False


def main():
    # Each pixel on if most of it is covered (4 x 4 samples).
    pixels = [[sum(logo(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4) for sy in range(4) for sx in range(4)) >= 8
               for x in range(WIDTH)] for y in range(HEIGHT)]
    # Only characters every console font has (▌▐ aren't in latarcyrheb).
    named = {0: " ", 0xFF: "█", 0x0F: "▀", 0xF0: "▄"}
    lines, used = [], set()
    for row in range(HEIGHT // CELL_H):
        line = ""
        for col in range(WIDTH // CELL_W):
            bits = sum(1 << (dy * CELL_W + dx)
                       for dy in range(CELL_H) for dx in range(CELL_W)
                       if pixels[row * CELL_H + dy][col * CELL_W + dx])
            if bits not in named:
                used.add(bits)
            line += named.get(bits, chr(PUA + bits))
        lines.append(line)
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    OUT.write_text("\n".join(lines) + "\n")
    print(f"{OUT.name}: {len(lines)} rows, {len(used)} cell patterns needing glyphs")


if __name__ == "__main__":
    main()
