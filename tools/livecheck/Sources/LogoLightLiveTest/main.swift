// Checks brightness, effects and on/off against the REAL logo, through the real LogoController.
//
//   pkill -x LogoLight                                 # it would fight this test
//   cd tools/livecheck && swift build && .build/debug/LogoLightLiveTest
//
// MacBook Pro with PROLED XDR Display only. It takes about two minutes, fades and animates the logo,
// and ends with the logo on at normal brightness. Don't pipe `swift build`: a failed build
// must stop the `&&` chain, or a stale binary runs against the hardware. It also dims the
// keyboard backlight twice, for a simulated display sleep.
//
// Before it writes anything it checks that this Mac has the logo, that the logo is on, that LogoLight
// isn't running and that Codeman isn't blinking the logo, and stops otherwise (status 2). Every check
// prints a verdict (ok, or a word in capitals), and the run ends with a count of them: status 0 when
// all passed, 1 when any failed. Ctrl-C (or a kill) puts normal lighting back first (status 130).
//
//   .build/debug/LogoLightLiveTest --morse      # only the Morse code check (about 15 s)
//   .build/debug/LogoLightLiveTest --morse-loop # only SOS looped for 30 s, to see that a loop carries on
//   .build/debug/LogoLightLiveTest --sound      # only the Sound effect, with a stand-in for the sound (about 20 s)
//   .build/debug/LogoLightLiveTest --charging   # only the charging light check (about 30 s)
//   .build/debug/LogoLightLiveTest --display    # only the display's brightness (about a minute): unties the logo
//                                               # from the display as the app does, steps the built-in display's
//                                               # brightness down and up, and checks the logo's light stays put;
//                                               # the display's brightness and its mapping are put back at the end
//   .build/debug/LogoLightLiveTest --hear       # only listens: prints the loudness of what the Mac plays for 8 s,
//                                               # playing a system sound meanwhile (asks for System Audio
//                                               # Recording Only the first time; the logo isn't touched)
//   .build/debug/LogoLightLiveTest --lid
//
// checks Lit with Lid Closed instead, with an external display attached. It asks aloud for the
// lid to be closed (a `!` command in Claude Code shows its output only at the end), runs for
// about a minute with it closed, then asks for it to be opened. Ctrl-C restores normal lighting.

import CoreGraphics
import Foundation
import IOKit
import LogoLightCore

// MARK: - Verdicts

/// How many checks gave a verdict, and the ones that failed. The output is often read on another Mac or
/// by a script, where one OFF among a hundred lines is easy to miss, so the run ends with the count and a
/// failing status (`finish()`).
var checkCount = 0
var failedChecks: [String] = []

/// Counts a check and returns the word to print for it: `good`, or `bad` in capitals.
@MainActor func verdict(_ passed: Bool, _ label: String, good: String = "ok", bad: String = "OFF") -> String {
    checkCount += 1
    if !passed { failedChecks.append("\(label.trimmingCharacters(in: .whitespaces)): \(bad)") }
    return passed ? good : bad
}

/// Prints the count of checks and ends the run: status 0 when every check passed, 1 otherwise.
@MainActor func finish() -> Never {
    if codemanBlinked {
        checkCount += 1
        failedChecks.append("Codeman blinked the logo during the run, so its numbers can't be trusted")
    }
    print("\n\(checkCount) checks, \(failedChecks.count) failed")
    for failure in failedChecks { print("  ✗ \(failure)") }
    exit(failedChecks.isEmpty ? 0 : 1)
}

/// Ends the run before it has written anything, because it couldn't mean anything (status 2).
func stop(_ reason: String) -> Never {
    print(reason)
    exit(2)
}

/// Whether a process with exactly this name is running.
func isRunning(_ name: String) -> Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-x", name]
    pgrep.standardOutput = FileHandle.nullDevice
    guard (try? pgrep.run()) != nil else { return false }
    pgrep.waitUntilExit()
    return pgrep.terminationStatus == 0
}

/// Whether Codeman is moving the logo right now (see `CodemanLoan`).
func isCodemanBlinking() -> Bool { CodemanLoan.borrower(markerAt: CodemanLoan.markerURL) != nil }

// --hear only listens, so it needs none of this.
let touchesLogo = !CommandLine.arguments.contains("--hear")
if touchesLogo {
    guard LogoStatusReader().read().isSupported else {
        stop("This Mac has no illuminated logo: livecheck needs the MacBook Pro with PROLED XDR Display.")
    }
    guard !isRunning("LogoLight") else { stop("Quit LogoLight first: its effects would fight this test.") }
    guard !isCodemanBlinking() else {
        stop("Codeman is blinking the logo. Quit Codeman, or turn its logo blinking off, first.")
    }
    if isRunning("codeman-desktop") {
        print("note: Codeman is running. If it blinks the logo during the run, the run counts as failed.")
    }
}
guard let brightnessService = CoreBrightnessService() else { stop("corebrightnessd's client isn't available on this macOS.") }
let emitter = LightEmitter(service: brightnessService, clock: LightEmitter.uptime)
if touchesLogo, emitter.setting != .on { stop("Turn the logo on first.") }
var controller = LogoController.live()

/// Set once Codeman is seen moving the logo during the run.
var codemanBlinked = false
let codemanWatch = Task { @MainActor in
    while !Task.isCancelled {
        if touchesLogo, isCodemanBlinking() { codemanBlinked = true }
        try? await Task.sleep(for: .seconds(0.5))
    }
}

/// What an interrupted run puts back besides the logo (`--display` adds the display's brightness).
var restoreOnInterrupt: [@MainActor () -> Void] = []
// Ctrl-C, or a kill (a remote session's timeout): back to normal lighting, which with the lid closed
// is dark, instead of leaving the logo wherever the run had it.
let interrupts = [SIGINT, SIGTERM].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            if touchesLogo { controller.restoreNormalLighting() }
            for restore in restoreOnInterrupt { restore() }
        }
        print("\nInterrupted; normal lighting restored.")
        exit(130)
    }
    source.resume()
    return source
}

