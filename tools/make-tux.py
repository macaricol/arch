#!/usr/bin/env python3
"""Draws Tux for the installer's last screen and writes assets/tux: tux-hd
and tux, each a .txt and a .colors.

Tux is the Linux mascot, drawn by Larry Ewing with the GIMP
(assets/tux/source.png, scaled down from the usual artwork; free to use,
with that credit). Here he's in four of the console's colours (black, his
white belly, yellow beak and feet) on a paint splat in a fifth, a wide blob
behind him with spiky arms and drops. The splat's shape comes from SEED
(random, but the same every run).

Two drawings of the same picture, 64 x 23 cells. tux-hd at the logo's
resolution, 2 x 4 pixels a cell, in the cell patterns tools/make-logo.py
draws (the private-use character U+E100 + its bits, or a block character):
those the logo uses, and at most NEW_PATTERNS more of its own, which
tools/make-console-fonts.py adds to the console fonts with the logo's; any
other pattern is drawn as its nearest. tux, 1 x 2 pixels a cell in half
blocks, for when those fonts aren't loaded (lib/ui.sh's tux_lines picks,
as logo_file does).

Each .colors line gives each cell two characters: its character's colour
and its background's, palette slots as hex digits, "." for none (whatever
the background is). The console has backgrounds in slots 0-7 only, and
with the 512-glyph font foregrounds too: so the splat is slot 5 (config.sh's
CONSOLE_PALETTE), and the white belly, 15, comes out as 7 with that font.

Needs ffmpeg, to read the image. Run it again only to change the drawing,
then tools/make-console-fonts.py (the patterns) and lib/ui.sh needs
nothing; the output is committed:
  tools/make-tux.py
"""
import collections
import math
import pathlib
import random
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "tux"
LOGO = ROOT / "assets" / "logo" / "logo-hd.txt"
COLS, ROWS = 64, 23      # cells
SEED = 3
NEW_PATTERNS = 15        # the console fonts' room, beyond the logo's patterns
BLACK, YELLOW, SPLAT, WHITE = 0, 3, 5, 15
# How the cell patterns name their bits (tools/make-logo.py): bit n is row
# n // 2, column n % 2 of a 2 x 4 cell; four of them are block characters.
NAMED = {0: " ", 0xFF: "█", 0x0F: "▀", 0xF0: "▄"}
PUA = 0xE100


def picture(cell_w, cell_h):
    """Tux on his splat at cell_w x cell_h pixels a cell: rows of palette
    slots, None where there's neither. Pixels are square on the screen at
    both resolutions (an 8 x 16 cell: 1 x 2 or 2 x 4 of them)."""
    W, H, s = COLS * cell_w, ROWS * cell_h, cell_w   # s: pixels per unit of the half-block drawing
    tw, th = 32 * s, 38 * s
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(OUT / "source.png"),
                          "-vf", f"scale={tw}:{th}:flags=lanczos", "-f", "rawvideo", "-pix_fmt", "rgba", "-"],
                         capture_output=True, check=True).stdout
    px = [[None] * W for _ in range(H)]
    ox, oy = (W - tw) // 2, (H - th) // 2
    for y in range(th):
        for x in range(tw):
            r, g, b, a = raw[(y * tw + x) * 4:(y * tw + x) * 4 + 4]
            if a < 128:
                continue
            if r > 150 and g > 100 and b < 90:
                c = YELLOW
            elif 0.3 * r + 0.59 * g + 0.11 * b > 150:
                c = WHITE
            else:
                c = BLACK
            px[y + oy][x + ox] = c
    drop_specks(px)
    mask = splat(W, H, s)
    for y in range(H):
        for x in range(W):
            if px[y][x] is None and mask[y][x]:
                px[y][x] = SPLAT
    return px


def drop_specks(px, smallest=4):
    """The artwork's shine on Tux's black body, shrunk to a lone white pixel
    or two, back to black: white patches of fewer than smallest pixels (the
    eyes and the belly are far bigger)."""
    H, W, seen = len(px), len(px[0]), set()
    for y in range(H):
        for x in range(W):
            if px[y][x] != WHITE or (y, x) in seen:
                continue
            stack, patch = [(y, x)], []
            seen.add((y, x))
            while stack:
                cy, cx = stack.pop()
                patch.append((cy, cx))
                for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                    if 0 <= ny < H and 0 <= nx < W and (ny, nx) not in seen and px[ny][nx] == WHITE:
                        seen.add((ny, nx))
                        stack.append((ny, nx))
            if len(patch) < smallest:
                for cy, cx in patch:
                    px[cy][cx] = BLACK


