#!/usr/bin/env swift
// Makes the animated examples of LogoLight's glowing logo: GIFs for the README and looping MP4s
// (with a poster PNG each) for the website.
//
// Every frame is the app's own drawing: the live view, the MacBook lid drawn by `LogoPreview`
// (Sources/LogoLight/ControlPanel.swift), and for the menu GIFs the whole menu panel around it. The debug
// build draws them without touching the logo (`LOGOLIGHT_RENDER_PANEL`): the live view at glows 0, 0.01 … 1,
// and the panel once, with the live view dark. The glow is pasted into the panel's lid, which gives the same
// pixels as the panel drawn at that glow (checked byte for byte). Frames in between the steps are blended from
// the two nearest (accurate to an 8-bit step). Nothing else with a logo is drawn here.
//
// Re-run from the repo root (Command Line Tools are enough, no ffmpeg needed):
//
//     swift scripts/make-media.swift                  # build, render into .build/media-frames, write the media
//     swift scripts/make-media.swift --frames DIR     # use the renders (and logs) a previous run left in DIR
//
// It writes:
// - docs/media/<clip>.gif, the lid alone on the website's #0e1014 (20 fps, lid 348 px wide);
// - docs/media/menu-breathe-light.gif and menu-breathe-dark.gif, the whole menu (680 × 2476, scale 4): the panel
//   with Breathe on, the slider at the top and the live view breathing, and the menu's own items under it, in
//   the menu's rounded shape with clear corners (a GIF's pixels are clear or not, so the corners' edge pixels are
//   blended onto GitHub's page colour, white or #0d1117), light and dark for a <picture> that follows
//   prefers-color-scheme;
// - site/media/<clip>.mp4 (H.264, 30 fps, lid 696 px wide) with site/media/<clip>.png, the video's poster.
//   The videos are kept outside site/public, so they aren't uploaded: Safari plays <video> only from servers
//   that answer Range requests, which Cloudflare's static assets don't. Move them into public/ with a Worker
//   that does, if the site should show them.
//
// The motion follows the app at brightness 1, where every step fades all the way to dark or lit:
// - The effects' steps are read from `LogoEffect.cycle` (Sources/LogoLightCore/LogoEffect.swift),
//   and On/Off's fades from `switchFadeDuration` (Sources/LogoLightCore/LogoController.swift), so
//   re-running after tuning them keeps the media in step.
// - Each fade follows the hardware's measured curve, the critically damped spring in `FadeCurve`
//   (docs/corebrightnessd.md, "The fade curve"), from wherever the logo is toward 0 or 1.
// - The live view shows the square root of the level (`LogoController.liveGlow`).
// Each clip is whole cycles, starting where the logo is fully lit (a still of a paused GIF shows it
// lit), so it loops seamlessly. The menu GIFs play the same cycle as breathe.gif.

import Accelerate
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - What to make

/// One clip: a motion (an effect's name in `LogoEffect`, or "on-off") in a finish ("black" or "silver").
struct Clip {
    let name: String
    let motion: String
    let finish: String
}

let clips = [
    Clip(name: "breathe", motion: "breathe", finish: "black"),
    Clip(name: "pulse", motion: "pulse", finish: "black"),
    Clip(name: "heartbeat", motion: "heartbeat", finish: "black"),
    Clip(name: "on-off", motion: "on-off", finish: "black"),
    Clip(name: "pulse-silver", motion: "pulse", finish: "silver"),
]

/// The menu GIFs (`menu-<effect>-light.gif`, `menu-<effect>-dark.gif`): the whole menu with this effect
/// switched on and its live view playing it, drawn at `menuFormat`'s scale and frame rate.
let menuEffect = "breathe"

/// On/Off: how long the logo stays dark after the fade out, and lit after the fade back in. These
/// are the clip's own pauses, not the app's.
let onOffDarkHold = 0.6
let onOffLitHold = 0.8

/// How a set of files is drawn: the renderer's scale (the lid is 116 × 82 points), the margin around
/// the lid in pixels, and the frame rate.
struct Format {
    let scale: Int
    let padding: Int
    let fps: Int
}

let gifFormat = Format(scale: 3, padding: 24, fps: 20) // lid 348 × 246 px, 396 × 294 in all
let menuFormat = Format(scale: 4, padding: 0, fps: 20) // the menu is 170 points wide: 680 px, shown at 320 in the README
let videoFormat = Format(scale: 6, padding: 48, fps: 30) // twice that: 792 × 588
/// The website's dark background, #0e1014.
let background = (red: 0x0e, green: 0x10, blue: 0x14)
/// GitHub's page behind the README, light and dark (0xRRGGBB): what the menu GIFs' clear corners are edged with.
let page = ["light": UInt32(0xFFFFFF), "dark": UInt32(0x0D1117)]
/// The H.264 encoder's quality (0–1). Below about 0.85 the first frame, the clip's only keyframe, is coded
/// coarser than the frames after it, and the lid's edge visibly jumps each time the clip loops; at 0.9 nothing
/// outside the glow moves by more than 2 levels, and a clip is a few hundred KB.
let videoQuality = 0.9

