// Draws the README's banner, docs/banner.jpg: LogoLight's icon and name, the headline, and the large
// live view of the lid with the real menu (Breathe on) beside it, on a dark gradient. Every picture of
// the logo in it is LogoLight's own render.
//
//   swift build && LOGOLIGHT_RENDER_PANEL=/tmp/lid LOGOLIGHT_RENDER_SCALE=10 LOGOLIGHT_RENDER_GLOWS=1 .build/debug/LogoLight
//   LOGOLIGHT_RENDER_PANEL=/tmp/menu LOGOLIGHT_RENDER_SCALE=3 LOGOLIGHT_RENDER_TRANSPARENT=1 \
//     LOGOLIGHT_RENDER_EFFECT=breathe LOGOLIGHT_RENDER_BRIGHTNESS=1 LOGOLIGHT_RENDER_GLOW=0.8 .build/debug/LogoLight
//   swift scripts/make-banner.swift /tmp/lid/live-black-100.png /tmp/menu/on-dark.png

import AppKit

let args = CommandLine.arguments
let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let lid = NSImage(contentsOfFile: args[1])!, menu = NSImage(contentsOfFile: args[2])!
let icon = NSImage(contentsOfFile: root.appendingPathComponent("docs/icon.png").path)!

let W = 2400.0, H = 1260.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let graphics = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics.cgContext, flipped: true)
let cg = graphics.cgContext
cg.translateBy(x: 0, y: H); cg.scaleBy(x: 1, y: -1)   // top-left origin
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

// Background: deep navy, lit blue at the top right and violet at the bottom left.
cg.setFillColor(rgb(14, 15, 26)); cg.fill(CGRect(x: 0, y: 0, width: W, height: H))
func glow(at p: CGPoint, radius: Double, _ color: CGColor) {
    let g = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
}
glow(at: CGPoint(x: W * 0.92, y: -120), radius: 1300, rgb(52, 66, 132, 0.85))
glow(at: CGPoint(x: -100, y: H + 120), radius: 1000, rgb(78, 36, 92, 0.75))
glow(at: CGPoint(x: W * 0.6, y: H * 0.62), radius: 700, rgb(40, 44, 80, 0.35))

func text(_ s: String, size: Double, weight: NSFont.Weight, color: NSColor, at p: CGPoint, kern: Double = 0) -> CGSize {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    str.draw(at: p)
    return str.size()
}

// The icon and name.
let left = 150.0
icon.draw(in: NSRect(x: left - 10, y: 120, width: 150, height: 150), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
_ = text("LogoLight", size: 66, weight: .semibold, color: .white, at: CGPoint(x: left + 160, y: 150))

// The headline, the last word in the lid's blue-white, as on the site.
let headline = 108.0
_ = text("Control your", size: headline, weight: .bold, color: .white, at: CGPoint(x: left, y: 340), kern: -3)
let w1 = text("glowing ", size: headline, weight: .bold, color: .white, at: CGPoint(x: left, y: 470), kern: -3).width
_ = text("Apple logo.", size: headline, weight: .bold, color: NSColor(srgbRed: 0.83, green: 0.86, blue: 1, alpha: 1),
         at: CGPoint(x: left + w1, y: 470), kern: -3)
let grey = NSColor(white: 0.66, alpha: 1)
_ = text("Turn it off, dim it, or let it breathe,", size: 46, weight: .regular, color: grey, at: CGPoint(x: left, y: 650))
_ = text("pulse or beat like a heart.", size: 46, weight: .regular, color: grey, at: CGPoint(x: left, y: 712))
_ = text("Right from the menu bar.", size: 46, weight: .regular, color: grey, at: CGPoint(x: left, y: 774))

// Tags.
var x = left
for tag in ["Free", "Open source", "MacBook Pro with PROLED XDR Display"] {
    let font = NSFont.systemFont(ofSize: 38, weight: .medium)
    let str = NSAttributedString(string: tag, attributes: [.font: font, .foregroundColor: NSColor(white: 0.92, alpha: 1)])
    let size = str.size()
    let pill = CGRect(x: x, y: 1100, width: size.width + 64, height: 84)
    let path = CGPath(roundedRect: pill, cornerWidth: 42, cornerHeight: 42, transform: nil)
    cg.addPath(path); cg.setFillColor(rgb(255, 255, 255, 0.07)); cg.fillPath()
    cg.addPath(path); cg.setStrokeColor(rgb(255, 255, 255, 0.16)); cg.setLineWidth(2); cg.strokePath()
    str.draw(at: CGPoint(x: x + 32, y: 1100 + (84 - size.height) / 2))
    x += pill.width + 22
}

// The lid, large, with the menu over its right side.
let lidRect = CGRect(x: 1150, y: 330, width: 1000, height: 1000 * 820 / 1160)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: 30), blur: 80, color: rgb(0, 0, 0, 0.55))
lid.draw(in: lidRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
cg.restoreGState()

let menuRect = CGRect(x: 1830, y: 170, width: 510, height: 945)
let window = CGPath(roundedRect: menuRect.insetBy(dx: -14, dy: -14), cornerWidth: 40, cornerHeight: 40, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: 30), blur: 70, color: rgb(0, 0, 0, 0.6))
cg.addPath(window); cg.setFillColor(rgb(40, 40, 44)); cg.fillPath()
cg.restoreGState()
cg.addPath(window); cg.setStrokeColor(rgb(255, 255, 255, 0.12)); cg.setLineWidth(2); cg.strokePath()
menu.draw(in: menuRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

NSGraphicsContext.current = nil
let output = root.appendingPathComponent("docs/banner.jpg")
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])!.write(to: output)
print("Wrote \(output.path)")