/// Switches the logo on or off, as the app's switch does. If that fails, the run can't go on: it puts
/// normal lighting back and ends (status 1).
@MainActor func switchLogo(_ target: LogoIllumination) async {
    do {
        try await controller.set(target)
    } catch {
        print("switching the logo \(target) failed: \(error)")
        controller.restoreNormalLighting()
        checkCount += 1
        failedChecks.append("switching the logo \(target): \(error)")
        finish()
    }
}

// As the app does, every 10 s: writes the flat mapping again should corebrightnessd lose it.
let mappingCheck = Task { @MainActor in
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        controller.keepBrightnessUntied()
    }
}
@MainActor func factor() -> Double { emitter.fadeLevel ?? -1 }
func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

/// The keyboard backlight's PWM duty, from the I/O Registry, as tools/probes/ledsample reads it
/// (0 when it's off, -1 when it can't be read).
func keyboardDuty() -> Double { ledDuty("kbd-backlight") }

/// The logo LED's PWM duty, the light it really gives (0 when it's off, -1 when it can't be read).
func logoDuty() -> Double { ledDuty("bklb-backlight") }

func ledDuty(_ name: String) -> Double {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching(name))
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
    print(String(format: "%-46@ factor=%.3f expected=%.3f glow=%.3f %@", label as NSString, f, expected, controller.liveGlow, verdict(abs(f - expected) <= 0.06, label)))
}
/// Samples the logo for `seconds` and prints the range it moved in. With `peak`, an effect is playing:
/// it should get within 0.06 of that level, and down to half of it or less.
@MainActor func sample(_ label: String, seconds: Double, peak: Double? = nil) async {
    var lo = 2.0, hi = -1.0, glowLo = 2.0, glowHi = -1.0, keyboardLo = 2.0
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        let f = factor(), g = controller.liveGlow
        lo = min(lo, f); hi = max(hi, f); glowLo = min(glowLo, g); glowHi = max(glowHi, g)
        keyboardLo = min(keyboardLo, keyboardDuty())
        await wait(0.02)
    }
    let moved = peak.map { " " + verdict(abs(hi - $0) <= 0.06 && lo <= $0 / 2, label) } ?? ""
    print(String(format: "%-46@ min=%.3f max=%.3f  glow %.3f...%.3f  keyboard min %.3f", label as NSString, lo, hi, glowLo, glowHi, keyboardLo)
          + moved)
}

/// Changes the brightness, samples the logo every 5 ms until it has been still for 0.3 s, and
/// prints how fast it was moving in the last 60 ms before it stopped, as a share of the move's
/// top speed (over 35 ms, two of the daemon's frames). Cut short at the level, it stopped at
/// 44-89%; eased on, at 10-17% (docs/corebrightnessd.md, "Easing onto a level"). Also prints how
/// far it went back the way it came (a bounce that ends near the level would pass the other
/// checks), and the keyboard's lowest duty during the move, against its duty before it. `change`
/// makes the move another way than the slider (e.g. the battery indicator).
@MainActor func landing(to brightness: Double, _ label: String, change: (@MainActor () -> Void)? = nil) async {
    let resting = keyboardDuty()
    var keyboardLo = resting
    var samples: [(t: Double, f: Double)] = []
    var lastChange = 0.0
    let t0 = Date()
    if let change { change() } else { controller.setBrightness(brightness) }
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
                 label as NSString, factor(), expected, verdict(abs(factor() - expected) <= 0.02, label), lastChange,
                 100 * share, peak, verdict(share < 0.25, label, bad: "ABRUPT"), back,
                 verdict(back <= 0.005, label, bad: "BOUNCE"),
                 keyboardLo, resting))
}
let level = LogoAnimator.level(forBrightness:)

// MARK: - Morse code (also alone, with --morse)

/// SOS sent once, at full brightness, then a loop that's stopped, from the logo held at brightness
/// 0.5. Each flash should last its number of units (a dot 1, a dash 3) within a daemon frame or two.
/// A gap can be longer than its units: corebrightnessd holds a rise from dark back until the display
/// shows a frame (up to 0.17 s with an idle screen), and that delays the next flash. But a gap inside
/// a letter (1 unit) must stay well short of one between letters (3), and none may be shorter.
@MainActor func morseCheck() async {
    let unit = MorseCode.unit
    let keyboardBefore = keyboardDuty()
    var keyboardLo = keyboardBefore, peak = 0.0
    var spans: [(start: Double, length: Double)] = []
    var litSince: Double?
    let t0 = Date()
    let started = controller.playMorse("SOS", loops: false)
    while controller.morse != nil, Date().timeIntervalSince(t0) < 12 {
        let t = Date().timeIntervalSince(t0), f = factor()
        peak = max(peak, f)
        keyboardLo = min(keyboardLo, keyboardDuty())
        if f > 0.5, litSince == nil { litSince = t }
        if f <= 0.5, let s = litSince { spans.append((s, t - s)); litSince = nil }
        await wait(0.002)
    }
    let units = spans.map { $0.length / unit }
    let gaps = zip(spans, spans.dropFirst()).map { ($1.start - $0.start - $0.length) / unit }
    let flashError = zip(units, [1.0, 1, 1, 3, 3, 3, 1, 1, 1]).map { abs($0 - $1) * unit }.max() ?? 99
    let expectedGaps = [1.0, 1, 3, 1, 1, 3, 1, 1]
    let gapsOK = gaps.count == 8 && zip(gaps, expectedGaps).allSatisfy { gap, units in
        gap >= units - 0.05 / unit && (units == 1 ? gap < 2 : gap < 4.5)
    }
    print(String(format: "%-46@ started %@, %d flashes (9 expected), peak %.3f", "morse SOS once" as NSString,
                 verdict(started, "morse SOS once: started", bad: "NO"), spans.count, peak))
    print("  flashes in units: " + units.map { String(format: "%.2f", $0) }.joined(separator: " ")
          + String(format: "  worst %.3f s %@", flashError,
                   verdict(spans.count == 9 && flashError <= 0.05, "morse SOS once: flashes")))
    print("  gaps in units:    " + gaps.map { String(format: "%.2f", $0) }.joined(separator: " ")
          + "  (1 1 3 1 1 3 1 1, or longer) " + verdict(gapsOK, "morse SOS once: gaps"))
    print(String(format: "  keyboard min %.3f (before %.3f)", keyboardLo, keyboardBefore))
    await wait(1.2)
    report("  morse done -> back to brightness", expected: level(0.5))
    controller.playMorse("E", loops: true); await sample("morse E looped", seconds: 4, peak: 1)
    controller.stopMorse(); await wait(1.2)
    report("  morse stopped -> back to brightness", expected: level(0.5))
}