// MARK: - Paths and arguments

let repo = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let gifFolder = repo.appendingPathComponent("docs/media")
let videoFolder = repo.appendingPathComponent("site/media")
let fileManager = FileManager.default

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-media: \(message)\n".utf8))
    exit(1)
}

var framesFolder = repo.appendingPathComponent(".build/media-frames")
var shouldRender = true
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--frames":
        guard let folder = arguments.popFirst() else { fail("--frames needs a folder") }
        framesFolder = URL(fileURLWithPath: folder).standardizedFileURL
        shouldRender = false
    default:
        fail("unknown argument \(argument). Usage: swift scripts/make-media.swift [--frames DIR]")
    }
}

func renders(_ format: Format) -> URL { framesFolder.appendingPathComponent("x\(format.scale)") }
func renderLog(_ format: Format) -> URL { framesFolder.appendingPathComponent("render-x\(format.scale).log") }

// MARK: - Rendering the live view

/// Runs a command, sending its output to `log`, and returns its exit status.
func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], log: URL) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = repo
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    fileManager.createFile(atPath: log.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: log) else { fail("can't write \(log.path)") }
    process.standardOutput = handle
    process.standardError = handle
    do { try process.run() } catch { fail("can't run \(executable): \(error)") }
    process.waitUntilExit()
    try? handle.close()
    return process.terminationStatus
}

let glowSteps = 100

if shouldRender {
    try? fileManager.removeItem(at: framesFolder)
    try? fileManager.createDirectory(at: framesFolder, withIntermediateDirectories: true)
    // The renderer draws in the debug build only. A failed build must stop here, so a stale
    // binary isn't run.
    print("Building the debug app…")
    let buildLog = framesFolder.appendingPathComponent("build.log")
    guard run("/usr/bin/env", ["swift", "build"], log: buildLog) == 0 else {
        fail("the build failed, see \(buildLog.path)")
    }
    let glows = (0...glowSteps).map { String(Double($0) / Double(glowSteps)) }.joined(separator: ",")
    for format in [gifFormat, menuFormat, videoFormat] {
        print("Rendering the live view at scale \(format.scale)…")
        let folder = renders(format)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        // At the menu's scale, the whole menu (`menu-dark.png`, `menu-light.png`) is drawn as the menu GIFs need
        // it: Breathe on, the slider at the top, and the live view dark, for the glow to be pasted in.
        var environment = [
            "LOGOLIGHT_RENDER_PANEL": folder.path,
            "LOGOLIGHT_RENDER_SCALE": String(format.scale),
            "LOGOLIGHT_RENDER_GLOWS": glows,
            "LOGOLIGHT_RENDER_EFFECT": menuEffect,
            "LOGOLIGHT_RENDER_BRIGHTNESS": "1",
            "LOGOLIGHT_RENDER_GLOW": "0",
        ]
        if format.scale == menuFormat.scale { environment["LOGOLIGHT_RENDER_MENU"] = "1" }
        let status = run(repo.appendingPathComponent(".build/debug/LogoLight").path, [], environment: environment,
                         log: renderLog(format))
        guard status == 0 else { fail("the renderer failed (exit \(status)), see \(framesFolder.path)") }
    }
}

// MARK: - Motion

/// Fade toward lit or dark over `fade` seconds, then wait `hold` seconds, as `FadeStep`.
struct Step {
    var lit: Bool
    var fade: Double
    var hold: Double
}

func source(_ path: String) -> String {
    guard let text = try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) else {
        fail("can't read \(path)")
    }
    return text
}

