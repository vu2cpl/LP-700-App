#!/usr/bin/env bash
# Creates a distributable DMG with the .app inside and a /Applications symlink.
# Usage: VERSION=1.0.0 scripts/make-dmg.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/LP-700-App.app"
VERSION="${VERSION:-0.0.0-dev}"
DMG="$DIST/LP-700-App-${VERSION}.dmg"

test -d "$APP" || { echo "Build the app first: scripts/build-app.sh" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Staging DMG contents at $STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"

echo "==> Creating DMG at $DMG"
hdiutil create \
    -volname "LP-700-App ${VERSION}" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

ls -lh "$DMG" | awk '{ printf "    %s\n", $0 }'
echo "==> Wrote $DMG"
