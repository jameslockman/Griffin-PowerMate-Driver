#!/bin/bash
#
# Build AppIcon.icns from a single source PNG (e.g. 1024×1024 or 512×512).
# iconutil does NOT accept Xcode's Assets.xcassets/AppIcon.appiconset format;
# it requires a standalone .iconset folder with these exact filenames:
#   icon_16x16.png, icon_32x32.png, icon_128x128.png, icon_256x256.png, icon_512x512.png
#   icon_16x16@2x.png, icon_32x32@2x.png, icon_128x128@2x.png, icon_256x256@2x.png, icon_512x512@2x.png
#
# Usage: ./scripts/make-app-icon.sh /path/to/icon.png
# Creates scripts/AppIcon.icns (and a temp .iconset folder, then removes it).
#
set -e
SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [ -z "$1" ] || [ ! -f "$1" ]; then
  echo "Usage: $0 /path/to/icon.png"
  echo "  Use a 1024×1024 or 512×512 PNG. Creates scripts/AppIcon.icns."
  exit 1
fi
SRC="$1"
ICONSET="$REPO_ROOT/AppIcon.iconset"
OUT="$SCRIPT_DIR/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Required sizes for iconutil (filename -> pixel size)
# @2x filenames are the Retina versions (double the base size)
sips -z 16 16   "$SRC" --out "$ICONSET/icon_16x16.png"
sips -z 32 32   "$SRC" --out "$ICONSET/icon_16x16@2x.png"
sips -z 32 32   "$SRC" --out "$ICONSET/icon_32x32.png"
sips -z 64 64   "$SRC" --out "$ICONSET/icon_32x32@2x.png"
sips -z 128 128 "$SRC" --out "$ICONSET/icon_128x128.png"
sips -z 256 256 "$SRC" --out "$ICONSET/icon_128x128@2x.png"
sips -z 256 256 "$SRC" --out "$ICONSET/icon_256x256.png"
sips -z 512 512 "$SRC" --out "$ICONSET/icon_256x256@2x.png"
sips -z 512 512 "$SRC" --out "$ICONSET/icon_512x512.png"
sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"
echo "Created $OUT"