/// The effects' cycles, read from `LogoEffect.cycle`.
func effectCycles() -> [String: [Step]] {
    let text = source("Sources/LogoLightCore/LogoEffect.swift")
    guard let start = text.range(of: "public var cycle: [FadeStep] {"),
          let end = text.range(of: "public func cycle(startingLit", range: start.upperBound..<text.endIndex)
    else { fail("can't find LogoEffect.cycle") }
    let body = String(text[start.upperBound..<end.lowerBound])
    let step = try! NSRegularExpression(pattern: #"FadeStep\(lit: (true|false), fade: ([0-9.]+), hold: ([0-9.]+)\)"#)
    var cycles: [String: [Step]] = [:]
    for chunk in body.components(separatedBy: "case .").dropFirst() {
        let name = String(chunk.prefix { $0.isLetter })
        let range = NSRange(chunk.startIndex..., in: chunk)
        cycles[name] = step.matches(in: chunk, range: range).map { match in
            func group(_ i: Int) -> String { String(chunk[Range(match.range(at: i), in: chunk)!]) }
            return Step(lit: group(1) == "true", fade: Double(group(2))!, hold: Double(group(3))!)
        }
    }
    return cycles
}

/// How long the switch fades the logo out and in, read from `LogoController.switchFadeDuration`.
func switchFadeDuration() -> Double {
    let text = source("Sources/LogoLightCore/LogoController.swift")
    let pattern = try! NSRegularExpression(pattern: #"switchFadeDuration: Double = ([0-9.]+)"#)
    guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let value = Double(text[Range(match.range(at: 1), in: text)!])
    else { fail("can't find LogoController.switchFadeDuration") }
    return value
}

/// The share of the way a fade has covered after `s` of its duration: the critically damped spring
/// fitted to the hardware (`FadeCurve.springProgress`, k = 6.51). The fade ends at its duration, where
/// the spring is still 1.1% short (the measured curve is within 0.5% of the end by 95% of it), so it's
/// scaled to end there smoothly instead of the glow jumping at the end of a fade to dark: 1.1% of the
/// level is 10% of the glow, its square root.
func progress(_ s: Double) -> Double {
    func spring(_ s: Double) -> Double { 1 - (1 + 6.51 * s) * exp(-6.51 * s) }
    return s <= 0 ? 0 : s >= 1 ? 1 : spring(s) / spring(1)
}

/// A repeating sequence of steps, turned to start with a rise (as `LogoEffect.cycle(startingLit: true)`).
struct Motion {
    let steps: [Step]

    init(_ steps: [Step]) {
        let start = steps.firstIndex { $0.lit } ?? 0
        self.steps = Array(steps[start...] + steps[..<start])
    }

    var period: Double { steps.reduce(0) { $0 + $1.fade + $1.hold } }

    /// Where the clip starts: as the first rise ends, fully lit.
    var start: Double { steps[0].fade }

    /// The fade level (0 dark … 1 fully lit) `t` seconds after the first rise started. Each step
    /// fades from where the last one left the logo.
    func level(at time: Double) -> Double {
        var t = time.truncatingRemainder(dividingBy: period)
        if t < 0 { t += period }
        var from = steps.last!.lit ? 1.0 : 0.0
        for step in steps {
            let end = step.lit ? 1.0 : 0.0
            if t < step.fade { return from + (end - from) * progress(t / step.fade) }
            t -= step.fade
            if t < step.hold { return end }
            t -= step.hold
            from = end
        }
        return from
    }

    /// The fewest whole cycles that make a whole number of frames, so the clip loops seamlessly.
    func cycles(fps: Int) -> Int {
        for n in 1...20 {
            let frames = Double(n) * period * Double(fps)
            if abs(frames - frames.rounded()) < 1e-6 { return n }
        }
        fail("no whole number of frames in up to 20 cycles of \(period) s at \(fps) fps")
    }
}

let cycles = effectCycles()
let switchFade = switchFadeDuration()

func motion(_ name: String) -> Motion {
    if name == "on-off" {
        // Switched off: the logo fades out (and the live view goes dark with the setting). Switched
        // on: it fades in from dark. At brightness 1 both are plain fades all the way.
        return Motion([Step(lit: false, fade: switchFade, hold: onOffDarkHold),
                       Step(lit: true, fade: switchFade, hold: onOffLitHold)])
    }
    guard let steps = cycles[name], !steps.isEmpty else { fail("no cycle for \(name) in LogoEffect.cycle") }
    return Motion(steps)
}

// MARK: - Frames

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// An sRGB bitmap, RGBX by default.
func canvas(width: Int, height: Int, bitmapInfo: UInt32 = CGImageAlphaInfo.noneSkipLast.rawValue) -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo)
    else { fail("can't make a \(width) × \(height) bitmap") }
    context.interpolationQuality = .none
    return context
}

/// Pixels from the top left, inclusive.
struct PixelBox {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int

    func contains(x: Int, y: Int) -> Bool { x >= left && x <= right && y >= top && y <= bottom }
}

/// An image's bytes as RGBA, premultiplied, in sRGB (the renders' own format, so they're unchanged).
func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("can't read an image") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("missing \(url.path); render the frames again") }
    return image
}

/// The live view at each glow step, and how a frame is made from them.
struct Levels {
    /// Everything that doesn't change with the glow, if the steps don't cover the whole frame.
    let base: CGImage?
    /// The live view at each glow step: opaque wherever they're drawn, so two can be blended.
    let images: [CGImage]
    /// Where the steps are drawn, in CoreGraphics' coordinates (from the bottom left).
    let rect: CGRect
    /// The only part of them drawn over `base`.
    let clip: CGRect?
    let width: Int
    let height: Int
    /// Where the steps differ, in the frame: nothing outside it ever changes.
    let changed: PixelBox
    /// Which pixels of the frame are clear (`base` was drawn on clear), top row first; nil when none is.
    let clear: [Bool]?

