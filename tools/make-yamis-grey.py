#!/usr/bin/env python3
"""Builds assets/icons/YAMIS-Grey: the icon theme the ARCHMAN look applies.
It's YAMIS (yet another monochrome icon set, by Dirn, GPL-3; config.sh's
ICON_THEME), which it inherits, with its folders, Trash and Recent Files
icons toned down: each drawn at 70% opacity. YAMIS fills them with the
colour scheme's text colour, near white on a dark scheme and much brighter
than its line icons; at 70% they're a soft grey, and still follow the
colour scheme.

Run it again only to change which icons, or how much; the output is
committed:
  tools/make-yamis-grey.py YAMIS_DIR    (a checkout of ICON_THEME_REPO)
"""
import pathlib
import re
import shutil
import sys

OPACITY = 0.7
# Per directory, the icons toned down: by the start of their names.
ICONS = {
    "places/16": ("folder", "inode-directory", "user-home", "user-desktop", "user-trash", "document-open-recent"),
    "places/scalable": ("folder", "inode-directory", "user-home", "user-desktop", "user-trash"),
    "mimetypes/scalable": ("folder", "inode-directory", "application-x-trash"),   # folder_tar: archives
    "actions/16": ("document-open-recent",),
}
OUT = pathlib.Path(__file__).resolve().parent.parent / "assets" / "icons" / "YAMIS-Grey"


def main():
    src = pathlib.Path(sys.argv[1])
    shutil.rmtree(OUT, ignore_errors=True)
    count = 0
    for directory, starts in ICONS.items():
        (OUT / directory).mkdir(parents=True)
        for icon in sorted((src / directory).glob("*.svg")):
            if not icon.name.startswith(starts):
                continue
            # The whole drawing in a group at OPACITY. (A link's target's
            # drawing: the copy stands on its own.)
            svg = icon.resolve().read_text()
            start = re.search(r"<svg\b[^>]*>", svg).end()
            end = svg.rindex("</svg>")
            svg = f'{svg[:start]}<g opacity="{OPACITY}">{svg[start:end]}</g>{svg[end:]}'
            (OUT / directory / icon.name).write_text(svg)
            count += 1
    # YAMIS' own index, renamed, inheriting it, listing only these
    # directories (the others' sections, unused, kept as they are).
    index = (src / "index.theme").read_text()
    index = re.sub(r"^Name=.*$", "Name=YAMIS Grey", index, count=1, flags=re.M)
    index = re.sub(r"^Comment=.*$", f"Comment=YAMIS by Dirn, its folders, Trash and Recent Files at {round(OPACITY * 100)}%",
                   index, count=1, flags=re.M)
    index = re.sub(r"^Inherits=", "Inherits=YAMIS,", index, count=1, flags=re.M)
    index = re.sub(r"^Directories=.*$", "Directories=" + ",".join(ICONS), index, count=1, flags=re.M)
    (OUT / "index.theme").write_text(index)
    shutil.copy(src / "LICENSE", OUT / "LICENSE")
    shutil.copy(src / "Authors", OUT / "Authors")
    print(f"{OUT}: {count} icons")


if __name__ == "__main__":
    main()
