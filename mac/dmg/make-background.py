#!/usr/bin/env python3
"""Draw the disk image's background: a light field and one arrow.

Restraint is the whole design. The window has to say "drag that onto this" and
nothing else, so there is no logo, no wordmark and no instructions; the two
icons are already the message and the arrow is the verb. Stats, Rectangle and
most of the Mac apps people already know how to install ship exactly this.

Light grey rather than the app's own dark palette, and that is a decision worth
keeping. Finder draws the icon labels in the system label colour, which follows
Light or Dark mode, while a background picture does not follow anything. A dark
field therefore reads as black text on black for every viewer in Light mode.
A light field is the one choice that cannot fail that way, which is why every
installer in the wild is light.

    pip install pillow
    ./make-background.py          # writes background.png next to this script

Drawn at 4x and reduced, because Pillow's lines have no antialiasing of their
own and the arrow is the only edge in the picture.
"""
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "background.png")

# Points, matching the window content area in make-ds-store.py. The image is
# written at 2x and tagged 144 dpi so Finder draws it at this size, sharp.
WIDTH, HEIGHT = 640, 380
SCALE = 2
# Drawn larger still, then reduced, purely for smooth diagonals.
SUPERSAMPLE = 4

FIELD = (222, 222, 224)
# macOS secondary label, near enough. Full black reads as an instruction
# shouted rather than offered.
INK = (60, 60, 67)

# The arrow sits in the gap between the two 128pt icons, on their centre line.
ARROW_Y = 190
ARROW_FROM, ARROW_TO = 280, 360
STROKE = 2.5
HEAD = 13


def main() -> int:
    s = SCALE * SUPERSAMPLE
    im = Image.new("RGB", (WIDTH * s, HEIGHT * s), FIELD)
    d = ImageDraw.Draw(im)

    y = ARROW_Y * s
    x0, x1 = ARROW_FROM * s, ARROW_TO * s
    w = max(1, round(STROKE * s))
    head = HEAD * s

    d.line([(x0, y), (x1, y)], fill=INK, width=w)
    # A plain chevron, the same weight as the shaft, meeting it at the tip.
    d.line([(x1 - head, y - head), (x1, y)], fill=INK, width=w)
    d.line([(x1 - head, y + head), (x1, y)], fill=INK, width=w)

    im = im.resize((WIDTH * SCALE, HEIGHT * SCALE), Image.LANCZOS)
    # 72 dpi per point times the scale, so Finder lays it out at WIDTH x HEIGHT
    # points rather than drawing it at twice the size.
    im.save(OUT, "PNG", dpi=(72 * SCALE, 72 * SCALE))
    print("wrote %s (%dx%d at %d dpi)" % (OUT, WIDTH * SCALE, HEIGHT * SCALE, 72 * SCALE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