    /// The live view on the website's background, with a margin.
    init(finish: String, format: Format) {
        let lids = (0...glowSteps).map { loadImage(renders(format).appendingPathComponent("live-\(finish)-\($0).png")) }
        let (width, height) = (lids[0].width + 2 * format.padding, lids[0].height + 2 * format.padding)
        let context = canvas(width: width, height: height)
        images = lids.map { lid in
            context.setFillColor(CGColor(srgbRed: CGFloat(background.red) / 255, green: CGFloat(background.green) / 255,
                                         blue: CGFloat(background.blue) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(lid, in: CGRect(x: format.padding, y: format.padding, width: lid.width, height: lid.height))
            return context.makeImage()!
        }
        (self.width, self.height) = (width, height)
        (base, rect, clip, clear) = (nil, CGRect(x: 0, y: 0, width: width, height: height), nil, nil)
        changed = Self.difference(images).box
    }

    /// The whole menu (`panel`, drawn with the live view dark), with the live view's glow pasted in at `lid` (its
    /// top left in the picture, in pixels). The glow stays inside the lid, where the live view is opaque, so this
    /// gives the same pixels as the menu drawn at each glow. The menu's corners are clear: pixels that are
    /// clear altogether stay so (`clear`), and partly clear ones are blended onto `page` (0xRRGGBB).
    init(panel: CGImage, lid: (x: Int, y: Int), finish: String, format: Format, page: UInt32) {
        images = (0...glowSteps).map { loadImage(renders(format).appendingPathComponent("live-\(finish)-\($0).png")) }
        let (box, isOpaque) = Self.difference(images)
        guard isOpaque else { fail("the glow reaches the live view's edge, so it can't be pasted into the panel") }
        (width, height) = (panel.width, panel.height)
        // Flattened onto the page, so the frame is opaque wherever it's drawn (the canvases have no alpha).
        let pixels = rgba(panel)
        var clear = [Bool](repeating: false, count: width * height)
        let context = canvas(width: width, height: height)
        let pageColor = CGColor(srgbRed: CGFloat(page >> 16 & 0xFF) / 255, green: CGFloat(page >> 8 & 0xFF) / 255,
                                blue: CGFloat(page & 0xFF) / 255, alpha: 1)
        context.setFillColor(pageColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(panel, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in 0..<(width * height) where pixels[i * 4 + 3] == 0 { clear[i] = true }
        base = context.makeImage()!
        self.clear = clear.contains(true) ? clear : nil
        rect = CGRect(x: lid.x, y: height - lid.y - images[0].height, width: images[0].width, height: images[0].height)
        clip = CGRect(x: lid.x + box.left, y: height - lid.y - box.bottom - 1,
                      width: box.right - box.left + 1, height: box.bottom - box.top + 1)
        changed = PixelBox(left: lid.x + box.left, top: lid.y + box.top, right: lid.x + box.right, bottom: lid.y + box.bottom)
    }

    /// Where the steps differ from the first, and whether they're opaque there. The glow only adds light, more
    /// with each step, so the last step differs wherever any does.
    static func difference(_ images: [CGImage]) -> (box: PixelBox, isOpaque: Bool) {
        let (first, last) = (rgba(images[0]), rgba(images[images.count - 1]))
        let width = images[0].width
        var box = PixelBox(left: width, top: images[0].height, right: -1, bottom: -1)
        var isOpaque = true
        for i in stride(from: 0, to: first.count, by: 4)
        where first[i] != last[i] || first[i + 1] != last[i + 1] || first[i + 2] != last[i + 2] || first[i + 3] != last[i + 3] {
            let (x, y) = (i / 4 % width, i / 4 / width)
            box = PixelBox(left: min(box.left, x), top: min(box.top, y), right: max(box.right, x), bottom: max(box.bottom, y))
            if first[i + 3] != 255 || last[i + 3] != 255 { isOpaque = false }
        }
        guard box.right >= 0 else { fail("the live view's steps are all the same") }
        return (box, isOpaque)
    }

    /// Draws the frame at a glow step.
    func draw(step: Int, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if let base { context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        if let clip { context.clip(to: clip) }
        context.draw(images[step], in: rect)
    }

    /// Draws the frame at `glow`, the live view blended from the two nearest steps.
    func draw(glow: Double, in context: CGContext) {
        let x = min(max(glow, 0), 1) * Double(glowSteps)
        let below = min(Int(x), glowSteps - 1)
        context.saveGState()
        defer { context.restoreGState() }
        if let base { context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        if let clip { context.clip(to: clip) }
        context.draw(images[below], in: rect)
        let share = x - Double(below)
        if share > 0 {
            context.setAlpha(share)
            context.draw(images[below + 1], in: rect)
        }
    }
}

/// The glow of each frame of a clip: whole cycles, from where the logo is first fully lit.
func glows(_ motion: Motion, fps: Int) -> [Double] {
    let count = Int((Double(motion.cycles(fps: fps)) * motion.period * Double(fps)).rounded())
    return (0..<count).map { frame in
        motion.level(at: motion.start + Double(frame) / Double(fps)).squareRoot()
    }
}

// MARK: - GIF

// Written here rather than with ImageIO: its encoder used one palette for all the frames that left the
// glows in between banded (rings around the logo, a line across the lid), and it re-quantises even an
// image that comes with its own palette.

/// Calls `body` with each pixel of an RGBX context in `box` (all of it without one) as 0xRRGGBB, top row first,
/// and its index in the frame.
func forEachPixel(_ context: CGContext, in box: PixelBox? = nil, _ body: (Int, UInt32) -> Void) {
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    let row = context.bytesPerRow
    let box = box ?? PixelBox(left: 0, top: 0, right: context.width - 1, bottom: context.height - 1)
    for y in box.top...box.bottom {
        for x in box.left...box.right {
            let o = y * row + x * 4
            body(y * context.width + x, UInt32(bytes[o]) << 16 | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]))
        }
    }
}

/// Every colour drawn inside `box` (all of the frame without one) over all the glow steps, sorted.
func colors(of levels: Levels, in box: PixelBox? = nil) -> [UInt32] {
    var isUsed = [Bool](repeating: false, count: 1 << 24)
    let context = canvas(width: levels.width, height: levels.height)
    for step in 0...glowSteps {
        levels.draw(step: step, in: context)
        forEachPixel(context, in: box) { _, color in isUsed[Int(color)] = true }
    }
    return isUsed.indices.filter { isUsed[$0] }.map(UInt32.init)
}

/// Cuts `colors` down to at most `count` by median cut: the box with the widest range in a channel is split at its
/// middle, and each box gives its mean.
func medianCut(_ colors: [UInt32], to count: Int) -> [UInt32] {
    var boxes = colors.isEmpty || count < 1 ? [] : [colors]
    func widest(_ box: [UInt32]) -> (extent: UInt32, shift: UInt32, middle: UInt32) {
        var best: (extent: UInt32, shift: UInt32, middle: UInt32) = (0, 0, 0)
        for shift: UInt32 in [16, 8, 0] {
            let values = box.map { ($0 >> shift) & 0xFF }
            let (low, high) = (values.min() ?? 0, values.max() ?? 0)
            if high - low > best.extent { best = (high - low, shift, (low + high + 1) / 2) }
        }
        return best
    }
    var splits = boxes.map(widest)
    while boxes.count < count, let i = splits.indices.max(by: { splits[$0].extent < splits[$1].extent }),
          splits[i].extent > 0 {
        let (box, shift, middle) = (boxes[i], splits[i].shift, splits[i].middle)
        boxes[i] = box.filter { ($0 >> shift) & 0xFF < middle }
        boxes.append(box.filter { ($0 >> shift) & 0xFF >= middle })
        splits[i] = widest(boxes[i])
        splits.append(widest(boxes[boxes.count - 1]))
    }
    return boxes.map { box in
        let count = UInt32(box.count)
        return [16, 8, 0].reduce(UInt32(0)) { color, shift in
            let sum = box.reduce(UInt32(0)) { $0 + ($1 >> shift) & 0xFF }
            return color | ((sum + count / 2) / count) << shift
        }
    }
}

/// Up to 255 colours: `exact` as they are, and the rest cut from `colors`. The live view's glow steps use well
/// under a thousand, so each is within about a level of its own and the GIF needs no dithering. Index 255 is left
/// transparent.
final class Palette {
    static let transparent: UInt8 = 255
    /// 0xRRGGBB.
    let colors: [UInt32]
    /// The index of the nearest colour for each 0xRRGGBB, found on first use (`.max` until then).
    private var nearest = [UInt16](repeating: .max, count: 1 << 24)

    init(cutting colors: [UInt32], keeping exact: [UInt32] = []) {
        guard exact.count < 255 || colors.isEmpty else { fail("too many colours to keep exactly (\(exact.count))") }
        self.colors = exact + medianCut(colors, to: 255 - exact.count)
    }

    func index(of color: UInt32) -> UInt8 {
        if nearest[Int(color)] == .max {
            func distance(_ other: UInt32) -> Int {
                [16, 8, 0].reduce(0) { total, shift in
                    let d = Int((color >> shift) & 0xFF) - Int((other >> shift) & 0xFF)
                    return total + d * d
                }
            }
            nearest[Int(color)] = UInt16(colors.indices.min { distance(colors[$0]) < distance(colors[$1]) }!)
        }
        return UInt8(nearest[Int(color)])
    }
}

/// A colour table for the first frame of a GIF whose later frames only change `box`. The first frame draws the
/// whole picture, and the menu's 1,300 or so colours don't fit one table with the glow's: cut together, the glow
/// came out 4–5 levels off, which flickered each time the GIF looped back to this frame. So the 32 commonest
/// colours outside the box (the flat areas, 92% of the menu) are kept exactly, 96 entries go to the glow box (within
/// 2 levels, as close as the later frames get) and the rest to the other colours (within 8 levels, apart from
/// a few dozen pixels on coloured edges).
func firstFramePalette(_ context: CGContext, changing box: PixelBox) -> Palette {
    var inside = Set<UInt32>()
    var outside: [UInt32: Int] = [:]
    forEachPixel(context) { i, color in
        if box.contains(x: i % context.width, y: i / context.width) {
            inside.insert(color)
        } else {
            outside[color, default: 0] += 1
        }
    }
    let common = outside.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(32).map(\.key)
    let rest = Set(outside.keys).subtracting(common).sorted()
    return Palette(cutting: rest, keeping: common.sorted() + medianCut(inside.sorted(), to: 96))
}

/// A GIF89a with one global palette that loops forever. Each frame after the first holds only the box that
/// changed, with the pixels that didn't transparent, and stays on screen under the next (disposal 1).
struct GIFWriter {
    private(set) var data = Data()
    let width: Int
    let height: Int
    let palette: Palette
    /// The colours on screen.
    private var shown: [UInt32]?

    init(width: Int, height: Int, palette: Palette) {
        (self.width, self.height, self.palette) = (width, height, palette)
        data.append(contentsOf: Array("GIF89a".utf8))
        append16(width)
        append16(height)
        data.append(contentsOf: [0xF7, 0, 0]) // a global palette of 256 colours, background 0, square pixels
        appendTable(palette)
        data.append(contentsOf: [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]) // loop forever
    }

    private mutating func append16(_ value: Int) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private mutating func appendTable(_ palette: Palette) {
        for i in 0..<256 {
            let color = i < palette.colors.count ? palette.colors[i] : 0
            data.append(contentsOf: [UInt8(color >> 16), UInt8((color >> 8) & 0xFF), UInt8(color & 0xFF)])
        }
    }

    /// Adds the frame drawn in an RGBX `context`, shown for `delay` hundredths of a second. After the first frame,
    /// only `changing` is looked at (the caller knows nothing outside it changes). `framePalette` gives the frame
    /// its own colour table instead of the GIF's. The pixels `clear` marks are left clear in the first frame (and
    /// must lie outside `changing`): the page shows through them.
    mutating func add(_ context: CGContext, delay: Int, changing: PixelBox? = nil, framePalette: Palette? = nil,
                      clear: [Bool]? = nil) {
        let palette = framePalette ?? self.palette
        let isFirst = shown == nil
        var shown = self.shown ?? [UInt32](repeating: 0, count: width * height)
        var indices = [UInt8](repeating: Palette.transparent, count: width * height)
        var (left, top, right, bottom) = (width, height, -1, -1)
        forEachPixel(context, in: isFirst ? nil : changing) { i, color in
            if isFirst, let clear, clear[i] {
                (left, top, right, bottom) = (min(left, i % width), min(top, i / width), max(right, i % width), max(bottom, i / width))
                return
            }
            let index = palette.index(of: color)
            let drawn = palette.colors[Int(index)]
            guard isFirst || drawn != shown[i] else { return }
            indices[i] = index
            shown[i] = drawn
            let (x, y) = (i % width, i / width)
            (left, top, right, bottom) = (min(left, x), min(top, y), max(right, x), max(bottom, y))
        }
        if right < 0 { (left, top, right, bottom) = (0, 0, 0, 0) } // unchanged: one transparent pixel
        var pixels: [UInt8] = []
        for y in top...bottom {
            pixels.append(contentsOf: indices[(y * width + left)...(y * width + right)])
        }
        // Graphic control: leave the frame in place, the transparent index (after the first frame, or in a first
        // frame with clear pixels), the delay.
        data.append(contentsOf: [0x21, 0xF9, 0x04, isFirst && clear == nil ? 0x04 : 0x05])
        append16(delay)
        data.append(contentsOf: [Palette.transparent, 0])
        data.append(0x2C)
        for value in [left, top, right - left + 1, bottom - top + 1] { append16(value) }
        if let framePalette {
            data.append(0x87) // its own table of 256 colours, not interlaced
            appendTable(framePalette)
        } else {
            data.append(0) // the global table, not interlaced
        }
        data.append(8) // the LZW code size for 256 colours
        let compressed = Self.lzw(pixels)
        for start in stride(from: 0, to: compressed.count, by: 255) {
            let block = compressed[start..<min(start + 255, compressed.count)]
            data.append(UInt8(block.count))
            data.append(contentsOf: block)
        }
        data.append(0)
        self.shown = shown
    }

    mutating func finish() -> Data {
        data.append(0x3B)
        return data
    }

    /// GIF's variable-length LZW: codes of 9 to 12 bits, least significant bit first, the table cleared when full.
    static func lzw(_ pixels: [UInt8]) -> [UInt8] {
        let clear = 256, end = 257
        var output: [UInt8] = []
        var (buffer, bits, size) = (0, 0, 9)
        func emit(_ code: Int) {
            buffer |= code << bits
            bits += size
            while bits >= 8 {
                output.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                bits -= 8
            }
        }
        var table: [Int: Int] = [:] // (prefix code << 8 | pixel) → code
        var next = end + 1
        emit(clear)
        var prefix = Int(pixels[0])
        for pixel in pixels.dropFirst() {
            let key = prefix << 8 | Int(pixel)
            if let code = table[key] {
                prefix = code
                continue
            }
            emit(prefix)
            if next == 4096 {
                emit(clear)
                table.removeAll(keepingCapacity: true)
                (size, next) = (9, end + 1)
            } else {
                table[key] = next
                if next == 1 << size { size += 1 }
                next += 1
            }
            prefix = Int(pixel)
        }
        emit(prefix)
        emit(end)
        if bits > 0 { output.append(UInt8(buffer & 0xFF)) }
        return output
    }
}

/// Writes a GIF of `levels` at each glow. With `ownFirstPalette`, the first frame gets its own colour table
/// (see `firstFramePalette`), for pictures with more colours than the glow, and `palette` is only the glow's.
/// The levels' clear pixels are left clear in the GIF.
func writeGIF(_ glows: [Double], levels: Levels, palette: Palette, ownFirstPalette: Bool = false, fps: Int, to url: URL) {
    // A GIF's delays are in hundredths of a second.
    guard 100 % fps == 0 else { fail("a GIF can't play at \(fps) fps exactly; use one that divides 100") }
    var gif = GIFWriter(width: levels.width, height: levels.height, palette: palette)
    let context = canvas(width: levels.width, height: levels.height)
    for (frame, glow) in glows.enumerated() {
        levels.draw(glow: glow, in: context)
        let framePalette = frame == 0 && ownFirstPalette
            ? firstFramePalette(context, changing: levels.changed) : nil
        gif.add(context, delay: 100 / fps, changing: levels.changed, framePalette: framePalette, clear: levels.clear)
    }
    do { try gif.finish().write(to: url) } catch { fail("can't write \(url.path): \(error)") }
}

// MARK: - Video

func writePNG(glow: Double, levels: Levels, to url: URL) {
    let context = canvas(width: levels.width, height: levels.height)
    levels.draw(glow: glow, in: context)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("can't write \(url.path)") }
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fail("can't finish \(url.path)") }
}

/// BT.709 at video range (Y' 16–235, CbCr 16–240), the matrix the video is tagged with.
let toYCbCr: vImage_ARGBToYpCbCr = {
    var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                        YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
    var info = vImage_ARGBToYpCbCr()
    guard vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range, &info,
                                                        kvImageARGB8888, kvImage420Yp8_CbCr8,
                                                        vImage_Flags(kvImageNoFlags)) == kvImageNoError
    else { fail("can't set up the Y'CbCr conversion") }
    return info
}()

/// Where videos are written before they're moved into place. Making a video fit for streaming
/// (`shouldOptimizeForNetworkUse`) rewrites it, and that has left copies named `<clip>.mp4.sb-…` next to it.
let videoWork = fileManager.temporaryDirectory.appendingPathComponent("make-media-\(getpid())")

@MainActor
func writeVideo(_ glows: [Double], levels: Levels, fps: Int, to destination: URL) async {
    try? fileManager.createDirectory(at: videoWork, withIntermediateDirectories: true)
    let url = videoWork.appendingPathComponent(destination.lastPathComponent)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { fail("can't write \(url.path)") }
    func failed(_ what: String, _ error: Error? = nil) -> Never {
        fail("can't \(what) \(url.path): \((error ?? writer.error).map { "\($0)" } ?? "")")
    }
    writer.shouldOptimizeForNetworkUse = true
    // The frames are sRGB: BT.709's primaries with sRGB's transfer function. Tagged as such, a browser
    // that manages video colour shows them as the page's own colours, and one that doesn't shows them as they are.
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: levels.width,
        AVVideoHeightKey: levels.height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [
            AVVideoQualityKey: videoQuality,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: glows.count,
        ],
    ])
    // This adds the input. Frames are converted to Y'CbCr here rather than by the encoder, so the colours
    // are exact: the encoder's own conversion put the background a step off in Cb, 4 levels too blue.
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: CVPixelBufferCreationAttributes(
        pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        size: CVImageSize(width: levels.width, height: levels.height)))
    do { try writer.start() } catch { failed("start", error) }
    writer.startSession(atSourceTime: .zero)
    guard let pool = receiver.pixelBufferPool else { failed("get a pixel buffer pool for") }
    let context = canvas(width: levels.width, height: levels.height,
                         bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    var info = toYCbCr
    let bgraToARGB: [UInt8] = [3, 2, 1, 0]
    for (frame, glow) in glows.enumerated() {
        levels.draw(glow: glow, in: context)
        let buffer: CVMutablePixelBuffer
        do { buffer = try pool.makeMutablePixelBuffer() } catch { failed("make a pixel buffer for", error) }
        let converted = buffer.withUnsafeBuffer { buffer in
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            var source = vImage_Buffer(data: context.data, height: vImagePixelCount(levels.height),
                                       width: vImagePixelCount(levels.width), rowBytes: context.bytesPerRow)
            var luma = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                                     height: vImagePixelCount(levels.height), width: vImagePixelCount(levels.width),
                                     rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
            var chroma = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
                                       height: vImagePixelCount(levels.height / 2), width: vImagePixelCount(levels.width / 2),
                                       rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
            return vImageConvert_ARGB8888To420Yp8_CbCr8(&source, &luma, &chroma, &info, bgraToARGB,
                                                        vImage_Flags(kvImageNoFlags))
        }
        guard converted == kvImageNoError else { fail("can't convert frame \(frame) to Y'CbCr") }
        do {
            try await receiver.append(CVReadOnlyPixelBuffer(buffer),
                                      with: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        } catch { failed("add frame \(frame) to", error) }
    }
    receiver.finish()
    // The last frame lasts a frame, so the clip is exactly its cycles long.
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(glows.count), timescale: CMTimeScale(fps)))
    await writer.finishWriting()
    guard writer.status == .completed else { failed("finish") }
    try? fileManager.removeItem(at: destination)
    do { try fileManager.moveItem(at: url, to: destination) } catch { fail("can't write \(destination.path): \(error)") }
}

