#!/bin/bash
# Creates PowerMateAgent-1.0.0.dmg from the signed .app in .build/release.
# Run from repo root after building and signing: ./scripts/create-dmg.sh
#
# If you get "Operation not permitted": grant Terminal (or your terminal app)
# Full Disk Access in System Settings → Privacy & Security → Full Disk Access,
# then restart the terminal and run this again.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
RELEASE_DIR=".build/release"
APP_NAME="PowerMate Agent"
DMG_NAME="PowerMateAgent-1.0.0.dmg"

# Use a volume name that's unlikely to be already mounted (avoids conflicts)
VOL_NAME="PowerMateAgent-1.0.0"

if [ ! -d "$RELEASE_DIR/${APP_NAME}.app" ]; then
  echo "Missing $RELEASE_DIR/${APP_NAME}.app — run scripts/build-app.sh first."
  exit 1
fi

# Unmount if something is already at this volume name
hdiutil detach "/Volumes/$VOL_NAME" 2>/dev/null || true

# Build layout: app + Applications alias (symlink) + optional .DS_Store for icon view
DMG_LAYOUT="$RELEASE_DIR/dmg-layout"
rm -rf "$DMG_LAYOUT"
mkdir -p "$DMG_LAYOUT"
cp -R "$RELEASE_DIR/${APP_NAME}.app" "$DMG_LAYOUT/"
ln -s /Applications "$DMG_LAYOUT/Applications"
if [ -f "$SCRIPT_DIR/dmg.DS_Store" ]; then
  cp "$SCRIPT_DIR/dmg.DS_Store" "$DMG_LAYOUT/.DS_Store"
fi

cd "$RELEASE_DIR"
echo "Creating $DMG_NAME..."
hdiutil create -volname "$VOL_NAME" -srcfolder "dmg-layout" -ov -format UDZO -imagekey zlib-level=9 "$DMG_NAME"
rm -rf dmg-layout
cd ../..

echo "Created $RELEASE_DIR/$DMG_NAME"