/// Loops SOS for `seconds` and prints when each pass's first flash came, so a loop that stops shows.
@MainActor func morseLoopCheck(seconds: Double) async {
    var flashStarts: [Double] = []
    var litSince: Double?
    var stoppedAt: Double?
    let t0 = Date()
    controller.playMorse("SOS", loops: true)
    while Date().timeIntervalSince(t0) < seconds {
        let t = Date().timeIntervalSince(t0), f = factor()
        if f > 0.5, litSince == nil { litSince = t; flashStarts.append(t) }
        if f <= 0.5 { litSince = nil }
        if stoppedAt == nil, controller.animator?.isPlaying != true || controller.morse == nil { stoppedAt = t }
        await wait(0.002)
    }
    // A pass is 9 flashes; print the start of each pass.
    let passes = stride(from: 0, to: flashStarts.count, by: 9).map { String(format: "%.1f", flashStarts[$0]) }
    let expected = Int(((seconds - 1.7) / MorseCode.duration(of: "SOS")) * 9)
    print(String(format: "%-46@ %d flashes in %.0f s (about %d expected), passes started at %@ s; stopped: %@ %@",
                 "morse SOS looped" as NSString, flashStarts.count, seconds, expected,
                 passes.joined(separator: ", ") as NSString,
                 stoppedAt.map { String(format: "at %.1f s", $0) } ?? "no",
                 verdict(flashStarts.count >= expected - 9 && stoppedAt == nil, "morse SOS looped")))
    print("  still playing: \(controller.animator?.isPlaying == true), message: \(String(describing: controller.morse))")
    controller.stopMorse(); await wait(1.2)
}

if CommandLine.arguments.contains("--morse-loop") {
    controller.restoreNormalLighting(); await wait(0.6)
    controller.start(brightness: 0.5, effect: .none); await wait(1.5)
    await morseLoopCheck(seconds: 30)
    report("morse loop stopped -> back to brightness", expected: level(0.5))
    controller.restoreNormalLighting(); await wait(0.8)
    report("restoreNormalLighting", expected: 1)
    finish()
}

if CommandLine.arguments.contains("--morse") {
    controller.restoreNormalLighting(); await wait(0.6)
    controller.start(brightness: 0.5, effect: .none); await wait(1.5)
    report("brightness 0.5", expected: level(0.5))
    await morseCheck()
    controller.restoreNormalLighting(); await wait(0.8)
    report("restoreNormalLighting", expected: 1)
    finish()
}

// MARK: - Charging light (also alone, with --charging)

/// Whether the battery "charges", a stand-in so it can be switched.
var charging = false

/// Prints how long each cycle of Breathe took, from one rise past half of `peak` to the next, over
/// `seconds`. Each should take its planned 6.3 s within 0.2 s (another effect's are far shorter), and the
/// logo should get within 0.06 of `peak`. Over two cycles or more, at least one must have been timed.
@MainActor func cycles(_ label: String, peak: Double, seconds: Double) async {
    var rises: [Double] = []
    var wasHigh = factor() > peak / 2
    var lo = 2.0, hi = -1.0
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        let f = factor()
        lo = min(lo, f); hi = max(hi, f)
        if f > peak / 2, !wasHigh { rises.append(Date().timeIntervalSince(t0)) }
        wasHigh = f > peak / 2
        await wait(0.005)
    }
    let planned = LogoEffect.breathe.cycle.reduce(0) { $0 + $1.fade + $1.hold }
    let lengths = zip(rises, rises.dropFirst()).map { $1 - $0 }
    let inRhythm = lengths.allSatisfy { abs($0 - planned) <= 0.2 } && (!lengths.isEmpty || seconds < 2 * planned)
    print(String(format: "%-46@ min=%.3f max=%.3f (peak ~%.3f) %@  cycles: %@ %@", label as NSString, lo, hi, peak,
                 verdict(abs(hi - peak) <= 0.06, "\(label): peak"),
                 lengths.isEmpty ? "fewer than two rises"
                     : lengths.map { String(format: "%.2f", $0) }.joined(separator: " ") + " s",
                 verdict(inRhythm, "\(label): cycles")))
}

/// The charging light, with a stand-in for charging, from the logo held at brightness 0.5. While it
/// "charges", Breathe plays, from dark to the brightness, 6.3 s a cycle; choosing Heartbeat meanwhile
/// shouldn't break its rhythm, and Heartbeat follows when charging stops.
@MainActor func chargingCheck() async {
    let power = Battery.powerState()
    print("real battery: " + (power.map { "plugged in \($0.isPluggedIn), charging \($0.isCharging), full \($0.isFull)" }
                                ?? "unknown"))
    charging = false
    // Plugged in exactly while it "charges", so the wait for charging to start never comes in.
    controller = LogoController.live(powerState: {
        Battery.PowerState(isPluggedIn: charging, isCharging: charging, isFull: false)
    })
    controller.start(brightness: 0.5, effect: .none, breathesWhileCharging: true); await wait(1.2)
    report("charging light on, not charging", expected: level(0.5))
    charging = true
    controller.batteryDidChange()
    await cycles("charging -> breathing", peak: level(0.5), seconds: 14)
    controller.setEffect(.heartbeat)
    await cycles("  Heartbeat chosen: still breathing", peak: level(0.5), seconds: 8)
    charging = false
    controller.batteryDidChange()
    await sample("charging stopped -> Heartbeat", seconds: 4, peak: level(0.5))
    controller.setEffect(.none); await wait(1.2)
    report("  effect None -> back to brightness", expected: level(0.5))
    charging = true
    controller.batteryDidChange(); await wait(2.2)
    await landing(to: 0.5, "Charging off while breathing -> 0.5", change: { controller.setBreathesWhileCharging(false) })
    charging = false
}

if CommandLine.arguments.contains("--charging") {
    controller.restoreNormalLighting(); await wait(0.6)
    await chargingCheck()
    controller.restoreNormalLighting(); await wait(0.8)
    report("restoreNormalLighting", expected: 1)
    finish()
}

