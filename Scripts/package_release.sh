#!/usr/bin/env bash
# Builds VaultBar.app, wraps it in a DMG for a GitHub release and prints the
# sha256 the Homebrew cask needs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/Scripts/build_app.sh"

DMG="$ROOT_DIR/dist/VaultBar.dmg"
rm -f "$DMG"

echo "Creating DMG…"
STAGE="$(mktemp -d)"
cp -R "$ROOT_DIR/dist/VaultBar.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "VaultBar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Built: $DMG"
echo "sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
