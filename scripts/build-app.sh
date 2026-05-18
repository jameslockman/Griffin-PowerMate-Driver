#!/bin/bash
# Builds PowerMate Agent as a universal (fat) release binary (arm64 + x86_64) and
# packages it into PowerMate Agent.app. Run from repo root: scripts/build-app.sh
# Then sign and notarize per DISTRIBUTION.md
#
# Requires Swift/Xcode that can build both slices (typically Apple Silicon Mac, or
# Intel Mac with a toolchain that supports arm64-apple-macosx cross-compilation).

set -e
cd "$(dirname "$0")/.."
RELEASE_DIR=".build/release"
APP_NAME="PowerMate Agent"
APP_DIR="$RELEASE_DIR/${APP_NAME}.app"

TRIPLE_ARM="arm64-apple-macosx"
TRIPLE_X86="x86_64-apple-macosx"
ARM_BIN=".build/${TRIPLE_ARM}/release/PowerMateAgent"
X86_BIN=".build/${TRIPLE_X86}/release/PowerMateAgent"
UNIVERSAL_BIN=".build/universal/PowerMateAgent"

echo "Building release for Apple Silicon (arm64)..."
swift build -c release --triple "$TRIPLE_ARM" --product PowerMateAgent

echo "Building release for Intel (x86_64)..."
swift build -c release --triple "$TRIPLE_X86" --product PowerMateAgent

if [ ! -f "$ARM_BIN" ] || [ ! -f "$X86_BIN" ]; then
  echo "Missing fat slice binary — expected:" >&2
  echo "  $ARM_BIN" >&2
  echo "  $X86_BIN" >&2
  exit 1
fi

echo "Creating universal binary with lipo..."
mkdir -p ".build/universal"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$UNIVERSAL_BIN"
lipo -info "$UNIVERSAL_BIN"

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$UNIVERSAL_BIN" "$APP_DIR/Contents/MacOS/"
cp "scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "scripts/AppIcon.icns" ]; then
  cp "scripts/AppIcon.icns" "$APP_DIR/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_DIR/Contents/Info.plist"
  echo "Added app icon from scripts/AppIcon.icns"
fi
if [ -d "scripts/Sounds" ] && [ "$(ls scripts/Sounds 2>/dev/null)" ]; then
  cp scripts/Sounds/* "$APP_DIR/Contents/Resources/"
  echo "Copied custom sounds from scripts/Sounds/"
fi
if [ -d "scripts/Icons" ] && ls scripts/Icons/*.icns &>/dev/null; then
  cp scripts/Icons/*.icns "$APP_DIR/Contents/Resources/"
  echo "Copied custom icons from scripts/Icons/"
fi

echo "Created $APP_DIR (universal binary)"
echo "Next: sign and notarize (see DISTRIBUTION.md)"
