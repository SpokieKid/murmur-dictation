#!/bin/bash
# Builds Murmur and assembles a runnable .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Murmur.app"
BUNDLE="build/$APP"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Murmur"

echo "▸ Assembling ${APP}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/Murmur"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
if [ -d "$BIN_DIR/Murmur_Murmur.bundle" ]; then
    ditto "$BIN_DIR/Murmur_Murmur.bundle" "$BUNDLE/Contents/Resources/Murmur_Murmur.bundle"
fi

# Prefer a stable signing identity so macOS TCC keeps Accessibility / Input
# Monitoring / Microphone grants across rebuilds. Developer ID also lets the
# DMG open on other Macs without the "damaged" Gatekeeper error. Falls back
# to ad-hoc. Override with SIGN_IDENTITY (e.g. SIGN_IDENTITY=- for ad-hoc).
IDENTITY="${SIGN_IDENTITY:-}"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(printf '%s\n' "$IDENTITIES" | grep 'Developer ID Application' | head -1 | awk '{print $2}' || true)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(printf '%s\n' "$IDENTITIES" | grep 'Apple Development' | head -1 | awk '{print $2}' || true)"
fi
if [ "$IDENTITY" = "-" ]; then
    IDENTITY=""
fi
if [ -n "$IDENTITY" ]; then
    echo "▸ Signing with stable identity ${IDENTITY}…"
    SIGN="$IDENTITY"
else
    echo "▸ Signing (ad-hoc — permissions will reset each rebuild)…"
    SIGN="-"
fi
codesign --force --sign "$SIGN" \
    --identifier com.murmur.dictation \
    --entitlements Resources/Murmur.entitlements \
    --options runtime \
    "$BUNDLE"

echo "✓ Built $BUNDLE"
echo "  Run it with:  open \"$BUNDLE\""
