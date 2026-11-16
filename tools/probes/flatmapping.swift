// Does a flat LEPWMBrightnessNitsMapping take the display's brightness out of the logo's?
//
//   pkill -x LogoLight     # it would fight this
//   swiftc -O tools/probes/flatmapping.swift -o /tmp/flatmapping > /tmp/flatmapping-build.log 2>&1 && /tmp/flatmapping
//
// MacBook Pro with PROLED XDR Display only, about a minute. It steps the built-in display's brightness
// (through DisplayServices) with the original mapping, then with a flat one (every display brightness
// mapped to 1000 logo nits, so AppliedNits should be MaxNitsRestriction, set by the ambient light
// alone), then with the original written back. After each step it prints LEPWMState and the logo's
// PWM duty, and how AppliedNits moved over the first 2 s (does it jump or ramp?). With each mapping it
// also fades the logo out and back in with the display turned down, to see whether a rise from dark
// gives more light than the steady logo (LogoLight's Pulse peaked at twice it).
//
// The original mapping, the display's brightness and normal lighting are put back at the end, and on
// Ctrl-C. The keyboard backlight goes dark briefly during each fade out.

import CoreGraphics
import Foundation
import IOKit

// MARK: - corebrightnessd

dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let client = (NSClassFromString("BrightnessSystemClient") as! NSObject.Type).init()
typealias CopyFn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
let copySel = NSSelectorFromString("copyPropertyForKey:"), setSel = NSSelectorFromString("setProperty:forKey:")
let copyImp = unsafeBitCast(client.method(for: copySel), to: CopyFn.self)
let setImp = unsafeBitCast(client.method(for: setSel), to: SetFn.self)
func get(_ key: String) -> Any? { copyImp(client, copySel, key as NSString)?.takeRetainedValue() }
@discardableResult func set(_ value: Any, _ key: String) -> Bool { setImp(client, setSel, value as AnyObject, key as NSString) }

func state() -> [String: Double] {
    (get("LEPWMState") as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
}

func compact(_ value: Any?) -> String {
    guard let pairs = value as? [[NSNumber]] else { return String(describing: value) }
    return pairs.map { "[\($0.map { $0.doubleValue > 1e30 ? "3.4e38" : String(format: "%g", $0.doubleValue) }.joined(separator: ","))]" }
        .joined(separator: " ")
}

// MARK: - The display and the LED

typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
guard let getSym = dlsym(displayServices, "DisplayServicesGetBrightness"),
      let setSym = dlsym(displayServices, "DisplayServicesSetBrightness")
else { print("DisplayServices isn't there: can't step the display's brightness"); exit(1) }
let getBrightness = unsafeBitCast(getSym, to: GetBrightness.self)
let setBrightness = unsafeBitCast(setSym, to: SetBrightness.self)
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
guard CGGetOnlineDisplayList(16, &ids, &count) == .success,
      let builtIn = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
else { print("no built-in display online (lid closed?)"); exit(1) }
func displayBrightness() -> Float? {
    var value: Float = 0
    return getBrightness(builtIn, &value) == 0 ? value : nil
}
func setDisplay(_ value: Float) { _ = setBrightness(builtIn, value) }

/// The logo LED's PWM duty, the light it really gives (0 when it's off, -1 when it can't be read).
func duty() -> Double {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("bklb-backlight"))
    guard service != 0 else { return -1 }
    defer { IOObjectRelease(service) }
    func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    let high = (property("high-period") as? NSNumber)?.doubleValue ?? 0
    let low = (property("low-period") as? NSNumber)?.doubleValue ?? 0
    guard high + low > 0 else { return -1 }
    return (property("enabled") as? Bool) == false ? 0 : high / (high + low)
}

// MARK: - Putting things back

let key = "LEPWMBrightnessNitsMapping"
let pgrep = Process()
pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
pgrep.arguments = ["-x", "LogoLight"]
pgrep.standardOutput = FileHandle.nullDevice
try pgrep.run(); pgrep.waitUntilExit()
guard pgrep.terminationStatus != 0 else { print("Quit LogoLight first: it would fight this probe."); exit(1) }
guard let original = get(key) else { print("\(key) can't be read"); exit(1) }
guard let originalDisplay = displayBrightness() else { print("can't read the display's brightness"); exit(1) }

/// Back to normal: the original mapping, the display's brightness, the logo fully lit at the automatic
/// fade duration (the flip to Blank and back releases anything held).
func restore() {
    set(original, key)
    setDisplay(originalDisplay)
    set(NSNumber(value: 0.3), "LEPWMFactorFadeDuration")
    set(NSNumber(value: 1), "DisplayLogicalState")
    Thread.sleep(forTimeInterval: 0.05)
    set(NSNumber(value: 2), "DisplayLogicalState")
    Thread.sleep(forTimeInterval: 0.5)
    set(NSNumber(value: 0.0), "LEPWMFactorFadeDuration")
}
// On another queue: the main thread is busy sleeping between looks.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler {
    restore()
    print("\nInterrupted; the mapping, the display's brightness and normal lighting are back.")
    exit(130)
}
interrupt.resume()

