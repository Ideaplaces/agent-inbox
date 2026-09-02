"""The disk image window's geometry, in points, shared by both generators.

One file because two of them need the same numbers and a disagreement is
invisible: the picture would be drawn for one layout and the icons placed for
another, and the arrow would point at nothing. The window is 20pt taller than
the content, which is the title bar.
"""

# Content area. The picture is drawn at exactly this size, at 2x.
WIDTH, HEIGHT = 640, 420
TITLE_BAR = 20
# Where the window opens. Finder clamps to the display, so a modest offset
# beats trying to centre it on a screen we cannot see.
LEFT, TOP = 200, 140

ICON_SIZE = 128
TEXT_SIZE = 14

# Both icons on one line. The app on the left, the folder it is dragged to on
# the right, far enough apart that the gap is obviously meant to be crossed.
ICON_Y = 200
APP_X = 168
APPLICATIONS_X = 472

# A soft panel behind the destination only, which is what makes it read as a
# place to drop something rather than a second thing to look at.
PANEL_SIZE = 216
PANEL_RADIUS = 28

# A curved arrow, not a straight one. A straight line reads as a divider
# between two icons; a curve reads as a hand moving one onto the other.
ARROW_START = (250, 224)
ARROW_CONTROL = (300, 172)
ARROW_END = (348, 198)
ARROW_STROKE = 2.5
ARROW_HEAD = 15

FIELD = (255, 255, 255)
PANEL = (238, 240, 252)
ARROW_INK = (138, 143, 168)
