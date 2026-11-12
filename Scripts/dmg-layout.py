"""Writes the Finder window layout of the installer disk image (its .DS_Store).

    dmg-layout.py /Volumes/AbobaXTerm

Done by writing the file directly, so nothing has to drive Finder: no window pops
up during the build and no Automation permission is needed. Positions match
Scripts/art/DmgBackground.svg (660x420; icon centres at 175,190 and 485,190).
"""
import sys

from ds_store import DSStore
from mac_alias import Alias

volume = sys.argv[1]
background = volume + "/.background/background.tiff"

window = {
    "WindowBounds": "{{200, 200}, {660, 448}}",  # 420 of content + the title bar
    "ContainerShowSidebar": False,
    "PreviewPaneVisibility": False,
    "ShowPathbar": False,
    "ShowSidebar": False,
    "ShowStatusBar": False,
    "ShowTabView": False,
    "ShowToolbar": False,
    "SidebarWidth": 180,
}
icons = {
    "viewOptionsVersion": 1,
    "arrangeBy": "none",
    "backgroundType": 2,  # picture
    "backgroundImageAlias": Alias.for_file(background).to_bytes(),
    "backgroundColorRed": 0.1,
    "backgroundColorGreen": 0.1,
    "backgroundColorBlue": 0.1,
    "gridOffsetX": 0.0,
    "gridOffsetY": 0.0,
    "gridSpacing": 100.0,
    "iconSize": 128.0,
    "textSize": 13.0,
    "labelOnBottom": True,
    "showIconPreview": False,
    "showItemInfo": False,
    "scrollPositionX": 0.0,
    "scrollPositionY": 0.0,
}

with DSStore.open(volume + "/.DS_Store", "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["bwsp"] = window
    store["."]["icvp"] = icons
    store["."]["icvl"] = ("type", b"icnv")
    store["AbobaXTerm.app"]["Iloc"] = (175, 190)
    store["Applications"]["Iloc"] = (485, 190)
