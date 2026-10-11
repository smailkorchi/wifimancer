# dmgbuild settings file. Driven by Scripts/dmg.sh — env vars supply the
# absolute paths so this file isn't directory-dependent.
#
# Why dmgbuild instead of raw AppleScript?
# AppleScript's `set background picture` against a fresh disk sometimes writes
# only `backgroundColorBlue/Red/Green/backgroundType=1` into .DS_Store and
# never persists `backgroundImageAlias` — the styling looks fine in Finder
# during the script run but is missing once the image is detached and
# reattached. dmgbuild writes the .DS_Store directly via the `ds_store`
# library, deterministically, so "set bg" always sticks.

import os

PKG_PATH        = os.environ["WM_PKG"]            # absolute path to .pkg
README_PATH     = os.environ["WM_README"]         # absolute path to install txt
LICENSE_PATH    = os.environ["WM_LICENSE"]        # absolute path to license
BACKGROUND_PATH = os.environ["WM_BG"]             # absolute path to bg tiff
VOLUME_ICON     = os.environ.get("WM_VOLICON", "")  # may be empty if no .icns

# ---- Image properties ---------------------------------------------------

format = os.environ.get("WM_FORMAT", "UDZO")
filesystem = "HFS+"
size = None  # let dmgbuild auto-size

# ---- Files placed in the DMG -------------------------------------------

# Renamed during placement: PKG → "Wifi Mancer Installer.pkg",
# README → "READ ME FIRST.txt", LICENSE → "LICENSE.txt".
files = [
    (PKG_PATH,      "Wifi Mancer Installer.pkg"),
    (README_PATH,   "READ ME FIRST.txt"),
    (LICENSE_PATH,  "LICENSE.txt"),
]

# ---- Window styling ----------------------------------------------------

# 720×440 window matching the rendered background. Positions correspond to
# the STEP markers + arrow drawn into the image.
window_rect = ((200, 120), (720, 440))
icon_size = 128
text_size = 12

icon_locations = {
    # Two primary items mirror-spaced around the center of the empty middle
    # band (the bg deliberately leaves that band clear). License is parked
    # small in the bottom-right corner — secondary, but reachable.
    "Wifi Mancer Installer.pkg": (200, 215),
    "READ ME FIRST.txt":         (520, 215),
    "LICENSE.txt":               (660, 380),
}

# Background picture — dmgbuild copies this into a hidden `.background/`
# folder inside the DMG and writes the alias into .DS_Store.
background = BACKGROUND_PATH

# Hide the toolbar/sidebar/statusbar; large icons; no auto-arrange.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# Volume icon shown in Finder + in the title bar.
if VOLUME_ICON and os.path.isfile(VOLUME_ICON):
    icon = VOLUME_ICON

# Default to icon view, no item arrangement.
default_view = "icon-view"
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 12
