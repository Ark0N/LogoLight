// Checks brightness, effects and on/off against the REAL logo, through the real LogoController.
//
//   pkill -x LogoLight                                 # it would fight this test
//   cd tools/livecheck && swift build && .build/debug/LogoLightLiveTest
//
// MacBook Pro with PROLED XDR Display only. It takes about a minute, fades and animates the logo,
// and ends with the logo on at normal brightness. Don't pipe `swift build`: a failed build
// must stop the `&&` chain, or a stale binary runs against the hardware. It also dims the
// keyboard backlight twice, for a simulated display sleep.

import Foundation
import IOKit
import LogoLightCore

var controller = LogoController.live()
let emitter = LightEmitter(service: CoreBrightnessService()!, clock: LightEmitter.uptime)
@MainActor func factor() -> Double { emitter.fadeLevel ?? -1 }
func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

/// The keyboard backlight's PWM duty, from the I/O Registry, as tools/probes/ledsample reads it
/// (0 when it's off, -1 when it can't be read).
func keyboardDuty() -> Double {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("kbd-backlight"))
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

@MainActor func report(_ label: String, expected: Double) {
    let f = factor()
    print(String(format: "%-46@ factor=%.3f expected=%.3f glow=%.3f %@", label as NSString, f, expected, controller.liveGlow, abs(f - expected) <= 0.06 ? "ok" : "OFF"))
}
@MainActor func sample(_ label: String, seconds: Double) async {
    var lo = 2.0, hi = -1.0, glowLo = 2.0, glowHi = -1.0, keyboardLo = 2.0
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        let f = factor(), g = controller.liveGlow
        lo = min(lo, f); hi = max(hi, f); glowLo = min(glowLo, g); glowHi = max(glowHi, g)
        keyboardLo = min(keyboardLo, keyboardDuty())
        await wait(0.02)
    }
    print(String(format: "%-46@ min=%.3f max=%.3f  glow %.3f...%.3f  keyboard min %.3f", label as NSString, lo, hi, glowLo, glowHi, keyboardLo))
}

/// Changes the brightness, samples the logo every 5 ms until it has been still for 0.3 s, and
/// prints how fast it was moving in the last 60 ms before it stopped, as a share of the move's
/// top speed (over 35 ms, two of the daemon's frames). Cut short at the level, it stopped at
/// 44-89%; eased on, at 10-17% (docs/corebrightnessd.md, "Easing onto a level"). Also prints how
/// far it went back the way it came (a bounce that ends near the level would pass the other
/// checks), and the keyboard's lowest duty during the move, against its duty before it.
@MainActor func landing(to brightness: Double, _ label: String) async {
    let resting = keyboardDuty()
    var keyboardLo = resting
    var samples: [(t: Double, f: Double)] = []
    var lastChange = 0.0
    let t0 = Date()
    controller.setBrightness(brightness)
    while true {
        let t = Date().timeIntervalSince(t0), f = factor()
        if let last = samples.last, f != last.f { lastChange = t }
        samples.append((t, f))
        keyboardLo = min(keyboardLo, keyboardDuty())
        if t > 3 || (t > 0.3 && t - lastChange > 0.3) { break }
        await wait(0.005)
    }
    func level(at t: Double) -> Double { samples.last { $0.t <= t }?.f ?? samples[0].f }
    let peak = samples.filter { $0.t >= 0.035 }.map { abs($0.f - level(at: $0.t - 0.035)) / 0.035 }.max() ?? 0
    let atStop = abs(level(at: lastChange) - level(at: lastChange - 0.06)) / 0.06
    let share = peak > 0 ? atStop / peak : 0
    let expected = LogoAnimator.level(forBrightness: brightness)
    let up = expected > samples[0].f
    let back = zip(samples, samples.dropFirst()).map { up ? $0.f - $1.f : $1.f - $0.f }.filter { $0 > 0 }.reduce(0, +)
    print(String(format: "%-46@ factor=%.3f expected=%.3f %@  took %.2fs, last 60 ms at %.0f%% of %.2f/s %@  back %.3f %@  keyboard min %.3f (before %.3f)",
                 label as NSString, factor(), expected, abs(factor() - expected) <= 0.02 ? "ok" : "OFF", lastChange,
                 100 * share, peak, share < 0.25 ? "ok" : "ABRUPT", back, back <= 0.005 ? "ok" : "BOUNCE",
                 keyboardLo, resting))
}
let level = LogoAnimator.level(forBrightness:)

print("start: setting=\(String(describing: emitter.setting)) factor=\(factor()) keyboard=\(String(format: "%.3f", keyboardDuty()))")
controller.restoreNormalLighting(); await wait(0.6)
report("baseline", expected: 1)

controller.setBrightness(0.5); await wait(0.9)
report("brightness 0.5 (down)", expected: level(0.5))
await wait(3)
report("  3 s later (drift?)", expected: level(0.5))
controller.setBrightness(0.25); await wait(0.9)
report("brightness 0.25 (down from held)", expected: level(0.25))
controller.setBrightness(0.8); await wait(0.9)
report("brightness 0.8 (up from held)", expected: level(0.8))
controller.setBrightness(0.6); await wait(0.9)
report("brightness 0.6 (down after up)", expected: level(0.6))