// MARK: - Lit with Lid Closed (--lid)

func speak(_ words: String) {
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = [words]
    try? say.run()
}

/// The built-in display going away or coming back is what the app reacts to.
func isBuiltInOnline() -> Bool { LogoStatusReader().isDisplayAwake() == true }

/// Waits up to 300 s for the built-in display to go (`online: false`) or come back, saying `cue`
/// every 30 s. Returns whether it did.
@MainActor func waitForBuiltIn(online: Bool, cue: String) async -> Bool {
    let t0 = Date()
    var lastCue = Date.distantPast
    while isBuiltInOnline() != online {
        if Date().timeIntervalSince(t0) > 300 { return false }
        if Date().timeIntervalSince(lastCue) >= 30 { speak(cue); lastCue = Date() }
        await wait(0.1)
    }
    return true
}

/// Like `report`, with the keyboard's duty, which should be 0 while the lid is closed. With
/// `expected` 0 it checks the LED instead: the factor goes back to 1 while the setting is off.
@MainActor func reportLid(_ label: String, expected: Double) {
    let f = factor(), k = keyboardDuty(), led = logoDuty()
    let ok = expected == 0 ? led == 0 : abs(f - expected) <= 0.06
    print(String(format: "%-46@ factor=%.3f expected=%.3f LED=%.3f %@  keyboard=%.3f %@", label as NSString, f, expected,
                 led, verdict(ok, label), k, verdict(k <= 0.005, "\(label): keyboard", good: "dark", bad: "LIT")))
}

/// Waits up to 3 s for the logo to start rising, and returns how long that took (corebrightnessd's
/// display-ready gate can hold back a rise from dark), or `nil`.
@MainActor func timeToRise(from start: Date) async -> Double? {
    while Date().timeIntervalSince(start) < 3 {
        if factor() > 0.01 { return Date().timeIntervalSince(start) }
        await wait(0.005)
    }
    return nil
}

/// Plays the chosen effect for `seconds` and prints the time between its rises (through half the
/// level) against the cycle's length, its lowest and highest factor, and the keyboard's highest
/// duty. A rise from dark that corebrightnessd holds back (its display-ready gate waits for a frame
/// from the built-in display) makes the cycle longer.
@MainActor func rhythm(_ label: String, cycle: Double, peak: Double, seconds: Double) async {
    var crossings: [Double] = []
    var lo = 2.0, hi = -1.0, keyboardHi = -1.0
    var below = factor() < peak / 2
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        let t = Date().timeIntervalSince(t0), f = factor()
        lo = min(lo, f); hi = max(hi, f); keyboardHi = max(keyboardHi, keyboardDuty())
        if below, f >= peak / 2 { crossings.append(t) }
        below = f < peak / 2
        await wait(0.005)
    }
    let periods = zip(crossings, crossings.dropFirst()).map { $1 - $0 }
    let worst = periods.map { abs($0 - cycle) }.max() ?? 99
    print(String(format: "%-46@ cycles %@ s (expected %.2f) %@  min=%.3f max=%.3f (peak %.3f) %@  keyboard max %.3f",
                 label as NSString, periods.map { String(format: "%.2f", $0) }.joined(separator: " ") as NSString,
                 cycle, verdict(worst <= 0.1, "\(label): cycles"), lo, hi, peak,
                 verdict(abs(hi - peak) <= 0.03, "\(label): peak"), keyboardHi))
}