def splat(W, H, s):
    """The splat's pixels: a round blob (an ellipse whose radius wobbles
    with the angle, a few sine waves of random phase), spiky arms reaching
    out of it, each ending in a drop, and a few loose drops further out.
    The same shape at any resolution: the drops' sizes scale with s."""
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
        rad *= s
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


def two_colours(pixels):
    """A cell's two colours, its character's and its background's: the two
    it has most of, the background in slots 0-7 (white, 15, is always the
    character's), "none" (None) only ever the background. The others in it
    become whichever of the two is nearer in brightness."""
    common = [c for c, _ in collections.Counter(pixels).most_common(2)]
    if len(common) == 1:
        common.append(None if common[0] is not None else BLACK)
    fg, bg = common
    if fg is None or (bg is not None and bg >= 8):
        fg, bg = bg, fg
    order = {None: 0, BLACK: 0, SPLAT: 1, YELLOW: 2, WHITE: 3}
    return fg, bg, lambda c: c if c in (fg, bg) else min((fg, bg), key=lambda k: abs(order[k] - order[c]))


def hexd(c):
    return "." if c is None else f"{c:x}"


def write(name, lines, colours):
    lines = [l.rstrip() for l in lines]
    colours = [c[:2 * len(l)] for l, c in zip(lines, colours)]
    (OUT / f"{name}.txt").write_text("\n".join(lines) + "\n")
    (OUT / f"{name}.colors").write_text("\n".join(colours) + "\n")


def half_blocks(px):
    """1 x 2 pixels a cell: ▀ the top's colour over the bottom's, ▄ the
    other way round, █ both the same."""
    lines, colours = [], []
    for y in range(0, len(px), 2):
        line = attrs = ""
        for x in range(len(px[0])):
            t, b = px[y][x], px[y + 1][x]
            if t == b:
                ch, fg, bg = (" ", None, None) if t is None else ("█", t, None)
            else:
                fg, bg, _ = two_colours([t, b])
                ch = "▀" if t == fg else "▄"
            line += ch
            attrs += hexd(fg) + hexd(bg)
        lines.append(line)
        colours.append(attrs)
    return lines, colours


def logo_cells(px):
    """2 x 4 pixels a cell, as the logo's patterns: the bits are the
    character's pixels. Patterns the logo doesn't use are limited to the
    NEW_PATTERNS most frequent; the rest become their nearest kept one."""
    grid = []
    for y in range(0, len(px), 4):
        row = []
        for x in range(0, len(px[0]), 2):
            cell = [px[y + n // 2][x + n % 2] for n in range(8)]
            fg, bg, near = two_colours(cell)
            bits = sum(1 << n for n, c in enumerate(cell) if near(c) == fg and fg is not None)
            if fg is None:                      # all background
                bits = 0
            row.append((bits, fg, bg))
        grid.append(row)
    logo = {ord(c) - PUA for c in LOGO.read_text() if ord(c) >= PUA}
    counts = collections.Counter(b for row in grid for b, _, _ in row if b not in NAMED and b not in logo)
    keep = logo | set(NAMED) | {b for b, _ in counts.most_common(NEW_PATTERNS)}
    nearest = {b: min(keep, key=lambda k: bin(k ^ b).count("1")) for b in counts if b not in keep}
    lines, colours = [], []
    for row in grid:
        line = attrs = ""
        for bits, fg, bg in row:
            bits = nearest.get(bits, bits)
            line += NAMED.get(bits) or chr(PUA + bits)
            attrs += ".." if bits == 0 else hexd(fg) + hexd(bg)   # (an empty cell: nothing there)
        lines.append(line)
        colours.append(attrs)
    new = len({ord(c) - PUA for l in lines for c in l if ord(c) >= PUA} - logo)
    return lines, colours, new


def main():
    lines, colours, new = logo_cells(picture(2, 4))
    write("tux-hd", lines, colours)
    print(f"assets/tux/tux-hd.txt: {COLS} x {ROWS} cells, {new} cell patterns beyond the logo's")
    write("tux", *half_blocks(picture(1, 2)))
    print(f"assets/tux/tux.txt: {COLS} x {ROWS} cells, half blocks")


if __name__ == "__main__":
    main()