// MARK: - Making the clips

for folder in [gifFolder, videoFolder] {
    try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
}

func size(_ url: URL) -> String {
    let bytes = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    return String(format: "%.0f KB", Double(bytes) / 1024)
}

for (format, isGIF) in [(gifFormat, true), (videoFormat, false)] {
    for finish in Set(clips.map(\.finish)).sorted() {
        let levels = Levels(finish: finish, format: format)
        let palette = isGIF ? Palette(cutting: colors(of: levels)) : nil
        for clip in clips where clip.finish == finish {
            let clipMotion = motion(clip.motion)
            let frames = glows(clipMotion, fps: format.fps)
            let timing = String(format: "%d × %.2f s cycle, %d frames, %.2f s", clipMotion.cycles(fps: format.fps),
                                clipMotion.period, frames.count, Double(frames.count) / Double(format.fps))
            if isGIF {
                let url = gifFolder.appendingPathComponent("\(clip.name).gif")
                writeGIF(frames, levels: levels, palette: palette!, fps: format.fps, to: url)
                print("\(url.path): \(levels.width) × \(levels.height), \(timing), \(size(url))")
            } else {
                let url = videoFolder.appendingPathComponent("\(clip.name).mp4")
                await writeVideo(frames, levels: levels, fps: format.fps, to: url)
                // The poster is the first frame, fully lit.
                let poster = videoFolder.appendingPathComponent("\(clip.name).png")
                writePNG(glow: frames[0], levels: levels, to: poster)
                print("\(url.path): \(levels.width) × \(levels.height), \(timing), \(size(url)); poster \(size(poster))")
            }
        }
    }
}

