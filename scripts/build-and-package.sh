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
APP_NAME="PowerMate Agent"
DMG_NAME="PowerMateAgent-1.0.0.dmg"
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

echo "Signing with Developer ID (runtime)..."
codesign --force --deep --sign "$DEVELOPER_ID_CERT" \
  --options runtime \
  "$RELEASE_DIR/${APP_NAME}.app"

echo "Creating DMG (app + Applications alias, .DS_Store for large icon view)..."
hdiutil detach "/Volumes/PowerMate Agent" 2>/dev/null || true
hdiutil detach "/Volumes/PowerMateAgent-1.0.0" 2>/dev/null || true
DMG_LAYOUT="$RELEASE_DIR/dmg-layout"
rm -rf "$DMG_LAYOUT"
mkdir -p "$DMG_LAYOUT"
cp -R "$RELEASE_DIR/${APP_NAME}.app" "$DMG_LAYOUT/"
ln -s /Applications "$DMG_LAYOUT/Applications"
if [ -f "scripts/dmg.DS_Store" ]; then
  cp "scripts/dmg.DS_Store" "$DMG_LAYOUT/.DS_Store"
fi
cd "$RELEASE_DIR"
hdiutil create -volname "PowerMateAgent-1.0.0" -srcfolder "dmg-layout" -ov -format UDZO -imagekey zlib-level=9 "$DMG_NAME"
rm -rf dmg-layout
cd ../..

echo "Submitting for notarization..."
xcrun notarytool submit "$RELEASE_DIR/$DMG_NAME" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --wait

echo "Stapling notarization ticket to DMG..."
xcrun stapler staple "$RELEASE_DIR/$DMG_NAME"

echo "Done. Notarized DMG: $RELEASE_DIR/$DMG_NAME"
