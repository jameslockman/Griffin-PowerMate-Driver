#!/bin/bash
# One-time setup: create scripts/dmg.DS_Store so the DMG opens with large icon view.
# Run from repo root: ./scripts/make-dmg-dsstore.sh
# Then commit scripts/dmg.DS_Store. After that, create-dmg and build-and-package
# copy it into the layout and skip the mount/AppleScript step.

set -e
SCRIPT_DIR="$(dirname "$0")"
cd "$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="PowerMate Agent"
LAYOUT="/tmp/powermate-dmg-dsstore-layout"
OUT="$SCRIPT_DIR/dmg.DS_Store"

rm -rf "$LAYOUT"
mkdir -p "$LAYOUT"
# Same names as in the real DMG so the .DS_Store applies
mkdir -p "$LAYOUT/${APP_NAME}.app"
ln -s /Applications "$LAYOUT/Applications"

echo "Opening layout in Finder; set icon view to 128 and close the window..."
open "$LAYOUT"
echo "Waiting 3 seconds for Finder to open..."
sleep 3
osascript <<'APPLESCRIPT'
tell application "Finder"
  set w to front window
  set current view of w to icon view
  set opts to the icon view options of w
  set icon size of opts to 128
  set arrangement of opts to not arranged
  close w
end tell
APPLESCRIPT
echo "Waiting for Finder to write .DS_Store..."
sleep 3
if [ -f "$LAYOUT/.DS_Store" ]; then
  cp "$LAYOUT/.DS_Store" "$OUT"
  echo "Created $OUT"
else
  echo "No .DS_Store found. Try closing the Finder window and run again."
  exit 1
fi
rm -rf "$LAYOUT"
