// Checks brightness, effects and on/off against the REAL logo, through the real LogoController.
//
//   pkill -x LogoLight                                 # it would fight this test
//   cd tools/livecheck && swift build && .build/debug/LogoLightLiveTest
//
// MacBook Pro with PROLED XDR Display only. It takes about 40 s, fades and animates the logo,
// and ends with the logo on at normal brightness. Don't pipe `swift build`: a failed build
// must stop the `&&` chain, or a stale binary runs against the hardware.

import Foundation
import LogoLightCore

let controller = LogoController.live()
let emitter = LightEmitter(service: CoreBrightnessService()!)
@MainActor func factor() -> Double { emitter.fadeLevel ?? -1 }
func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
@MainActor func report(_ label: String, expected: Double) {
    let f = factor()
    print(String(format: "%-46@ factor=%.3f expected=%.3f %@", label as NSString, f, expected, abs(f - expected) <= 0.06 ? "ok" : "OFF"))
}
@MainActor func sample(_ label: String, seconds: Double) async {
    var lo = 2.0, hi = -1.0
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        let f = factor(); lo = min(lo, f); hi = max(hi, f)
        await wait(0.02)
    }
    print(String(format: "%-46@ min=%.3f max=%.3f", label as NSString, lo, hi))
}
let level = LogoAnimator.level(forBrightness:)

print("start: setting=\(String(describing: emitter.setting)) factor=\(factor())")
controller.restoreNormalLighting(); await wait(0.6)
report("baseline", expected: 1)

controller.setBrightness(0.5); await wait(0.7)
report("brightness 0.5 (down)", expected: level(0.5))
await wait(3)
report("  3 s later (drift?)", expected: level(0.5))
controller.setBrightness(0.25); await wait(0.7)
report("brightness 0.25 (down from held)", expected: level(0.25))
controller.setBrightness(0.8); await wait(0.7)
report("brightness 0.8 (up from held)", expected: level(0.8))
controller.setBrightness(0.6); await wait(0.7)
report("brightness 0.6 (down after up)", expected: level(0.6))

// A slider drag: 60 changes at 60 Hz.
let t0 = Date()
for i in 0..<60 { controller.setBrightness(0.8 - Double(i) * 0.01); await wait(0.016) }
print(String(format: "drag took %.2fs, factor at end of drag %.3f", Date().timeIntervalSince(t0), factor()))
await wait(0.8)
report("after drag to 0.21", expected: level(0.21))

controller.setBrightness(0.5); await wait(0.7)
controller.setEffect(.pulse); await sample("pulse at 0.5 (peak ~\(String(format: "%.3f", level(0.5))))", seconds: 4)
controller.setEffect(.heartbeat); await sample("heartbeat at 0.5", seconds: 4)
controller.setEffect(.breathe); await sample("breathe at 0.5", seconds: 7)
controller.setEffect(.none); await wait(0.8)
report("effect None -> back to brightness", expected: level(0.5))

try await controller.set(.off); await wait(0.3)
print("off: setting=\(String(describing: emitter.setting)) factor=\(factor())")
try await controller.set(.on); await wait(0.5)
print("on: setting=\(String(describing: emitter.setting))")
report("on at brightness 0.5", expected: level(0.5))

controller.displayDidSleep(); await wait(0.2)
report("simulated sleep leaves level", expected: level(0.5))
controller.displayDidWake(); await wait(0.6)
report("simulated wake keeps level", expected: level(0.5))

controller.setBrightness(1); await wait(0.7)
report("brightness back to 1", expected: 1)
controller.setBrightness(0.5); await wait(0.7)
controller.restoreNormalLighting(); await wait(0.8)
report("restoreNormalLighting releases hold", expected: 1)
print("end: setting=\(String(describing: emitter.setting)) factor=\(factor()) state=\(CoreBrightnessService()!.value(forKey: "DisplayLogicalState") ?? "?")")
