#!/usr/bin/env python3
"""Draws Tux for the installer's last screen and writes assets/tux: tux.txt
and tux.colors.

Tux is the Linux mascot, drawn by Larry Ewing with the GIMP
(assets/tux/source.png, scaled down from the usual artwork; free to use,
with that credit). Here he's TUX_W x TUX_H pixels in four of the console's
colours (black, his white belly, yellow beak and feet), on a paint splat
in a fifth, a wide blob behind him with spiky arms and drops; two pixels a
character cell, in half blocks, which every console font has. The splat's
shape comes from SEED (random, but the same every run).

tux.txt holds the characters; tux.colors, for each cell, two characters:
its character's colour and its background's, palette slots as hex digits
(lib/ui.sh's tux_lines turns them into colours), "." for none (whatever
the background is). The console has backgrounds in slots 0-7 only, and
with the 512-glyph font foregrounds too: so the splat is slot 5 (config.sh's
CONSOLE_PALETTE), and the white belly, 15, comes out as 7 with that font.

Needs ffmpeg, to read the image. Run it again only to change the drawing;
the output is committed:
  tools/make-tux.py
"""
import math
import pathlib
import random
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "tux"
W, H = 64, 46            # the canvas, in pixels: 64 x 23 cells
TUX_W, TUX_H = 32, 38    # Tux, centred on it
SEED = 3
BLACK, YELLOW, SPLAT, WHITE = 0, 3, 5, 15


def tux_pixels():
    """Tux as rows of palette slots, None where he isn't."""
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(OUT / "source.png"),
                          "-vf", f"scale={TUX_W}:{TUX_H}:flags=lanczos", "-f", "rawvideo", "-pix_fmt", "rgba", "-"],
                         capture_output=True, check=True).stdout
    px = [[None] * W for _ in range(H)]
    ox, oy = (W - TUX_W) // 2, (H - TUX_H) // 2
    for y in range(TUX_H):
        for x in range(TUX_W):
            r, g, b, a = raw[(y * TUX_W + x) * 4:(y * TUX_W + x) * 4 + 4]
            if a < 128:
                continue
            if r > 150 and g > 100 and b < 90:
                c = YELLOW
            elif 0.3 * r + 0.59 * g + 0.11 * b > 150:
                c = WHITE
            else:
                c = BLACK
            px[y + oy][x + ox] = c
    return px


def splat():
    """The splat's pixels: a round blob (an ellipse whose radius wobbles
    with the angle, a few sine waves of random phase), spiky arms reaching
    out of it, each ending in a drop, and a few loose drops further out."""
    rnd = random.Random(SEED)
    cx, cy, rx, ry = W / 2, H / 2, W * 0.40, H * 0.47
    waves = [(k, rnd.uniform(0, 2 * math.pi), rnd.uniform(0.03, 0.07)) for k in (3, 5, 8, 13)]
    arms = [(rnd.uniform(0, 2 * math.pi), rnd.uniform(1.12, 1.35), rnd.uniform(0.05, 0.10)) for _ in range(7)]
    mask = [[False] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            ux, uy = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
            r, a = math.hypot(ux, uy), math.atan2(uy, ux)
            reach = 1 + sum(amp * math.sin(k * a + ph) for k, ph, amp in waves)
            for aa, length, width in arms:       # an arm: a wedge narrowing outwards
                d = abs((a - aa + math.pi) % (2 * math.pi) - math.pi)
                if d < width:
                    reach = max(reach, 1 + (length - 1) * (1 - d / width))
            mask[y][x] = r <= reach

    def drop(dx, dy, rad):
        for yy in range(H):
            for xx in range(W):
                if (xx + 0.5 - dx) ** 2 + (yy + 0.5 - dy) ** 2 <= rad * rad:
                    mask[yy][xx] = True
    for aa, length, _ in arms:                   # the drop at an arm's end
        drop(cx + math.cos(aa) * rx * (length + 0.10), cy + math.sin(aa) * ry * (length + 0.10),
             rnd.choice((1.0, 1.3, 1.6)))
    for _ in range(6):                           # loose drops
        aa, far = rnd.uniform(0, 2 * math.pi), rnd.uniform(1.15, 1.45)
        drop(cx + math.cos(aa) * rx * far, cy + math.sin(aa) * ry * far, rnd.choice((0.7, 0.9, 1.1)))
    return mask


def cells(px):
    """Half-block characters and their colours, a pair of pixels a cell:
    ▀ the top's colour over the bottom's, ▄ the other way round. A
    background must be slot 0-7, so white (15) is always the character's."""
    hexd = lambda c: "." if c is None else f"{c:x}"
    lines, colours = [], []
    for y in range(0, H, 2):
        line = attrs = ""
        for x in range(W):
            t, b = px[y][x], px[y + 1][x]
            if t is None and b is None:
                ch, fg, bg = " ", None, None
            elif t == b:
                ch, fg, bg = "█", t, None
            elif t is None:
                ch, fg, bg = "▄", b, None
            elif b is None:
                ch, fg, bg = "▀", t, None
            elif b == WHITE:
                ch, fg, bg = "▄", b, t
            else:
                ch, fg, bg = "▀", t, b
            line += ch
            attrs += hexd(fg) + hexd(bg)
        lines.append(line.rstrip())
        colours.append(attrs[:2 * len(lines[-1])])
    return lines, colours


def main():
    px, mask = tux_pixels(), splat()
    for y in range(H):
        for x in range(W):
            if px[y][x] is None and mask[y][x]:
                px[y][x] = SPLAT
    lines, colours = cells(px)
    (OUT / "tux.txt").write_text("\n".join(lines) + "\n")
    (OUT / "tux.colors").write_text("\n".join(colours) + "\n")
    print(f"assets/tux/tux.txt: {W} x {len(lines)} cells")


if __name__ == "__main__":
    main()
