#!/bin/sh
# Rebuilds the app icon (all sizes of the AppIcon set) from Scripts/art/AppIcon.svg.
# Run through `make icon` after editing the SVG; the PNGs are kept in git.
set -eu
cd "$(dirname "$0")/.."
SRC=Scripts/art/AppIcon.svg
SET=App/Assets.xcassets/AppIcon.appiconset

rm -f "$SET"/*.png
swift Scripts/render-svg.swift "$SRC" \
    "$SET/icon_16x16.png" 16       "$SET/icon_16x16@2x.png" 32 \
    "$SET/icon_32x32.png" 32       "$SET/icon_32x32@2x.png" 64 \
    "$SET/icon_128x128.png" 128    "$SET/icon_128x128@2x.png" 256 \
    "$SET/icon_256x256.png" 256    "$SET/icon_256x256@2x.png" 512 \
    "$SET/icon_512x512.png" 512    "$SET/icon_512x512@2x.png" 1024
chmod 644 "$SET"/*.png
echo "Updated $SET"
