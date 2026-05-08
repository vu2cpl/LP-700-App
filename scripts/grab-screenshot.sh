#!/usr/bin/env bash
# Captures the LP-700 app's main window (with any modal sheet) to a PNG.
# Usage: scripts/grab-screenshot.sh <name> [delay-seconds]
#
# Example:
#   scripts/grab-screenshot.sh power-swr-view 3
#       → docs/screenshots/<name>.png
#
# Tip: pass a delay so you can switch focus to the app and get to the
# desired view before capture fires.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-}"
DELAY="${2:-2}"

if [ -z "$NAME" ]; then
    echo "usage: $0 <name> [delay-seconds]" >&2
    exit 2
fi

OUT_DIR="$ROOT/docs/screenshots"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$NAME.png"

# Locate the LP-700 window via CGWindowListCopyWindowInfo (no Accessibility
# permission required — just Screen Recording, which `screencapture` itself
# also needs).
#
# WINDOW_KIND env var selects which window to capture:
#   main  (default) — the main meter window. Title is "LP-500 / LP-700".
#   prefs           — the Settings/Preferences window. Title equals the
#                     active tab ("Server" / "Notifications" / "Display").
#   sheet           — a sheet attached to the main window (empty title).
FIND_SCRIPT="$(mktemp -t findwin.XXXXXX).swift"
cat > "$FIND_SCRIPT" <<'SWIFT'
import CoreGraphics
import Foundation
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                      kCGNullWindowID) as? [[String: Any]] ?? []
let mode = CommandLine.arguments.dropFirst().first ?? "main"
let prefsTitles: Set<String> = ["Server", "Notifications", "Display"]
var mainID: Int? = nil
var prefsID: Int? = nil
var sheetID: Int? = nil
for w in info {
    let owner = w["kCGWindowOwnerName"] as? String ?? ""
    let layer = w["kCGWindowLayer"] as? Int ?? -1
    guard owner.contains("LP-700"), layer == 0 else { continue }
    let title = (w["kCGWindowName"] as? String) ?? ""
    let id = w["kCGWindowNumber"] as? Int
    if title == "LP-500 / LP-700" {
        mainID = mainID ?? id
    } else if prefsTitles.contains(title) {
        prefsID = prefsID ?? id
    } else if title.isEmpty {
        sheetID = sheetID ?? id
    }
}
let pick: Int?
switch mode {
case "prefs": pick = prefsID
case "sheet": pick = sheetID ?? mainID
default:      pick = mainID
}
if let id = pick { print(id) } else { exit(1) }
SWIFT

WINDOW_KIND="${WINDOW_KIND:-main}"
WIN_ID="$(swift "$FIND_SCRIPT" "$WINDOW_KIND" 2>/dev/null || true)"
rm -f "$FIND_SCRIPT"

if [ -z "${WIN_ID}" ]; then
    echo "==> LP-700-App window not found. Is the app running?" >&2
    exit 1
fi

if [ "$DELAY" -gt 0 ] 2>/dev/null; then
    echo "==> Capturing window $WIN_ID in ${DELAY}s — switch to the app and arrange the desired view."
    sleep "$DELAY"
else
    echo "==> Capturing window $WIN_ID immediately"
fi

screencapture -l "$WIN_ID" -x "$OUT"
ls -lh "$OUT"
echo "==> Wrote $OUT"
