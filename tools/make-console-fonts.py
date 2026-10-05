#!/usr/bin/env python3
"""Builds assets/consolefonts/: the three console fonts lib/ui.sh picks
from, each with two glyphs redrawn as Pac-Man.

  ᗧ (U+15E7)  Pac-Man, mouth open to the right: the message tag
  ⬤ (U+2B24)  Pac-Man, mouth closed: the same circle, for the spinner's chomp

The console can't show emoji or colour glyphs, and no stock console font has
either character, so they take over the slots of two glyphs the installer
never prints (old DOS symbols like ☺ ♀, or Hebrew letters in the 512-glyph
font). Both are drawn as one circle as tall as the font's capital O, centred
on it, so they sit in a line of text like a letter.

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
MOUTH_DEGREES = 38   # half the opening, measured from the horizontal
# Slots to give up, in order of preference.
SPARE = list("☺☻♀♂♪♫☼") + [chr(c) for c in range(0x5D0, 0x5EB)]


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
        assert len(spare) >= 2, f"{name}: no spare glyph slots"
        for slot, char, mouth in ((spare[0], PACMAN, MOUTH_DEGREES), (spare[1], CLOSED, 0)):
            font["glyphs"][slot] = draw(font, mouth)
            font["table"][slot] = char.encode()
        save(font, OUT / f"{name}.psfu.gz")
        print(f"{name}: {font['width']}x{font['height']}, slots {spare[0]} and {spare[1]}")


if __name__ == "__main__":
    main()
