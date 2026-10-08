#!/usr/bin/env python3
"""Builds the images and settings of the archman SDDM theme
(assets/sddm/archman): an Omarchy-style unlock screen in the installer's
look, the logo over a padlock and a password box.

The images are rendered with the patched 8x16 console font, exactly as the
console draws them: logo.png from logo-hd.txt, lock.png from the padlock's
15 tiles, dot.png from the round bullet (the 12x22 font's: bigger). Main.qml shows them at a whole-number
scale with smoothing off. theme.conf carries the colours and tagline from
config.sh (CONSOLE_PALETTE, TAGLINE).

It also writes assets/logo/banner.png, the same logo on the palette's
background with a margin, for the top of the README.

Run it again after changing the logo, the fonts, the palette or the tagline;
the output is committed:
  tools/make-sddm-theme.py
"""
import importlib.util
import pathlib
import struct
import subprocess
import sys
import zlib

sys.dont_write_bytecode = True   # no __pycache__ from importing the font tool

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "sddm" / "archman"

spec = importlib.util.spec_from_file_location("fonts", ROOT / "tools" / "make-console-fonts.py")
fonts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fonts)


def config(expr):
    """A value from config.sh, through bash."""
    return subprocess.run(["bash", "-c", f'source "{ROOT}/config.sh"; printf %s "{expr}"'],
                          check=True, capture_output=True, text=True).stdout


def png(path, pixels):
    """Writes pixels, each an RGB hex colour or None, as an RGBA PNG; None
    is transparent."""
    raw = b"".join(b"\x00" + b"".join(bytes.fromhex(p) + b"\xff" if p else b"\x00\x00\x00\x00" for p in row)
                   for row in pixels)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", len(pixels[0]), len(pixels), 8, 6, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def render(font, lines, colours=None, palette=None, rgb=None):
    """Text drawn with the font's glyphs, one cell per character, as colours:
    rgb for every glyph pixel, or with colours (lines of hex digits
    fg * 4 + bg, as lib/ui.sh's logo_lines reads them) the palette's slot
    for each; the background (0) is transparent."""
    index = {}
    for i, entry in enumerate(font["table"]):
        for char in fonts.chars_of(entry):
            index.setdefault(char, i)
    w, h = font["width"], font["height"]
    slots = (None, palette[6], palette[2], palette[3]) if palette else None   # background, letters, extrusion, Pac-Man
    pixels = [[None] * (w * max(map(len, lines))) for _ in range(h * len(lines))]
    for row, line in enumerate(lines):
        for col, char in enumerate(line):
            if char == " ":
                continue
            fg, bg = rgb, None
            if colours:
                attr = int(colours[row][col], 16)
                fg, bg = slots[attr // 4], slots[attr % 4]
            glyph = font["glyphs"][index[char]]
            for y in range(h):
                for x in range(w):
                    pixels[row * h + y][col * w + x] = fg if fonts.pixel(font, glyph, x, y) else bg
    return pixels


def main():
    font = fonts.load(fonts.OUT / "default8x16.psfu.gz")
    palette = config("${CONSOLE_PALETTE[*]}").split()
    accent, text = palette[14], palette[15]
    OUT.mkdir(parents=True, exist_ok=True)

    logo = (ROOT / "assets" / "logo" / "logo-hd.txt").read_text().rstrip("\n").split("\n")
    colours = (ROOT / "assets" / "logo" / "logo-hd.colors").read_text().rstrip("\n").split("\n")
    logo_pixels = render(font, logo, colours, palette)
    png(OUT / "logo.png", logo_pixels)
    # The README's banner: on the background, 16 px of it all round.
    margin, w = 16, len(logo_pixels[0])
    blank = [palette[0]] * (w + 2 * margin)
    banner = [blank] * margin + [[palette[0]] * margin + [p or palette[0] for p in row] + [palette[0]] * margin
                                for row in logo_pixels] + [blank] * margin
    png(ROOT / "assets" / "logo" / "banner.png", banner)
    lock = ["".join(fonts.LOCK[r * fonts.LOCK_COLS:(r + 1) * fonts.LOCK_COLS]) for r in range(fonts.LOCK_ROWS)]
    png(OUT / "lock.png", render(font, lock, rgb=accent))
    # The password dots from the 12x22 font: its dot is 7 px across to the
    # 8x16's 5, the nearest a crisp round dot gets to half as big again.
    png(OUT / "dot.png", render(fonts.load(fonts.OUT / "sun12x22.psfu.gz"), [fonts.DOT], rgb=text))

    # The roles lib/ui.sh gives the palette's slots.
    (OUT / "theme.conf").write_text(f"""[General]
tagline={config("$TAGLINE")}
background=#{palette[0]}
taglineColor=#{palette[13]}
border=#{palette[8]}
hint=#{palette[8]}
error=#{palette[9]}
""")
    print(f"{OUT.relative_to(ROOT)}: logo.png, lock.png, dot.png, theme.conf; assets/logo/banner.png")


if __name__ == "__main__":
    main()
