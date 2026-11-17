#!/usr/bin/env bash
# Builds a universal release binary and wraps it into VaultBar.app (LSUIElement,
# no Dock icon). Ad-hoc signed with the hardened runtime; App Sandbox is off
# on purpose, because the app has to spawn the `bw` command line tool.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building universal release binary…"
swift build -c release --arch arm64 --arch x86_64

APP_DIR="$ROOT_DIR/dist/VaultBar.app"
CONTENTS="$APP_DIR/Contents"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cp "$BIN_PATH/VaultBar" "$CONTENTS/MacOS/VaultBar"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

echo "Building app icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT_DIR/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ROOT_DIR/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

echo "Ad-hoc signing (hardened runtime)…"
codesign --force --deep --options runtime --sign - "$APP_DIR"

echo "Built: $APP_DIR"
