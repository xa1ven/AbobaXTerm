#!/bin/sh
# Packs a built app into the installer disk image: the app and an Applications
# shortcut on a background with an arrow, and the app icon on the mounted volume.
#   Scripts/make-dmg.sh path/to/AbobaXTerm.app path/to/out.dmg
# The window layout is written straight into the image's .DS_Store by
# Scripts/dmg-layout.py; its two Python modules are fetched once into build/dmg-tools.
set -eu
APP=$1
DMG=$2
cd "$(dirname "$0")/.."
NAME=AbobaXTerm
WORK=$(mktemp -d /tmp/abx-dmg.XXXXXX)
MOUNT=
cleanup() {
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Python modules that write .DS_Store (kept in build/, fetched on the first run).
TOOLS=build/dmg-tools
if ! "$TOOLS/bin/python3" -c 'import ds_store, mac_alias' 2>/dev/null; then
    rm -rf "$TOOLS"
    python3 -m venv "$TOOLS"
    "$TOOLS/bin/pip" install --quiet --disable-pip-version-check ds-store==1.3.1 mac-alias==2.2.2
fi

# Background (1x + 2x in one TIFF) and the volume icon.
swift Scripts/render-svg.swift Scripts/art/DmgBackground.svg "$WORK/bg.png" 660x420 "$WORK/bg@2x.png" 1320x840
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1
cp -R App/Assets.xcassets/AppIcon.appiconset "$WORK/icon.iconset"
rm "$WORK/icon.iconset/Contents.json"
iconutil -c icns "$WORK/icon.iconset" -o "$WORK/VolumeIcon.icns"

mkdir "$WORK/image" "$WORK/image/.background"
ditto "$APP" "$WORK/image/$NAME.app"
ln -s /Applications "$WORK/image/Applications"
cp "$WORK/background.tiff" "$WORK/image/.background/background.tiff"
cp "$WORK/VolumeIcon.icns" "$WORK/image/.VolumeIcon.icns"

# A writable image first: the layout refers to the background by its place on the volume.
hdiutil create -quiet -volname "$NAME" -srcfolder "$WORK/image" -ov -format UDRW -fs HFS+ "$WORK/rw.dmg"
MOUNT=$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1)
[ -d "$MOUNT" ] || { echo "cannot mount the image" >&2; exit 1; }
SetFile -a C "$MOUNT"
"$TOOLS/bin/python3" Scripts/dmg-layout.py "$MOUNT"

sync
hdiutil detach "$MOUNT" -quiet || { sleep 2; hdiutil detach "$MOUNT" -force -quiet; }
MOUNT=
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG"
echo "Created $DMG"
