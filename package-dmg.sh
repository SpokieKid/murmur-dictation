#!/bin/bash
# Builds Murmur and packages it into a drag-to-install DMG.
set -euo pipefail
cd "$(dirname "$0")"

APP="Murmur.app"
STAGE="build/dmg-stage"
DMG="build/Murmur.dmg"

./build.sh release

echo "▸ Staging DMG contents…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

echo "▸ Creating ${DMG}…"
hdiutil create -volname "Murmur" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ Built $DMG"
echo "  Open it, drag Murmur into Applications, then run from /Applications."
