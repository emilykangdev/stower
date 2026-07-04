"""dmgbuild settings for Stower's drag-to-Applications release DMG.

Usage (see .github/workflows/release.yml):
    dmgbuild -s Scripts/release/dmg_settings.py \
             -D app=<path to Stower.app> -D background=<path to multi-res TIFF> \
             "Stower <version>" <output>.dmg

This is a plain Python file read by dmgbuild at build time: module-level names
ARE the settings, and `-D key=value` on the command line populates the
`defines` dict dmgbuild injects into this file's globals. No Finder/AppleScript
involved (unlike create-dmg), so this runs headless on CI (A3 — see the plan's
Assumption A3 / Judgment Call JC1).
"""

import os.path

# `defines` is injected by dmgbuild from -D key=value on the command line.
application = defines.get("app")  # noqa: F821 — e.g. ".../Build/Products/Release/Stower.app"
appname = os.path.basename(application)  # "Stower.app" — keys icon_locations/hide_extensions below

# Multi-res TIFF (1x 660x400 + 2x 1320x800), built by the release.yml step via
# sips + tiffutil -cathidpicheck. A raw @2x PNG here sizes the window to 1320
# POINTS (2x too big) — see Known gotcha #3 in the plan. Do not pass the PNG directly.
background = defines.get("background")  # noqa: F821

# Volume format: UDZO (read-only, zlib-compressed) — same default create-dmg used.
format = "UDZO"

# Exactly one payload item: the stapled, codesigned app.
files = [application]

# Drag-to-Applications affordance.
symlinks = {"Applications": "/Applications"}

# Hide the ".app" extension on the label (PLURAL — dmgbuild's real setting name;
# the singular `hide_extension` is silently ignored. See the plan's gotcha #... /
# JC — grounded against dmgbuild's docs, not the (wrong) singular in some older guides.
hide_extensions = [appname]

# Window layout — matches the old create-dmg --window-pos/--window-size.
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"

# Icon layout — matches the old create-dmg --icon-size / --icon / --app-drop-link
# coordinates (arrow ends; no y-flip; y=200 is the window midline).
icon_size = 120
icon_locations = {appname: (165, 200), "Applications": (495, 200)}

# Keep the volume window minimal — matches create-dmg's default chrome.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