@MainActor func lidCheck() async {
    guard emitter.isLidClosed == false, isBuiltInOnline() else { stop("Open the lid first.") }
    guard LogoStatusReader().isExternalDisplayAwake() == true else {
        stop("Attach an external display first: without one, closing the lid puts the Mac to sleep.")
    }

    let pulse = LogoEffect.pulse.cycle.reduce(0) { $0 + $1.fade + $1.hold }
    print("start: setting=\(String(describing: emitter.setting)) factor=\(factor()) lid closed (daemon)=\(String(describing: emitter.isLidClosed)) keyboard=\(String(format: "%.3f", keyboardDuty()))")
    controller.restoreNormalLighting(); await wait(0.6)
    // The option off first: closing the lid should darken the logo, although it's held at a level.
    controller.start(brightness: 0.5, effect: .none, lightsWithLidClosed: false); await wait(1.5)
    report("lid open: brightness 0.5", expected: level(0.5))
    controller.setEffect(.pulse)
    await rhythm("lid open: pulse at 0.5", cycle: pulse, peak: level(0.5), seconds: 7.5)
    controller.setEffect(.none); await wait(1.2)
    report("lid open: back to brightness 0.5 (held)", expected: level(0.5))

    print("Close the lid now (keep the external display on).")
    guard await waitForBuiltIn(online: false, cue: "Close the lid now.") else {
        controller.restoreNormalLighting(); print("The lid wasn't closed; normal lighting restored.")
        checkCount += 1
        failedChecks.append("the lid wasn't closed, so the checks with it closed didn't run")
        finish()
    }
    // As the app does when the built-in display goes away: a sleep, then a wake a second later.
    let closed = Date()
    controller.displayDidSleep()
    var woke: Date?
    controller.scheduleWake(after: 1) { woke = Date() }
    speak("Lid closed. Testing for about a minute. Keep it closed.")
    await wait(0.9)
    print(String(format: "%-46@ factor=%.3f LED=%.3f (lit here means the daemon alone kept the hold)",
                 "lid closed, option off: before the wake" as NSString, factor(), logoDuty()))
    while woke == nil, Date().timeIntervalSince(closed) < 5 { await wait(0.005) }
    print(String(format: "lid closed: wake handled %.2f s after the display went; daemon saw the lid closed: %@",
                 woke.map { $0.timeIntervalSince(closed) } ?? -1, String(describing: emitter.isLidClosed)))
    await wait(1)
    reportLid("lid closed, option off: dark (hold released)", expected: 0)

    let turnedOn = Date()
    controller.setLightsWithLidClosed(true)
    let rose = await timeToRise(from: turnedOn)
    print("lid closed: option on, logo started rising after \(rose.map { String(format: "%.2f s", $0) } ?? "?") "
          + verdict(rose != nil, "lid closed: option on, the logo rises", bad: "NEVER"))
    await wait(1.5)
    reportLid("lid closed: option on -> lit at 0.5", expected: level(0.5))
    await landing(to: 0.8, "lid closed: landing 0.5 -> 0.8 (up)")
    await landing(to: 0.3, "lid closed: landing 0.8 -> 0.3 (down)")
    controller.setBrightness(0.5); await wait(1.2)
    reportLid("lid closed: brightness 0.5", expected: level(0.5))
    controller.setEffect(.pulse)
    await rhythm("lid closed: pulse at 0.5", cycle: pulse, peak: level(0.5), seconds: 7.5)
    controller.setEffect(.heartbeat); await sample("lid closed: heartbeat at 0.5", seconds: 4, peak: level(0.5))
    controller.setEffect(.none); await wait(1.2)
    reportLid("lid closed: effect None -> back to brightness", expected: level(0.5))
    await switchLogo(.off); await wait(0.3)
    reportLid("lid closed: switched off", expected: 0)
    await switchLogo(.on); await wait(1.2)
    reportLid("lid closed: switched on at 0.5", expected: level(0.5))
    controller.setLightsWithLidClosed(false); await wait(1.2)
    reportLid("lid closed: option off -> dark", expected: 0)
    controller.setLightsWithLidClosed(true); await wait(2)
    reportLid("lid closed: option on -> relit at 0.5", expected: level(0.5))
    controller.restoreNormalLighting(); await wait(1.2)
    reportLid("lid closed: quit -> dark", expected: 0)
    controller = LogoController.live()
    controller.start(brightness: 0.5, effect: .none, lightsWithLidClosed: true); await wait(2)
    reportLid("lid closed: relaunch -> lit at 0.5", expected: level(0.5))

    print("Open the lid now.")
    guard await waitForBuiltIn(online: true, cue: "Done with the lid closed. Open the lid now.") else {
        controller.restoreNormalLighting(); print("The lid wasn't opened; normal lighting restored.")
        checkCount += 1
        failedChecks.append("the lid wasn't opened, so the checks after it didn't run")
        finish()
    }
    // As the app does when the built-in display comes back with no effect playing.
    controller.scheduleWake(after: 1) {}
    await wait(2.5)
    let keyboard = keyboardDuty()
    print(String(format: "lid opened: daemon saw the lid closed: %@  keyboard=%.3f %@", String(describing: emitter.isLidClosed),
                 keyboard, verdict(keyboard > 0.005, "lid opened: keyboard", good: "ok (lit again)", bad: "OFF (dark)")))
    report("lid opened: level kept", expected: level(0.5))
    controller.restoreNormalLighting(); await wait(0.8)
    report("restoreNormalLighting", expected: 1)
    print("end: setting=\(String(describing: emitter.setting)) factor=\(factor()) state=\(brightnessService.value(forKey: "DisplayLogicalState") ?? "?") keyboard=\(String(format: "%.3f", keyboardDuty()))")
    speak("Done.")
}

if CommandLine.arguments.contains("--lid") {
    await lidCheck()
    finish()
}

// MARK: - Sound (also alone, with --sound; --hear only listens)

/// A stand-in for the sound: a loudness set here, or a script of the time since it was set.
@MainActor
final class StandInSound: SoundLevelSource {
    var level = 0.0
    var script: ((Double) -> Double)?
    private var scriptStart = Date()
    private(set) var isListening = false
    func start() throws { isListening = true }
    func stop() { isListening = false }
    func play(_ script: @escaping (Double) -> Double) {
        scriptStart = Date()
        self.script = script
    }
    var loudness: Double { script?(Date().timeIntervalSince(scriptStart)) ?? level }
}

/// The Sound effect against the real logo, with a stand-in for the sound. Beats at 2 Hz should each
/// take the logo up near the peak and back to dark, within a frame or two of the follower's timings;
/// a steady level should settle within the deadband and then leave the logo alone; and the keyboard
/// backlight, which every fade toward dark dims a little, should stay close to its resting duty.
@MainActor func soundCheck() async {
    let stand = StandInSound()
    controller = LogoController.live(soundSource: stand)
    controller.start(brightness: 1, effect: .none); await wait(1)
    let keyboardBefore = keyboardDuty()

    stand.level = 0
    controller.setEffect(.sound); await wait(0.8)
    print(String(format: "%-46@ factor=%.3f %@  listening %@", "sound: silence -> dark" as NSString, factor(),
                 verdict(factor() <= 0.01, "sound: silence -> dark"),
                 verdict(stand.isListening, "sound: listening", bad: "NO")))

    // Beats: 0.12 s loud, every 0.5 s, for 5 s.
    stand.play { $0.truncatingRemainder(dividingBy: 0.5) < 0.12 ? 1 : 0 }
    var samples: [(t: Double, f: Double)] = []
    var keyboardLo = keyboardBefore, keyboardSum = 0.0, keyboardCount = 0
    let t0 = Date()
    while Date().timeIntervalSince(t0) < 5 {
        samples.append((Date().timeIntervalSince(t0), factor()))
        let k = keyboardDuty()
        keyboardLo = min(keyboardLo, k); keyboardSum += k; keyboardCount += 1
        await wait(0.005)
    }
    stand.script = nil
    stand.level = 0
    // A peak: up through 0.7, then back below 0.1.
    var peaks: [(rise: Double, top: Double, fall: Double)] = []
    var lit = false, riseAt = 0.0, top = 0.0
    for s in samples {
        if !lit, s.f > 0.7 { lit = true; riseAt = s.t; top = s.f }
        if lit { top = max(top, s.f) }
        if lit, s.f < 0.1 { lit = false; peaks.append((riseAt, top, s.t)) }
    }
    let periods = zip(peaks, peaks.dropFirst()).map { $1.rise - $0.rise }
    print(String(format: "%-46@ %d peaks in 5 s (10 beats), tops %.2f...%.2f, lit for %.2f...%.2f s %@",
                 "sound: beats at 2 Hz" as NSString, peaks.count,
                 peaks.map(\.top).min() ?? 0, peaks.map(\.top).max() ?? 0,
                 peaks.map { $0.fall - $0.rise }.min() ?? 0, peaks.map { $0.fall - $0.rise }.max() ?? 0,
                 verdict(peaks.count >= 9 && peaks.count <= 10, "sound: beats at 2 Hz")))
    print("  periods: " + periods.map { String(format: "%.2f", $0) }.joined(separator: " ")
          + String(format: "  keyboard min %.3f mean %.3f (before %.3f)", keyboardLo,
                   keyboardCount > 0 ? keyboardSum / Double(keyboardCount) : -1, keyboardBefore))

    // A steady sound at half loudness: a quarter of the peak, held, then nothing more.
    await wait(0.8)
    stand.level = 0.5
    await wait(1)
    let settled = factor()
    var lo = settled, hi = settled
    let steadyStart = Date()
    while Date().timeIntervalSince(steadyStart) < 2 { lo = min(lo, factor()); hi = max(hi, factor()); await wait(0.01) }
    print(String(format: "%-46@ factor=%.3f expected 0.25 %@  over 2 s %.3f...%.3f %@", "sound: steady at half loudness" as NSString,
                 settled, verdict(abs(settled - 0.25) <= 0.08, "sound: steady at half loudness"), lo, hi,
                 verdict(hi - lo <= 0.005, "sound: steady at half loudness", good: "ok (still)", bad: "MOVING")))

    // Full loudness at brightness 0.5 peaks at its level; then full brightness ends fully lit.
    controller.setBrightness(0.5)
    stand.level = 1; await wait(1)
    report("sound: loud at brightness 0.5", expected: level(0.5))
    controller.setBrightness(1); await wait(1)
    report("sound: loud at brightness 1", expected: 1)
    stand.level = 0; await wait(1)
    report("sound: silence again -> dark", expected: 0)

    controller.setEffect(.none); await wait(1.2)
    report("sound: effect None -> back to brightness", expected: 1)
    print(String(format: "  listening after None: %@  keyboard=%.3f",
                 verdict(!stand.isListening, "sound: listening after None", good: "ok (stopped)", bad: "STILL"), keyboardDuty()))
}

