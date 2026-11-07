// Draws LogoLight's app icon, a space black lid with a soft light glowing at its centre, and writes it
// as Resources/AppIcon.icns. (No Apple logo: Apple doesn't allow it in other apps' icons.)
//
//   swift scripts/make-icon.swift && git add Resources/AppIcon.icns
//
// It's drawn on Apple's macOS icon grid: an 824-point rounded square with continuous corners on a
// 1024-point canvas, with a soft shadow below it.

import AppKit
import SwiftUI

let canvas = 1024.0
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius = 185.4

func drawIcon(in context: CGContext) {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: body).cgPath
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // The shadow under the icon.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // The lid: space black, a little lighter at the top.
    let lid = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.205, green: 0.208, blue: 0.228, alpha: 1),
        CGColor(srgbRed: 0.075, green: 0.076, blue: 0.088, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(lid, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // The glow: a wide, faint bloom, then a brighter halo, then the light itself.
    let centre = CGPoint(x: body.midX, y: body.midY + 8)
    func glow(radius: Double, colors: [CGColor], locations: [CGFloat]) {
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
    }
    glow(radius: 380, colors: [CGColor(srgbRed: 0.85, green: 0.9, blue: 1, alpha: 0.28), CGColor(srgbRed: 0.85, green: 0.9, blue: 1, alpha: 0)],
         locations: [0, 1])
    glow(radius: 190, colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75), CGColor(srgbRed: 0.95, green: 0.97, blue: 1, alpha: 0.25),
                               CGColor(srgbRed: 0.9, green: 0.94, blue: 1, alpha: 0)], locations: [0, 0.45, 1])
    glow(radius: 78, colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                              CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)], locations: [0, 0.55, 1])

    // A sheen across the top, and a fine light edge, as on the lid's aluminium.
    let sheen = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 120), options: [])
    context.restoreGState()

    context.addPath(shape)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    context.setLineWidth(3)
    context.strokePath()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.scaleBy(x: Double(size) / canvas, y: Double(size) / canvas)
    drawIcon(in: context)
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
