// Draws the README's "Download LogoLight" button, docs/download-button.png. It matches Buy Me a
// Coffee's own button (545 × 153 px, the same rounding), which sits next to it.
//
//   swift scripts/make-download-button.swift

import AppKit

let width = 545.0, height = 153.0, radius = 22.0
let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

blue.setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: radius, yRadius: radius).fill()

// The label, in the rounded system font (close to the friendly lettering of the button beside it),
// as large as fits with the same margins as that button's.
let glyph = 46.0, gap = 20.0, margin = 46.0
func makeLabel(size: Double) -> NSAttributedString {
    let base = NSFont.systemFont(ofSize: size, weight: .semibold)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    return NSAttributedString(string: "Download LogoLight", attributes: [.font: font, .foregroundColor: NSColor.white])
}
var size = 46.0
while glyph + gap + makeLabel(size: size).size().width > width - 2 * margin { size -= 1 }
let label = makeLabel(size: size)
let labelSize = label.size()

// A download glyph: an arrow into a tray, drawn here.
let total = glyph + gap + labelSize.width
let left = (width - total) / 2
let mid = height / 2
NSColor.white.setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 6; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: left + glyph / 2, y: mid + 21))
arrow.line(to: NSPoint(x: left + glyph / 2, y: mid - 5))
arrow.move(to: NSPoint(x: left + glyph / 2 - 11, y: mid + 6))
arrow.line(to: NSPoint(x: left + glyph / 2, y: mid - 5))
arrow.line(to: NSPoint(x: left + glyph / 2 + 11, y: mid + 6))
arrow.move(to: NSPoint(x: left + 3, y: mid - 9))
arrow.line(to: NSPoint(x: left + 3, y: mid - 20))
arrow.line(to: NSPoint(x: left + glyph - 3, y: mid - 20))
arrow.line(to: NSPoint(x: left + glyph - 3, y: mid - 9))
arrow.stroke()

label.draw(at: NSPoint(x: left + glyph + gap, y: mid - labelSize.height / 2 + 2))

NSGraphicsContext.current = nil
let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("docs/download-button.png")
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path)")
