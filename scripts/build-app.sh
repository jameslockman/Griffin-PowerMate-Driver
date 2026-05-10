#!/bin/bash
# Builds PowerMate Agent as a release binary and packages it into PowerMate Agent.app
# Run from repo root: scripts/build-app.sh
# Then sign and notarize per DISTRIBUTION.md

set -e
cd "$(dirname "$0")/.."
RELEASE_DIR=".build/release"
APP_NAME="PowerMate Agent"
APP_DIR="$RELEASE_DIR/${APP_NAME}.app"

echo "Building release binary..."
swift build -c release --product PowerMateAgent

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp ".build/release/PowerMateAgent" "$APP_DIR/Contents/MacOS/"
cp "scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "scripts/AppIcon.icns" ]; then
  cp "scripts/AppIcon.icns" "$APP_DIR/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_DIR/Contents/Info.plist"
  echo "Added app icon from scripts/AppIcon.icns"
fi

echo "Created $APP_DIR"
echo "Next: sign and notarize (see DISTRIBUTION.md)"