// The menu, with the effect on and its live view playing it. The menus were drawn with the live view dark; the
// renderer says where the lid is in each.
let menuFrames = glows(motion(menuEffect), fps: menuFormat.fps)
let renderOutput = (try? String(contentsOf: renderLog(menuFormat), encoding: .utf8)) ?? ""
for appearance in ["light", "dark"] {
    let name = "menu-\(appearance).png"
    let place = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: "/\(name): lid at x ")
                                         + #"([0-9.]+), y ([0-9.]+)"#)
    guard let match = place.firstMatch(in: renderOutput, range: NSRange(renderOutput.startIndex..., in: renderOutput)),
          let x = Double(renderOutput[Range(match.range(at: 1), in: renderOutput)!]),
          let y = Double(renderOutput[Range(match.range(at: 2), in: renderOutput)!])
    else { fail("the renderer didn't say where the lid is in \(name); render the frames again") }
    let lid = (x: x * Double(menuFormat.scale), y: y * Double(menuFormat.scale))
    guard lid.x == lid.x.rounded(), lid.y == lid.y.rounded() else { fail("the lid isn't on whole pixels in \(name)") }
    let levels = Levels(panel: loadImage(renders(menuFormat).appendingPathComponent(name)), lid: (Int(lid.x), Int(lid.y)),
                        finish: "black", format: menuFormat, page: page[appearance]!)
    let url = gifFolder.appendingPathComponent("menu-\(menuEffect)-\(appearance).gif")
    writeGIF(menuFrames, levels: levels, palette: Palette(cutting: colors(of: levels, in: levels.changed)),
             ownFirstPalette: true, fps: menuFormat.fps, to: url)
    print("\(url.path): \(levels.width) × \(levels.height), \(menuFrames.count) frames, "
          + String(format: "%.2f s, ", Double(menuFrames.count) / Double(menuFormat.fps)) + size(url))
}

try? fileManager.removeItem(at: videoWork)
