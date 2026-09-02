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
    ./make-background.py          # the picture this file points at
    ./make-ds-store.py            # writes DS_Store next to this script

package-dmg.sh copies the result into the staging folder as `.DS_Store`.
Re-run it only when the layout below changes.
"""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

import mac_alias
from ds_store import DSStore

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "DS_Store")

# Shared with make-background.py, so the picture is drawn for the layout the
# icons are actually placed in.
import layout as L

# The names have to match the staging folder exactly, or Finder falls back to
# an automatic position and the file is silently useless.
APP_NAME = "Agent Inbox.app"
LINK_NAME = "Applications"

# Must match package-dmg.sh, and the volume name it builds with, because the
# alias below records both.
VOLUME_NAME = "Agent Inbox"
BACKGROUND_IN_VOLUME = ".background/background.png"
BACKGROUND = os.path.join(HERE, "background.png")


def background_references():
    """How Finder names the background picture: an alias and a bookmark.

    Both, because they are two generations of the same idea and Finder does not
    read the older one on its own. A `.DS_Store` carrying only
    `backgroundImageAlias` gets a plain window and no error: checked against a
    disk image built exactly that way, where Finder reported "background
    picture: NONE" while every other setting in the same file applied. The
    bookmark under `pBBk` is what it actually resolves; the alias stays for
    older systems and because every shipping installer still carries one.

    Neither can be made from a path alone. They record the volume a file sits
    on, so a real file on a volume of the right name has to exist. Nothing can
    be written into the finished image, so a throwaway one is built here,
    mounted read-only, measured and discarded, which is why this runs once and
    the result is committed rather than made at build time.
    """
    if not os.path.exists(BACKGROUND):
        sys.exit("run ./make-background.py first: %s is missing" % BACKGROUND)

    tmp = tempfile.mkdtemp()
    mounted = None
    try:
        stage = os.path.join(tmp, "stage")
        os.makedirs(os.path.join(stage, os.path.dirname(BACKGROUND_IN_VOLUME)))
        shutil.copy(BACKGROUND, os.path.join(stage, BACKGROUND_IN_VOLUME))

        image = os.path.join(tmp, "probe.dmg")
        subprocess.run(
            ["hdiutil", "makehybrid", "-hfs", "-hfs-volume-name", VOLUME_NAME,
             "-o", image, stage],
            check=True, stdout=subprocess.DEVNULL)

        # -mountpoint, so a volume of this name already mounted elsewhere does
        # not send us to "Agent Inbox 1" and bake the wrong name into the alias.
        mounted = os.path.join(tmp, "mnt")
        os.makedirs(mounted)
        subprocess.run(
            ["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mounted, image],
            check=True, stdout=subprocess.DEVNULL)

        picture = os.path.join(mounted, BACKGROUND_IN_VOLUME)
        return (mac_alias.Alias.for_file(picture).to_bytes(),
                mac_alias.Bookmark.for_file(picture))
    finally:
        if mounted:
            subprocess.run(["hdiutil", "detach", mounted, "-quiet"], check=False)
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    alias, bookmark = background_references()
    if os.path.exists(OUT):
        os.remove(OUT)

    with DSStore.open(OUT, "w+") as d:
        d["."]["bwsp"] = {
            "WindowBounds": "{{%d, %d}, {%d, %d}}" % (L.LEFT, L.TOP, L.WIDTH, L.HEIGHT + L.TITLE_BAR),
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
            # 2 is "a picture", and the picture is named by the alias.
            "backgroundType": 2,
            "backgroundImageAlias": plistlib.Data(alias)
            if hasattr(plistlib, "Data") else alias,
            "arrangeBy": "none",
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "iconSize": float(L.ICON_SIZE),
            "labelOnBottom": True,
            "showIconPreview": True,
            "showItemInfo": False,
            "textSize": float(L.TEXT_SIZE),
            # Present even though the background is a picture. Finder writes
            # them, so a file without them is not a file Finder wrote.
            "backgroundColorRed": 1.0,
            "backgroundColorGreen": 1.0,
            "backgroundColorBlue": 1.0,
        }
        d["."]["pBBk"] = bookmark
        # Only a few keys have codecs in ds_store; the rest are written as an
        # explicit (type, value) pair.
        d["."]["vSrn"] = ("long", 1)

        d[APP_NAME]["Iloc"] = (L.APP_X, L.ICON_Y)
        d[LINK_NAME]["Iloc"] = (L.APPLICATIONS_X, L.ICON_Y)

    print("wrote %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
