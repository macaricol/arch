#!/usr/bin/env python3
"""Builds the images and settings of the archman SDDM theme
(assets/sddm/archman), the login screen made to look like the installer's
unlock screen (lib/prompt.sh's unlock_screen).

The images are rendered with the patched 8x16 console font, exactly as the
console draws them: logo.png from logo-hd.txt, lock.png from the padlock's
15 tiles, dot.png from the round bullet. Main.qml shows them at a whole-number
scale with smoothing off. theme.conf carries the colours and tagline from
config.sh (CONSOLE_PALETTE, TAGLINE).

Run it again after changing the logo, the fonts, the palette or the tagline;
the output is committed:
  tools/make-sddm-theme.py
"""
import importlib.util
import pathlib
import struct
import subprocess
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "sddm" / "archman"

spec = importlib.util.spec_from_file_location("fonts", ROOT / "tools" / "make-console-fonts.py")
fonts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fonts)


def config(expr):
    """A value from config.sh, through bash."""
    return subprocess.run(["bash", "-c", f'source "{ROOT}/config.sh"; printf %s "{expr}"'],
                          check=True, capture_output=True, text=True).stdout


def png(path, pixels, rgb):
    """Writes on/off pixels as an RGBA PNG: rgb where on, transparent elsewhere."""
    colour = bytes.fromhex(rgb)
    raw = b"".join(b"\x00" + b"".join(colour + b"\xff" if on else b"\x00\x00\x00\x00" for on in row)
                   for row in pixels)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", len(pixels[0]), len(pixels), 8, 6, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def render(font, lines):
    """Text drawn with the font's glyphs, one cell per character."""
    index = {}
    for i, entry in enumerate(font["table"]):
        for char in fonts.chars_of(entry):
            index.setdefault(char, i)
    w, h = font["width"], font["height"]
    pixels = [[False] * (w * max(map(len, lines))) for _ in range(h * len(lines))]
    for row, line in enumerate(lines):
        for col, char in enumerate(line):
            if char == " ":
                continue
            glyph = font["glyphs"][index[char]]
            for y in range(h):
                for x in range(w):
                    if fonts.pixel(font, glyph, x, y):
                        pixels[row * h + y][col * w + x] = True
    return pixels


def main():
    font = fonts.load(fonts.OUT / "default8x16.psfu.gz")
    palette = config("${CONSOLE_PALETTE[*]}").split()
    accent, text = palette[14], palette[15]
    OUT.mkdir(parents=True, exist_ok=True)

    logo = (ROOT / "logo-hd.txt").read_text().rstrip("\n").split("\n")
    png(OUT / "logo.png", render(font, logo), accent)
    lock = ["".join(fonts.LOCK[r * fonts.LOCK_COLS:(r + 1) * fonts.LOCK_COLS]) for r in range(fonts.LOCK_ROWS)]
    png(OUT / "lock.png", render(font, lock), accent)
    png(OUT / "dot.png", render(font, [fonts.DOT]), text)

    # The roles lib/ui.sh gives the palette's slots.
    (OUT / "theme.conf").write_text(f"""[General]
tagline={config("$TAGLINE")}
background=#{palette[0]}
taglineColor=#{palette[13]}
border=#{palette[8]}
hint=#{palette[8]}
error=#{palette[9]}
""")
    print(f"{OUT.relative_to(ROOT)}: logo.png, lock.png, dot.png, theme.conf")


if __name__ == "__main__":
    main()
