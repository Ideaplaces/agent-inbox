#!/usr/bin/env python3
"""Write the .DS_Store that gives the disk image its window.

A DMG with no .DS_Store opens at whatever size and icon scale Finder last
felt like, which is the small cramped window this replaces. Every polished Mac
installer ships one: it is the only place Finder records window size, icon
size and where each icon sits.

Generated rather than arranged by hand, and committed, for one reason: the
usual way to make one is to mount the image read-write and drive Finder with
AppleScript, and this project cannot mount read-write. Managed Macs and CI
runners force disk images read-only, which is why the image is built with
`hdiutil makehybrid` in the first place. Writing the file directly needs no
mount, no Finder and no GUI, so it runs the same on CI as it does here.

    pip install ds-store mac_alias
    ./make-ds-store.py            # writes DS_Store next to this script

package-dmg.sh copies the result into the staging folder as `.DS_Store`.
Re-run it only when the layout below changes.
"""
import os
import sys

from ds_store import DSStore

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "DS_Store")

# The window, in points. 640x400 is wide enough to put the two icons well
# apart at 128pt without the drag looking like a shuffle.
WIDTH, HEIGHT = 640, 400
# Where the window opens on screen. Finder clamps this to the display, so a
# modest offset is safer than trying to centre it for a screen we cannot see.
LEFT, TOP = 200, 140

ICON_SIZE = 128
# Both icons on one line, each centred in its half of the window.
ICON_Y = 190
APP_X = 160
APPLICATIONS_X = 480

# The names have to match the staging folder exactly, or Finder falls back to
# an automatic position and the file is silently useless.
APP_NAME = "Agent Inbox.app"
LINK_NAME = "Applications"


def main() -> int:
    if os.path.exists(OUT):
        os.remove(OUT)

    with DSStore.open(OUT, "w+") as d:
        d["."]["bwsp"] = {
            "WindowBounds": "{{%d, %d}, {%d, %d}}" % (LEFT, TOP, WIDTH, HEIGHT),
            # An installer window is two icons and an instruction. Every strip
            # of chrome on it is another thing that is not the app.
            "ShowSidebar": False,
            "ShowToolbar": False,
            "ShowStatusBar": False,
            "ShowPathbar": False,
            "SidebarWidth": 0,
        }
        d["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 0,
            "arrangeBy": "none",
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "iconSize": float(ICON_SIZE),
            "labelOnBottom": True,
            "showIconPreview": False,
            "showItemInfo": False,
            "textSize": 13.0,
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
        }
        # Icon view, rather than whatever the viewer last used elsewhere.
        # Only a few keys have codecs in ds_store; the rest are written as an
        # explicit (type, value) pair.
        d["."]["ICVO"] = ("bool", True)
        d["."]["vSrn"] = ("long", 1)

        d[APP_NAME]["Iloc"] = (APP_X, ICON_Y)
        d[LINK_NAME]["Iloc"] = (APPLICATIONS_X, ICON_Y)

    print("wrote %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
