#!/usr/bin/env python3
"""Draw the disk image's background: a white field, a drop panel, an arrow.

The shape every good Mac installer uses, and the reason each part is there:

- **White, not the app's own dark palette.** Finder takes the icon label colour
  from the background picture rather than from Light or Dark mode, so a light
  field gives dark, readable labels for everyone. Checked against a shipping
  installer on a Mac in Dark mode before committing to it.
- **A soft panel behind the Applications folder only.** Behind both, it would
  be decoration; behind the destination alone, it reads as a place to drop
  something.
- **A curved arrow.** A straight line between two icons reads as a divider
  separating them. A curve reads as a hand moving one onto the other.

Nothing else. No logo and no instructions: the two icons are already the
message and the arrow is the verb.

    pip install pillow
    ./make-background.py          # writes background.png next to this script

Drawn several times over size and reduced, because Pillow does not antialias
its own strokes and this picture is nothing but curves.
"""
import math
import os
import sys

from PIL import Image, ImageDraw

import layout as L

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "background.png")

SCALE = 2
SUPERSAMPLE = 4


def bezier(p0, p1, p2, steps=160):
    """Points along a quadratic curve, for drawing it as a polyline."""
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        yield (u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
               u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1])


def main() -> int:
    s = SCALE * SUPERSAMPLE
    im = Image.new("RGB", (L.WIDTH * s, L.HEIGHT * s), L.FIELD)
    d = ImageDraw.Draw(im)

    half = L.PANEL_SIZE / 2
    d.rounded_rectangle(
        [((L.APPLICATIONS_X - half) * s, (L.ICON_Y - half) * s),
         ((L.APPLICATIONS_X + half) * s, (L.ICON_Y + half) * s)],
        radius=L.PANEL_RADIUS * s, fill=L.PANEL)

    width = max(1, round(L.ARROW_STROKE * s))
    curve = [(x * s, y * s) for x, y in
             bezier(L.ARROW_START, L.ARROW_CONTROL, L.ARROW_END)]
    d.line(curve, fill=L.ARROW_INK, width=width, joint="curve")

    # The head follows the curve's own direction at its end, so it looks drawn
    # in one stroke rather than stuck on.
    tip = curve[-1]
    angle = math.atan2(tip[1] - curve[-2][1], tip[0] - curve[-2][0])
    for spread in (2.5, -2.5):
        d.line([tip,
                (tip[0] + L.ARROW_HEAD * s * math.cos(angle + spread),
                 tip[1] + L.ARROW_HEAD * s * math.sin(angle + spread))],
               fill=L.ARROW_INK, width=width)

    im = im.resize((L.WIDTH * SCALE, L.HEIGHT * SCALE), Image.LANCZOS)
    # 72 dpi per point times the scale, so Finder lays the picture out at the
    # window's size rather than drawing it at twice that.
    im.save(OUT, "PNG", dpi=(72 * SCALE, 72 * SCALE))
    print("wrote %s (%dx%d at %d dpi)" % (OUT, L.WIDTH * SCALE, L.HEIGHT * SCALE, 72 * SCALE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