/// Listens to the real system audio for 8 s and prints the loudness 4 times a second, playing a
/// system sound at 2 s and 5 s. The logo isn't touched.
@MainActor func hearCheck() async {
    guard let source = SystemSound.source() else { stop("No system audio tap on this macOS.") }
    do {
        try source.start()
    } catch {
        print("start failed: \(error) " + verdict(false, "hear: start", bad: "FAILED"))
        return
    }
    print("listening (macOS may ask for System Audio Recording Only now)")
    let sound = "/System/Library/Sounds/Glass.aiff"
    let t0 = Date()
    var played: Set<Int> = []
    var maxLoudness = 0.0
    while Date().timeIntervalSince(t0) < 8 {
        let t = Date().timeIntervalSince(t0)
        for at in [2, 5] where t >= Double(at) && !played.contains(at) {
            played.insert(at)
            let afplay = Process()
            afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            afplay.arguments = [sound]
            try? afplay.run()
        }
        maxLoudness = max(maxLoudness, source.loudness)
        print(String(format: "  %.2f s  loudness %.3f", t, source.loudness))
        await wait(0.25)
    }
    source.stop()
    print("heard the sound: " + verdict(maxLoudness > 0.5, "hear", bad: "NOTHING (permission? nothing playing?)"))
}

if CommandLine.arguments.contains("--hear") {
    await hearCheck()
    finish()
}
if CommandLine.arguments.contains("--sound") {
    await soundCheck()
    controller.restoreNormalLighting(); await wait(0.8)
    report("restoreNormalLighting", expected: 1)
    finish()
}

// MARK: - The display's brightness (--display)

/// `LEPWMState`'s numbers.
@MainActor func pwmState() -> [String: Double] {
    let state = brightnessService.value(forKey: "LEPWMState") as? [String: Any] ?? [:]
    return state.compactMapValues { ($0 as? NSNumber)?.doubleValue }
}

/// One look at the logo after a change: when, `LEPWMState`'s numbers, and the LED's duty.
struct Look {
    let t: Double, applied: Double, pre: Double, factor: Double, duty: Double
}

@MainActor func look(since t0: Date) -> Look {
    let state = pwmState()
    return Look(t: Date().timeIntervalSince(t0), applied: state["AppliedNits"] ?? -1,
                pre: state["PWMNitsPreRestriction"] ?? -1, factor: state["Factor"] ?? -1, duty: logoDuty())
}