// MARK: - Steps

func line(_ label: String) -> String {
    let s = state()
    return String(format: "%-28@ display=%.2f displayNits=%5.0f pre=%5.0f applied=%5.0f min=%4.0f max=%4.0f factor=%.3f final=%6.1f duty=%.4f",
                  label as NSString, displayBrightness() ?? -1, s["DisplayNits"] ?? -1, s["PWMNitsPreRestriction"] ?? -1,
                  s["AppliedNits"] ?? -1, s["MinNitsRestriction"] ?? -1, s["MaxNitsRestriction"] ?? -1,
                  s["Factor"] ?? -1, s["FinalNits"] ?? -1, duty())
}

/// Sets the display's brightness, watches AppliedNits and the duty every 20 ms for 2 s, and prints
/// where they were at a few moments.
func step(to display: Float) {
    var looks: [(t: Double, applied: Double, duty: Double)] = []
    let t0 = Date()
    setDisplay(display)
    while Date().timeIntervalSince(t0) < 2 {
        looks.append((Date().timeIntervalSince(t0), state()["AppliedNits"] ?? -1, duty()))
        Thread.sleep(forTimeInterval: 0.02)
    }
    print(line("display -> \(String(format: "%.2f", display))"))
    let moments = [0.0, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 1.5, 1.95]
    let path = moments.map { m in
        let look = looks.last { $0.t <= m } ?? looks[0]
        return String(format: "%.2fs %.0f/%.4f", m, look.applied, look.duty)
    }
    print("    applied/duty: " + path.joined(separator: "  "))
}

/// With the display at `display`: the steady duty, then a fade out over 0.4 s and back in over 0.6 s,
/// with the highest duty during the rise and LEPWMState at that moment.
func fadeOutAndIn(display: Float) {
    setDisplay(display)
    Thread.sleep(forTimeInterval: 2)
    let steady = duty()
    let steadyApplied = state()["AppliedNits"] ?? -1
    set(NSNumber(value: 0.4), "LEPWMFactorFadeDuration")
    set(NSNumber(value: 1), "DisplayLogicalState")
    Thread.sleep(forTimeInterval: 0.8)
    set(NSNumber(value: 0.6), "LEPWMFactorFadeDuration")
    set(NSNumber(value: 2), "DisplayLogicalState")
    var peak = (duty: 0.0, applied: 0.0, factor: 0.0, final: 0.0, t: 0.0)
    var appliedRange = (lo: Double.infinity, hi: -Double.infinity)
    let t0 = Date()
    while Date().timeIntervalSince(t0) < 2 {
        let d = duty(), s = state()
        let applied = s["AppliedNits"] ?? -1
        appliedRange = (min(appliedRange.lo, applied), max(appliedRange.hi, applied))
        if d > peak.duty {
            peak = (d, applied, s["Factor"] ?? -1, s["FinalNits"] ?? -1, Date().timeIntervalSince(t0))
        }
        Thread.sleep(forTimeInterval: 0.005)
    }
    set(NSNumber(value: 0.0), "LEPWMFactorFadeDuration")
    print(String(format: "    fade out and in at display %.2f: steady duty %.4f (applied %.0f); rise peaked at duty %.4f at %.2f s (applied %.0f, factor %.3f, final %.1f); applied %.0f...%.0f during the rise; now duty %.4f",
                 display, steady, steadyApplied, peak.duty, peak.t, peak.applied, peak.factor, peak.final,
                 appliedRange.lo, appliedRange.hi, duty()))
}

print("display's brightness at the start: \(String(format: "%.3f", originalDisplay))")
print("original \(key): \(compact(original))")
print(line("start"))

print("\n== The original mapping")
for display: Float in [1, 0.3, 0.6] { step(to: display) }
fadeOutAndIn(display: 0.3)

print("\n== A flat mapping: every display brightness to 1000 logo nits")
let flat: [[NSNumber]] = [[0, 1000], [NSNumber(value: 3.402823e38), 1000]]
print("set -> \(set(flat, key)), reads back \(compact(get(key)))")
Thread.sleep(forTimeInterval: 2)
print(line("2 s later, display unchanged"))
for display: Float in [1, 0.3, 0.1, 0.6] { step(to: display) }
fadeOutAndIn(display: 0.3)

print("\n== The original mapping written back")
print("set -> \(set(original, key)), reads back \(compact(get(key)))")
for display: Float in [1, 0.3] { step(to: display) }

restore()
Thread.sleep(forTimeInterval: 1)
print("\n" + line("end (all put back)"))
print("mapping now: \(compact(get(key)))")
