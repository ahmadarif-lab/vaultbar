#!/usr/bin/env bash
# Regenerates the README images from the app's built-in demo vault (invented data; no real
# vault, account or preference is read): the screenshots and the hero banner, as small WebP files.
# Needs cwebp (brew install webp). Run: Scripts/screenshots.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/Resources/screenshots"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
command -v cwebp >/dev/null || { echo "cwebp not found: brew install webp" >&2; exit 1; }
mkdir -p "$OUT"

"$ROOT/Scripts/build_app.sh" >/dev/null
"$ROOT/dist/VaultBar.app/Contents/MacOS/VaultBar" --snapshot-dir "$TMP" >/dev/null

# The images the README uses (the hero is 2000x1100; the rest are popover shots).
for name in hero list list-dark list-id search detail detail-dark editor generator twofa \
            accounts accounts-dark folders about settings-tab settings-tab-dark locked setup delete-dark; do
  [ -f "$TMP/$name.png" ] || { echo "missing snapshot: $name" >&2; exit 1; }
  cwebp -q 86 -m 6 -alpha_q 90 "$TMP/$name.png" -o "$OUT/$name.webp" >/dev/null 2>&1
  echo "wrote Resources/screenshots/$name.webp"
done