/// As the app does at launch, unties the logo's brightness from the display's, with the logo at
/// brightness 0.5 and the display at 0.5: a flat `LEPWMBrightnessNitsMapping`, which writing the
/// display's brightness back makes corebrightnessd take at once. The light should rise to its untied
/// level within moments, without going past it. Then, with the logo at 0.5, steps the display's
/// brightness from full down to almost dark and back, and checks the logo's light (its PWM duty, the
/// LED's real output) against its light with the display at full: it should stay put at every step.
/// For each step it prints how far the light strayed and for how long, `AppliedNits` over the first
/// second, and the keyboard's lowest duty. Then Pulse with the display at 0.30 should peak where it
/// does with the display at full, and 100% should give the same light at display 0.30 as at full.
/// Last, quitting (`restoreNormalLighting()`) should put the display's own mapping back in effect at
/// once, without the display moving.
/// The display's brightness is put back.
@MainActor func displayCheck() async {
    // Neither of these has changed anything yet: the caller has only put normal lighting back.
    guard let screen = DisplayBrightness(), let original = screen.value else {
        stop("can't read or set the built-in display's brightness (DisplayServices): check by hand with the keys")
    }
    guard pwmState()["AppliedNits"] != nil, pwmState()["MaxNitsRestriction"] != nil, emitter.brightnessMapping != nil else {
        stop("LEPWMState has no AppliedNits or MaxNitsRestriction, or there's no LEPWMBrightnessNitsMapping")
    }
    // An interrupted run also puts the display's brightness back (its own mapping goes back with the logo).
    restoreOnInterrupt.append { screen.set(original) }
    defer { restoreOnInterrupt.removeAll() }

    func line(_ label: String, display: Float) -> String {
        let state = pwmState()
        let flat = emitter.brightnessMapping.map(LightEmitter.isFlat) == true
        return String(format: "%-30@ display=%.2f pre=%4.0f applied=%4.0f max=%4.0f lux=%4.0f factor=%.3f final=%6.1f duty=%.4f mapping=%@",
                      label as NSString, display, state["PWMNitsPreRestriction"] ?? -1, state["AppliedNits"] ?? -1,
                      state["MaxNitsRestriction"] ?? -1, state["Lux"] ?? -1, state["Factor"] ?? -1,
                      state["FinalNits"] ?? -1, logoDuty(), flat ? "flat" : "the display's")
    }
    print(String(format: "display's brightness at the start: %.3f", original))
    print("the display's mapping: " + (emitter.brightnessMapping ?? []).map { "[\($0.map { $0 > 1e30 ? "3.4e38" : String(format: "%g", $0) }.joined(separator: ","))]" }.joined(separator: " "))
    // The launch: the logo at 0.5, dimmed by the display at 0.5 through its own mapping, then untied.
    screen.set(0.5); await wait(2.5)
    controller.setBrightness(0.5); await wait(2)
    print(line("tied: brightness 0.5", display: 0.5))
    var handoff: [Look] = []
    let h0 = Date()
    controller.untieBrightnessFromDisplay()
    while Date().timeIntervalSince(h0) < 3 { handoff.append(look(since: h0)); await wait(0.01) }
    let untied = logoDuty()
    let over = (handoff.map(\.duty).max() ?? 0) / untied - 1
    let taken = handoff.first { $0.pre >= 999 }?.t
    let settled = handoff.last { abs($0.duty / untied - 1) > 0.06 }?.t ?? 0
    print(line("untied", display: 0.5) + " " + verdict((taken ?? 9) <= 0.5, "untied: mapping taken", bad: "OFF (not taken)"))
    let handoffPath = stride(from: 0.0, through: 1.3, by: 0.1).map { m in
        let look = handoff.last { $0.t <= m } ?? handoff[0]
        return String(format: "%.1fs %.0f/%.3f/%.4f", m, look.applied, look.factor, look.duty)
    }
    print(String(format: "  taken after %@; up to %+.0f%% over the untied light %@, within 6%% of it from %.2f s; applied/factor/duty: ",
                 (taken.map { String(format: "%.2f s", $0) } ?? "(not within 3 s)") as NSString, 100 * over,
                 verdict(over <= 0.06, "untied: light over its level"), settled)
          + handoffPath.joined(separator: "  "))

    screen.set(1); await wait(2.5)
    controller.setBrightness(0.5); await wait(2)
    let reference = logoDuty()
    print(line("reference: brightness 0.5", display: 1))
    guard reference > 0 else {
        print("the logo gives no light: is it on? " + verdict(false, "reference: the logo's light", bad: "NONE"))
        screen.set(original)
        return
    }

    for display: Float in [0.7, 0.4, 0.2, 0.08, 0.6, 0.3, 1] {
        let keyboardBefore = keyboardDuty()
        var keyboardLo = keyboardBefore
        var looks: [Look] = []
        let t0 = Date()
        screen.set(display)
        while Date().timeIntervalSince(t0) < 3 {
            looks.append(look(since: t0))
            keyboardLo = min(keyboardLo, keyboardDuty())
            await wait(0.01)
        }
        let worst = looks.map { abs($0.duty / reference - 1) }.max() ?? 0
        let strayedUntil = looks.last { abs($0.duty / reference - 1) > 0.06 }?.t ?? 0
        let ok = abs(logoDuty() / reference - 1) <= 0.06
        let step = "display -> \(String(format: "%.2f", display))"
        print(line(step, display: display) + " " + verdict(ok, step))
        let path = [0.0, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0].map { m in
            let look = looks.last { $0.t <= m } ?? looks[0]
            return String(format: "%.1fs %.0f/%.3f", m, look.applied, look.factor)
        }
        print(String(format: "  strayed up to %.0f%%, back within 6%% after %.2f s; keyboard min %.3f (before %.3f); applied/factor: ",
                     100 * worst, strayedUntil, keyboardLo, keyboardBefore) + path.joined(separator: "  "))
    }

    // Pulse's own peak can sit a little off the held level, so it's checked against Pulse at full.
    func pulsePeak(display: Float) async -> Double {
        screen.set(display); await wait(2.5)
        controller.setEffect(.pulse)
        var peak = 0.0, factorPeak = 0.0, luxLo = 1e9, luxHi = 0.0
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 5 {
            let state = pwmState()
            peak = max(peak, logoDuty())
            factorPeak = max(factorPeak, state["Factor"] ?? 0)
            luxLo = min(luxLo, state["Lux"] ?? 0); luxHi = max(luxHi, state["Lux"] ?? 0)
            await wait(0.005)
        }
        controller.setEffect(.none); await wait(1.2)
        print(String(format: "%-30@ peak duty %.4f, factor %.3f (level %.3f), lux %.0f-%.0f",
                     "pulse at 0.5, display \(String(format: "%.2f", display))" as NSString, peak, factorPeak,
                     LogoAnimator.level(forBrightness: 0.5), luxLo, luxHi))
        return peak
    }
    let pulseFull = await pulsePeak(display: 1)
    let pulseDim = await pulsePeak(display: 0.3)
    // The factor's peaks were within 0.001 of each other, while the duty read up to 6% high once.
    print(String(format: "%-30@ %.4f against %.4f at full %@", "  pulse's peak at display 0.30" as NSString, pulseDim,
                 pulseFull, verdict(abs(pulseDim / pulseFull - 1) <= 0.1, "pulse's peak at display 0.30")))

    screen.set(1); await wait(2)
    controller.setBrightness(1); await wait(1.5)
    let full = logoDuty()
    print(line("brightness 1 at display 1.00", display: 1))
    screen.set(0.3); await wait(2.5)
    print(line("brightness 1 at display 0.30", display: 0.3) + " "
          + verdict(abs(logoDuty() / full - 1) <= 0.06, "brightness 1 at display 0.30"))

    // Quitting: the display's own mapping back, and in effect at once (the display's nits at 0.30 map to
    // far less than the flat mapping's 1000).
    controller.restoreNormalLighting(); await wait(1)
    let written = emitter.brightnessMapping.map(LightEmitter.isFlat) == false
    let inEffect = (pwmState()["PWMNitsPreRestriction"] ?? 1000) < 999
    print(line("quit", display: 0.3) + " "
          + verdict(written && inEffect, "quit: the display's own mapping",
                    bad: written ? "OFF (not in effect)" : "OFF (still flat)"))
    screen.set(original); await wait(2)
    print(line("display put back", display: original))
}

