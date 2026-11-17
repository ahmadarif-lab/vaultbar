#!/usr/bin/env bash
# Builds VaultBar.app, wraps it in a DMG (drag to Applications) and a PKG (double-click installer that
# puts it in /Applications for you) for a GitHub release, and prints the sha256 the Homebrew cask needs.
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

echo "Creating PKG…"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/dist/VaultBar.app/Contents/Info.plist")"
PKG="$ROOT_DIR/dist/VaultBar.pkg"
rm -f "$PKG"
PKGROOT="$(mktemp -d)"
cp -R "$ROOT_DIR/dist/VaultBar.app" "$PKGROOT/"
# Not relocatable: otherwise the installer would "upgrade" a stray copy of VaultBar.app found elsewhere on the disk.
COMPONENTS="$(mktemp -d)/components.plist"
pkgbuild --analyze --root "$PKGROOT" "$COMPONENTS" >/dev/null
# Which keys --analyze writes differs between macOS versions, so set a key if it is there and add it if not.
set_bool() { /usr/libexec/PlistBuddy -c "Set :0:$1 false" "$COMPONENTS" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :0:$1 bool false" "$COMPONENTS"; }
set_bool BundleIsRelocatable
set_bool BundleIsVersionChecked # always replace, even with the same version
pkgbuild --root "$PKGROOT" --component-plist "$COMPONENTS" --identifier dev.ahmadarif.vaultbar.pkg \
    --version "$VERSION" --install-location /Applications --scripts "$ROOT_DIR/packaging/pkg-scripts" "$PKG" >/dev/null
rm -rf "$PKGROOT"

echo "Built: $DMG"
echo "Built: $PKG"
echo "sha256 (dmg, for the cask): $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "sha256 (pkg): $(shasum -a 256 "$PKG" | awk '{print $1}')"
