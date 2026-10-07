#!/usr/bin/env python3
"""Draws the ARCHMAN logo straight onto the framebuffer: centred, two thirds
of the screen's width, pixels kept sharp (nearest neighbour), on the
palette's background. The USB's start-up script (tools/build-autoinstall-iso.sh)
shows it for a few seconds before the installer takes over; the console's
own characters can't scale the logo to a proportion of the screen.

  fb-logo.py LOGO.txt LOGO.colors BACKGROUND LETTERS EXTRUSION

The colours are RGB hex. The logo files are assets/logo/logo-hd.*: a cell a
character, 2 x 4 pixels, its pattern the character (U+E100 + bits, or one of
the block characters) and its two colours a digit, fg * 3 + bg. Only 32-bit
framebuffers are drawn; anything else exits 1, and the caller falls back to
a text splash. On success it prints the logo's bottom edge and the screen's
height, in pixels, so the caller can put a line of text just under it.
"""
import os
import sys

NAMED = {" ": 0, "█": 0xFF, "▀": 0x0F, "▄": 0xF0}
CELL_W, CELL_H = 2, 4


def logo_pixels(text_path, colour_path):
    """The logo as rows of colour indices: 0 background, 1 letters, 2 extrusion."""
    lines = open(text_path, encoding="utf-8").read().rstrip("\n").split("\n")
    attrs = open(colour_path).read().rstrip("\n").split("\n")
    rows = [[0] * (len(lines[0]) * CELL_W) for _ in range(len(lines) * CELL_H)]
    for r, line in enumerate(lines):
        for c, char in enumerate(line):
            bits = NAMED.get(char, ord(char) - 0xE100)
            fg, bg = divmod(int(attrs[r][c]), 3)
            for dy in range(CELL_H):
                for dx in range(CELL_W):
                    on = bits >> (dy * CELL_W + dx) & 1
                    rows[r * CELL_H + dy][c * CELL_W + dx] = fg if on else bg
    return rows


def sysfs(name):
    with open(f"/sys/class/graphics/fb0/{name}") as f:
        return f.read().strip()


def main():
    text_path, colour_path, *hexes = sys.argv[1:]
    if sysfs("bits_per_pixel") != "32":
        sys.exit(1)
    # The visible mode (the virtual size can be taller, for panning).
    mode = sysfs("modes").split("\n")[0]                     # e.g. U:1280x800p-0
    width, height = (int(n) for n in mode.split(":")[1].split("p")[0].split("x"))
    stride = int(sysfs("stride"))
    # XRGB8888, little-endian: blue, green, red, unused.
    colours = [bytes.fromhex(h)[::-1] + b"\xff" for h in hexes]

    logo = logo_pixels(text_path, colour_path)
    scale = width * 2 / 3 / len(logo[0])
    w, h = round(len(logo[0]) * scale), round(len(logo) * scale)
    left, top = (width - w) // 2, (height - h) // 2

    background = colours[0] * width
    rows = {}
    with open("/dev/fb0", "r+b", buffering=0) as fb:
        for y in range(height):
            line = background
            if top <= y < top + h:
                src = min(int((y - top) / scale), len(logo) - 1)
                if src not in rows:
                    row = logo[src]
                    rows[src] = b"".join(colours[row[min(int(x / scale), len(row) - 1)]] for x in range(w))
                line = background[:left * 4] + rows[src] + background[(left + w) * 4:]
            os.pwrite(fb.fileno(), line, y * stride)
    print(top + h, height)


if __name__ == "__main__":
    main()