if CommandLine.arguments.contains("--display") {
    controller.restoreNormalLighting(); await wait(0.6)
    await displayCheck()
    controller.setBrightness(1); await wait(0.7)
    controller.restoreNormalLighting(); await wait(0.8)
    report("restoreNormalLighting", expected: 1)
    finish()
}

print("start: setting=\(String(describing: emitter.setting)) factor=\(factor()) keyboard=\(String(format: "%.3f", keyboardDuty()))")
controller.restoreNormalLighting(); await wait(0.6)
report("baseline", expected: 1)
// As the app does at launch (corebrightnessd takes the flat mapping at once).
controller.untieBrightnessFromDisplay()

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

controller.setEffect(.pulse); await sample("pulse at 0.5 (peak ~\(String(format: "%.3f", level(0.5))))", seconds: 4, peak: level(0.5))
controller.setEffect(.heartbeat); await sample("heartbeat at 0.5", seconds: 4, peak: level(0.5))
controller.setEffect(.breathe); await sample("breathe at 0.5", seconds: 7, peak: level(0.5))
controller.setEffect(.none); await wait(1.2)
report("effect None -> back to brightness", expected: level(0.5))

await switchLogo(.off); await wait(0.3)
print("off: setting=\(String(describing: emitter.setting)) factor=\(factor()) glow=\(controller.liveGlow) "
      + verdict(emitter.setting == .off && controller.liveGlow == 0, "off"))
await switchLogo(.on); await wait(0.8)
print("on: setting=\(String(describing: emitter.setting)) " + verdict(emitter.setting == .on, "on"))
report("on at brightness 0.5", expected: level(0.5))

// Turning on with an effect chosen: the effect's first rise is the fade in, from dark.
await switchLogo(.off); await wait(0.3)
controller.setEffect(.pulse)
await switchLogo(.on)
var rise: [Double] = []
let riseStart = Date()
while Date().timeIntervalSince(riseStart) < 0.3 { rise.append(factor()); await wait(0.005) }
let biggestDrop = zip(rise, rise.dropFirst()).map { $0 - $1 }.max() ?? 0
let isSteadyRise = (rise.first ?? 1) <= 0.05 && biggestDrop <= 0.01 && (rise.last ?? 0) > (rise.first ?? 1)
print(String(format: "%-46@ first 0.3 s from %.3f to %.3f, biggest drop %.3f %@", "on with Pulse chosen" as NSString,
             rise.first ?? -1, rise.last ?? -1, biggestDrop, verdict(isSteadyRise, "on with Pulse chosen")))
await sample("  pulse after turning on", seconds: 3, peak: level(0.5))
controller.setEffect(.none); await wait(1.2)
report("  effect None -> back to brightness", expected: level(0.5))

await morseCheck()
await soundCheck()
controller.setBrightness(0.5); await wait(0.9)

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
print("  wake handled: \(verdict(wakeHandled, "scheduled wake handled"))  keyboard=\(String(format: "%.3f", keyboardDuty()))")

// A relaunch after a run killed while holding a level reached going up (held in Blank, which
// reads back as Unblank). A fresh controller doesn't know the logo's heading, as at launch.
controller.setBrightness(0.8); await wait(0.9)
let held = factor()
print("held at 0.8 before relaunch: factor=\(String(format: "%.3f", held)) state=\(brightnessService.value(forKey: "DisplayLogicalState") ?? "?")")
controller = LogoController.live()
controller.start(brightness: 0.3, effect: .none)
var relaunchPeak = factor()
let relaunchStart = Date()
while Date().timeIntervalSince(relaunchStart) < 1.5 { relaunchPeak = max(relaunchPeak, factor()); await wait(0.005) }
report("relaunch: straight to 0.3", expected: level(0.3))
print(String(format: "  peak during relaunch %.3f (held at %.3f) %@", relaunchPeak, held, verdict(relaunchPeak <= held + 0.02, "relaunch: peak", bad: "BUMP")))

// The battery indicator, with a stand-in charge so it can be stepped. A fresh controller, as at a
// launch with Battery on and the slider at 0.3.
var charge = 0.7
print("real battery: \(Battery.charge().map { String(format: "%.0f%%", $0 * 100) } ?? "none")")
controller = LogoController.live(batteryCharge: { charge })
controller.start(brightness: 0.3, effect: .none, followsBattery: true); await wait(1.2)
report("battery 70% at launch", expected: level(0.7))
charge = 0.69
await landing(to: 0.69, "battery 70% -> 69%", change: { controller.batteryDidChange() })
charge = 0.4
await landing(to: 0.4, "battery 69% -> 40%", change: { controller.batteryDidChange() })
let sent = controller.brightness
controller.batteryDidChange(); await wait(0.3)
print(String(format: "%-46@ brightness %.3f -> %.3f %@", "same charge again changes nothing" as NSString, sent,
             controller.brightness,
             verdict(controller.animator?.isAnimating == false, "same charge again changes nothing")))
controller.setEffect(.pulse); await sample("pulse at 40% (peak ~\(String(format: "%.3f", level(0.4))))", seconds: 4, peak: level(0.4))
controller.setEffect(.none); await wait(1.2)
report("  effect None -> back to 40%", expected: level(0.4))
await landing(to: 0.3, "Battery off -> the slider's 0.3", change: { controller.setFollowsBattery(false) })
charge = 1
await landing(to: 1, "Battery on at 100% -> normal", change: { controller.setFollowsBattery(true) })
controller.setFollowsBattery(false); await wait(0.9)

await chargingCheck()

controller.setBrightness(1); await wait(0.7)
report("brightness back to 1", expected: 1)
controller.setBrightness(0.5); await wait(0.9)
controller.restoreNormalLighting(); await wait(0.8)
report("restoreNormalLighting releases hold", expected: 1)
print("end: setting=\(String(describing: emitter.setting)) factor=\(factor()) state=\(brightnessService.value(forKey: "DisplayLogicalState") ?? "?") keyboard=\(String(format: "%.3f", keyboardDuty()))")
finish()
