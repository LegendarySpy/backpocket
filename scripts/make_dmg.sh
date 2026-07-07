#!/bin/zsh
# Usage: make_dmg.sh <path/to/App.app> <output.dmg>
set -euo pipefail

APP_PATH="$1"
FINAL_DMG="$2"
APP_NAME="$(basename "$APP_PATH" .app)"
STAGING="$(mktemp -d)"
RW_DMG="$STAGING/rw.dmg"
DMG_ROOT="$STAGING/root"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$DMG_ROOT"
cp -R "$APP_PATH" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -fs HFS+ \
    -format UDRW -ov -quiet "$RW_DMG"

MOUNT_DIR="$STAGING/mnt"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -noautoopen -quiet

osascript <<EOF
tell application "Finder"
    tell disk (POSIX file "$MOUNT_DIR" as alias)
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 760, 570}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set position of item "$APP_NAME.app" of container window to {150, 165}
        set position of item "Applications" of container window to {410, 165}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "$MOUNT_DIR" -quiet
rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -quiet -o "$FINAL_DMG"
echo "Created $FINAL_DMG"
