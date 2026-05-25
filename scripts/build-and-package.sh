#!/bin/bash
#
# Full build and packaging workflow: build app → sign → create DMG → notarize → staple.
# Reads developer_id_cert, apple_id, team_id, app_specific_password from secrets.json.
#
# Setup:
#   1. cp secrets.json.example secrets.json
#   2. Edit secrets.json with your certificate name, Apple ID, team ID, app-specific password
#   3. Run from repo root: ./scripts/build-and-package.sh
#
set -e
cd "$(dirname "$0")/.."
[ -x "scripts/build-app.sh" ] || chmod +x scripts/build-app.sh
RELEASE_DIR=".build/release"
PROJECT_RELEASE_DIR="release"
APP_NAME="PowerMate Agent"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" scripts/Info.plist)
DMG_NAME="PowerMateAgent-${VERSION}.dmg"
SECRETS="secrets.json"

if [ ! -f "$SECRETS" ]; then
  echo "Missing $SECRETS — copy secrets.json.example to secrets.json and fill in your values."
  exit 1
fi

# Read and validate secrets (output: 4 lines = cert, apple_id, team_id, password)
SECRETS_OUT=$(python3 - "$SECRETS" << 'PY'
import json, sys
with open(sys.argv[1]) as f:
  d = json.load(f)
keys = ['developer_id_cert', 'apple_id', 'team_id', 'app_specific_password']
for k in keys:
  if k not in d or not str(d[k]).strip():
    sys.exit('secrets.json missing or empty: ' + k)
for k in keys:
  print(d[k])
PY
) || exit 1
vals=()
while IFS= read -r line; do vals+=("$line"); done <<< "$SECRETS_OUT"
DEVELOPER_ID_CERT="${vals[0]}"
APPLE_ID="${vals[1]}"
TEAM_ID="${vals[2]}"
APP_SPECIFIC_PASSWORD="${vals[3]}"

echo "Building app bundle..."
./scripts/build-app.sh

echo "Stripping extended attributes before signing..."
xattr -cr "$RELEASE_DIR/${APP_NAME}.app"

echo "Signing with Developer ID (runtime + entitlements)..."
codesign --force --deep --sign "$DEVELOPER_ID_CERT" \
  --options runtime \
  --entitlements "scripts/PowerMateAgent.entitlements" \
  "$RELEASE_DIR/${APP_NAME}.app"

echo "Creating DMG (app + Applications alias, background image via AppleScript)..."
DMG_VOLNAME="PowerMate Agent"
DMG_STAGING="$RELEASE_DIR/dmg-staging.dmg"
hdiutil detach "/Volumes/${DMG_VOLNAME}" 2>/dev/null || true
hdiutil detach "/Volumes/PowerMateAgent-${VERSION}" 2>/dev/null || true

# Build a temporary read-write DMG from a flat folder.
DMG_LAYOUT="$RELEASE_DIR/dmg-layout"
rm -rf "$DMG_LAYOUT"
mkdir -p "$DMG_LAYOUT"
cp -R "$RELEASE_DIR/${APP_NAME}.app" "$DMG_LAYOUT/"
ln -s /Applications "$DMG_LAYOUT/Applications"
if [ -f "scripts/dmg-background.png" ]; then
  mkdir -p "$DMG_LAYOUT/.background"
  cp "scripts/dmg-background.png" "$DMG_LAYOUT/.background/background.png"
fi

rm -f "$DMG_STAGING"
hdiutil create -volname "$DMG_VOLNAME" -srcfolder "$DMG_LAYOUT" -ov -format UDRW "$DMG_STAGING"
rm -rf "$DMG_LAYOUT"
hdiutil attach "$DMG_STAGING" -mountpoint "/Volumes/${DMG_VOLNAME}"

# Use AppleScript to set window size, icon positions, and background image.
# This is more reliable than a captured .DS_Store because it runs against the
# live mounted volume and doesn't store stale alias paths.
if [ -f "scripts/dmg-background.png" ]; then
  osascript << APPLESCRIPT
  tell application "Finder"
    tell disk "${DMG_VOLNAME}"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 800, 560}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 128
      set background picture of viewOptions to file ".background:background.png"
      set position of item "${APP_NAME}.app" of container window to {130, 195}
      set position of item "Applications" of container window to {495, 195}
      close
      open
      update without registering applications
      delay 3
    end tell
  end tell
APPLESCRIPT
fi

hdiutil detach "/Volumes/${DMG_VOLNAME}"

# Convert to compressed read-only DMG for distribution.
cd "$RELEASE_DIR"
hdiutil convert "dmg-staging.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_NAME"
rm -f "dmg-staging.dmg"
cd ../..

echo "Submitting for notarization..."
xcrun notarytool submit "$RELEASE_DIR/$DMG_NAME" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --wait

echo "Stapling notarization ticket to DMG..."
xcrun stapler staple "$RELEASE_DIR/$DMG_NAME"

mkdir -p "$PROJECT_RELEASE_DIR"
cp "$RELEASE_DIR/$DMG_NAME" "$PROJECT_RELEASE_DIR/$DMG_NAME"

echo "Done. Notarized DMG: $RELEASE_DIR/$DMG_NAME"
echo "Copied to project folder: $PROJECT_RELEASE_DIR/$DMG_NAME"