// A slider drag: 60 changes at 60 Hz.
let t0 = Date()
for i in 0..<60 { controller.setBrightness(0.8 - Double(i) * 0.01); await wait(0.016) }
print(String(format: "drag took %.2fs, factor at end of drag %.3f", Date().timeIntervalSince(t0), factor()))
await wait(0.8)
report("after drag to 0.21", expected: level(0.21))

// Slider clicks, eased onto the level.
await landing(to: 0.5, "landing 0.21 -> 0.5 (up)")
await landing(to: 0.9, "landing 0.5 -> 0.9 (up)")
await landing(to: 0.4, "landing 0.9 -> 0.4 (down)")
await landing(to: 0.2, "landing 0.4 -> 0.2 (down)")
await landing(to: 0.5, "landing 0.2 -> 0.5 (up)")

controller.setEffect(.pulse); await sample("pulse at 0.5 (peak ~\(String(format: "%.3f", level(0.5))))", seconds: 4)
controller.setEffect(.heartbeat); await sample("heartbeat at 0.5", seconds: 4)
controller.setEffect(.breathe); await sample("breathe at 0.5", seconds: 7)
controller.setEffect(.none); await wait(1.2)
report("effect None -> back to brightness", expected: level(0.5))

try await controller.set(.off); await wait(0.3)
print("off: setting=\(String(describing: emitter.setting)) factor=\(factor()) glow=\(controller.liveGlow)")
try await controller.set(.on); await wait(0.8)
print("on: setting=\(String(describing: emitter.setting))")
report("on at brightness 0.5", expected: level(0.5))

// Turning on with an effect chosen: the effect's first rise is the fade in, from dark.
try await controller.set(.off); await wait(0.3)
controller.setEffect(.pulse)
try await controller.set(.on)
var rise: [Double] = []
let riseStart = Date()
while Date().timeIntervalSince(riseStart) < 0.3 { rise.append(factor()); await wait(0.005) }
let biggestDrop = zip(rise, rise.dropFirst()).map { $0 - $1 }.max() ?? 0
let isSteadyRise = (rise.first ?? 1) <= 0.05 && biggestDrop <= 0.01 && (rise.last ?? 0) > (rise.first ?? 1)
print(String(format: "%-46@ first 0.3 s from %.3f to %.3f, biggest drop %.3f %@", "on with Pulse chosen" as NSString,
             rise.first ?? -1, rise.last ?? -1, biggestDrop, isSteadyRise ? "ok" : "OFF"))
await sample("  pulse after turning on", seconds: 3)
controller.setEffect(.none); await wait(1.2)
report("  effect None -> back to brightness", expected: level(0.5))

controller.displayDidSleep(); await wait(0.2)
report("simulated sleep leaves level", expected: level(0.5))
controller.displayDidWake(); await wait(1.2)
report("simulated wake keeps level", expected: level(0.5))

// A wake handled a moment later, as the app does after the system's wake notifications.
controller.displayDidSleep(); await wait(0.2)
var wakeHandled = false
controller.scheduleWake(after: 0.2) { wakeHandled = true }
await wait(1.5)
report("scheduled wake (0.2 s) keeps level", expected: level(0.5))
print("  wake handled: \(wakeHandled ? "ok" : "OFF")  keyboard=\(String(format: "%.3f", keyboardDuty()))")

// A relaunch after a run killed while holding a level reached going up (held in Blank, which
// reads back as Unblank). A fresh controller doesn't know the logo's heading, as at launch.
controller.setBrightness(0.8); await wait(0.9)
let held = factor()
print("held at 0.8 before relaunch: factor=\(String(format: "%.3f", held)) state=\(CoreBrightnessService()!.value(forKey: "DisplayLogicalState") ?? "?")")
controller = LogoController.live()
controller.start(brightness: 0.3, effect: .none)
var relaunchPeak = factor()
let relaunchStart = Date()
while Date().timeIntervalSince(relaunchStart) < 1.5 { relaunchPeak = max(relaunchPeak, factor()); await wait(0.005) }
report("relaunch: straight to 0.3", expected: level(0.3))
print(String(format: "  peak during relaunch %.3f (held at %.3f) %@", relaunchPeak, held, relaunchPeak <= held + 0.02 ? "ok" : "BUMP"))

controller.setBrightness(1); await wait(0.7)
report("brightness back to 1", expected: 1)
controller.setBrightness(0.5); await wait(0.9)
controller.restoreNormalLighting(); await wait(0.8)
report("restoreNormalLighting releases hold", expected: 1)
print("end: setting=\(String(describing: emitter.setting)) factor=\(factor()) state=\(CoreBrightnessService()!.value(forKey: "DisplayLogicalState") ?? "?") keyboard=\(String(format: "%.3f", keyboardDuty()))")
