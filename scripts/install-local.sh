#!/usr/bin/env bash
# Builds LP-700-App.app and installs it to /Applications on this Mac.
#
# Steps:
#   1. Run scripts/build-app.sh (universal release, ad-hoc signed).
#   2. ditto-copy the .app to /Applications, replacing any existing copy.
#   3. Strip the com.apple.quarantine xattr so Gatekeeper does not block
#      the ad-hoc-signed binary on first launch.
#
# Usage:
#   VERSION=$(git describe --tags --always) scripts/install-local.sh
#
# Requires sudo only if /Applications/LP-700-App.app exists and is not
# owned by the current user (rare on personal macs, common on managed
# fleets). The script tries without sudo first and re-runs with sudo on
# permission failure.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="LP-700-App.app"
SRC_APP="$DIST/$APP_NAME"
DEST_APP="/Applications/$APP_NAME"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0-dev)}"

echo "==> Building $APP_NAME (version $VERSION)"
VERSION="$VERSION" "$ROOT/scripts/build-app.sh"

test -d "$SRC_APP" || { echo "Build did not produce $SRC_APP" >&2; exit 1; }

install_to_applications() {
    local sudo_cmd=("$@")
    if [ "${#sudo_cmd[@]}" -gt 0 ]; then
        echo "==> Removing existing $DEST_APP (with sudo)"
        "${sudo_cmd[@]}" rm -rf "$DEST_APP"
        echo "==> Copying $SRC_APP -> $DEST_APP (with sudo)"
        "${sudo_cmd[@]}" /usr/bin/ditto "$SRC_APP" "$DEST_APP"
        echo "==> Stripping com.apple.quarantine xattr (with sudo)"
        "${sudo_cmd[@]}" /usr/bin/xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
    else
        echo "==> Removing existing $DEST_APP"
        rm -rf "$DEST_APP"
        echo "==> Copying $SRC_APP -> $DEST_APP"
        /usr/bin/ditto "$SRC_APP" "$DEST_APP"
        echo "==> Stripping com.apple.quarantine xattr"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
    fi
}

if install_to_applications 2>/tmp/lp700-install.err; then
    :
else
    if grep -qi "permission denied" /tmp/lp700-install.err; then
        echo "==> Permission denied without sudo, re-trying with sudo"
        install_to_applications sudo
    else
        cat /tmp/lp700-install.err >&2
        exit 1
    fi
fi
rm -f /tmp/lp700-install.err

echo
echo "==> Installed: $DEST_APP"
echo "==> Launch with: open '$DEST_APP'"
