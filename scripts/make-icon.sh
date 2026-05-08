#!/usr/bin/env bash
# Generates an AppIcon.icns from a single 1024x1024 SVG/PNG source.
# Usage: scripts/make-icon.sh [path/to/source.png]
#
# Produces: dist/AppIcon.icns
#
# If no source is supplied, generates a placeholder PNG via a small
# Swift program. The placeholder matches the LP-500/700 LCD aesthetic:
# dark teal-on-black "LP" mark.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
ICONSET="$DIST/AppIcon.iconset"
SOURCE="${1:-$DIST/AppIcon-source.png}"

mkdir -p "$DIST" "$ICONSET"

generate_placeholder() {
    cat > "$DIST/_icon.swift" <<'SWIFT'
import AppKit
import CoreGraphics

let size = CGSize(width: 1024, height: 1024)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil,
                    width: Int(size.width),
                    height: Int(size.height),
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let grad = CGGradient(colorsSpace: cs,
                      colors: [CGColor(red: 0x14/255.0, green: 0x1b/255.0, blue: 0x25/255.0, alpha: 1),
                               CGColor(red: 0x06/255.0, green: 0x09/255.0, blue: 0x0c/255.0, alpha: 1)] as CFArray,
                      locations: [0, 1])!
let path = CGPath(roundedRect: CGRect(origin: .zero, size: size),
                  cornerWidth: 200, cornerHeight: 200, transform: nil)
ctx.addPath(path)
ctx.clip()
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: 0, y: size.height),
                       end: CGPoint(x: 0, y: 0),
                       options: [])

let lcd = CGRect(x: 140, y: 240, width: size.width - 280, height: size.height - 480)
ctx.setFillColor(CGColor(red: 0x06/255.0, green: 0x08/255.0, blue: 0x0a/255.0, alpha: 1))
ctx.addPath(CGPath(roundedRect: lcd, cornerWidth: 30, cornerHeight: 30, transform: nil))
ctx.fillPath()

ctx.setFillColor(CGColor(red: 0x6c/255.0, green: 0xb6/255.0, blue: 0xff/255.0, alpha: 0.85))
let bar = CGRect(x: lcd.minX + 60, y: lcd.minY + 100, width: lcd.width * 0.65, height: 80)
ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 8, cornerHeight: 8, transform: nil))
ctx.fillPath()

let attr: [NSAttributedString.Key: Any] = [
    .font: NSFont(name: "Menlo-Bold", size: 280) ?? NSFont.boldSystemFont(ofSize: 280),
    .foregroundColor: NSColor(red: 0x4a/255.0, green: 0xd6/255.0, blue: 0xa3/255.0, alpha: 1)
]
let text = NSAttributedString(string: "LP", attributes: attr)
let line = CTLineCreateWithAttributedString(text)
ctx.textPosition = CGPoint(x: lcd.minX + 60, y: lcd.maxY - 200)
CTLineDraw(line, ctx)

guard let img = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

    swift "$DIST/_icon.swift" "$1"
    rm -f "$DIST/_icon.swift"
}

if [ ! -f "$SOURCE" ]; then
    echo "==> Generating placeholder icon at $SOURCE"
    generate_placeholder "$SOURCE"
fi

echo "==> Generating .iconset from $SOURCE"
for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$SOURCE" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    dbl=$((sz * 2))
    sips -z "$dbl" "$dbl" "$SOURCE" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
sips -z 1024 1024 "$SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$DIST/AppIcon.icns"
echo "==> Wrote $DIST/AppIcon.icns"
