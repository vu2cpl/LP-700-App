#!/usr/bin/env bash
# Builds a universal release binary, wraps it into LP-700-App.app with the
# Info.plist template, embeds AppIcon.icns, and ad-hoc signs.
# Output: dist/LP-700-App.app
#
# Usage: VERSION=1.0.0 scripts/build-app.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/LP-700-App.app"
VERSION="${VERSION:-0.0.0-dev}"

mkdir -p "$DIST"

echo "==> Building universal release binary (arm64 + x86_64) — version $VERSION"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BIN="$BIN_PATH/LP-700-App"
test -x "$BIN" || { echo "Binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling .app bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/LP-700-App"
chmod +x "$APP/Contents/MacOS/LP-700-App"

# Info.plist with version substitution.
sed "s/__VERSION__/${VERSION}/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

# Icon (best-effort — falls back to no icon if generator fails).
if [ ! -f "$DIST/AppIcon.icns" ]; then
    if "$ROOT/scripts/make-icon.sh"; then
        :
    else
        echo "==> WARNING: AppIcon.icns generation failed, shipping without icon"
    fi
fi
if [ -f "$DIST/AppIcon.icns" ]; then
    cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

# Verify
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
file "$APP/Contents/MacOS/LP-700-App" | sed 's/^/    /'

echo "==> Built $APP"
