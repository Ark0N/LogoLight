// clamshell: can the logo light with the lid closed (an external display attached)?
//
// Tries each way in turn, a few seconds apart, and puts things back after each one:
//   A  DisplayLogicalState Blank -> Unblank          (the state the logo follows)
//   B  ClamshellUpdate = false                       (the daemon's lid flag for the logo)
//      then ClamshellUpdate = true to the keyboards only, to see if they stay dark
//   C  ClamshellUpdate = false, then Blank -> Unblank
//   D  ClamshellUpdate = false, DisplayPowerStateEvent = 2 (DidWake)   (only with --power-event)
// It reads the LEDs from the I/O Registry (bklb-backlight@0, kbd-backlight@0), so nobody needs
// to watch the logo, and prints a summary of which attempt lit it. It's what showed that B works
// (see "The lid" in docs/corebrightnessd.md).
//
//   ./clamshell                 # asks (aloud) for the lid to be closed, waits up to 5 minutes, then
//                               # runs for about 25 s and says when the lid can be opened
//   ./clamshell --sample-only   # writes nothing: prints one set of readings and exits
//   ./clamshell --power-event   # also runs attempt D
//
// Needs an external display (without one, closing the lid sleeps the Mac). Quit LogoLight first.
// Ctrl-C restores normal lighting before exiting. The log is saved to the current directory.
import CoreGraphics
import Foundation
import IOKit

// MARK: - corebrightnessd

dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
guard let clientType = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else {
    print("BrightnessSystemClient is missing"); exit(1)
}
let client = clientType.init()
typealias CopyFn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
typealias SetKbdFn = @convention(c) (AnyObject, Selector, AnyObject, NSString, UInt64) -> Bool
let copySel = NSSelectorFromString("copyPropertyForKey:")
let setSel = NSSelectorFromString("setProperty:forKey:")
let kbdSel = NSSelectorFromString("setProperty:withKey:keyboardID:")
let copyImp = unsafeBitCast(client.method(for: copySel), to: CopyFn.self)
let setImp = unsafeBitCast(client.method(for: setSel), to: SetFn.self)
let kbdImp: SetKbdFn? = clientType.instancesRespond(to: kbdSel)
    ? unsafeBitCast(client.method(for: kbdSel), to: SetKbdFn.self) : nil
let keyboardIDs: [UInt64] = {
    let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
    guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type,
          type.instancesRespond(to: sel) else { return [] }
    return (type.init().perform(sel)?.takeRetainedValue() as? [NSNumber])?.map(\.uint64Value) ?? []
}()

func get(_ key: String) -> Any? { copyImp(client, copySel, key as NSString)?.takeRetainedValue() }

var log: [String] = []
func say(_ line: String) { print(line); log.append(line) }

func set(_ key: String, _ value: NSNumber) {
    let ok = setImp(client, setSel, value, key as NSString)
    say("    set \(key) = \(value)\(ok ? "" : "  (NOT delivered)")")
}
func setKeyboards(_ key: String, _ value: NSNumber) {
    guard let kbdImp, !keyboardIDs.isEmpty else { say("    (no keyboard route; skipped keyboard-only \(key))"); return }
    for id in keyboardIDs { _ = kbdImp(client, kbdSel, value, key as NSString, id) }
    say("    set \(key) = \(value) on keyboards \(keyboardIDs) only")
}

// MARK: - Readings

func registryProperties(name: String) -> [String: Any] {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching(name))
    guard service != IO_OBJECT_NULL else { return [:] }
    defer { IOObjectRelease(service) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
    return props?.takeRetainedValue() as? [String: Any] ?? [:]
}

func led(_ name: String) -> (enabled: Bool?, duty: Double?) {
    let p = registryProperties(name: name)
    let hi = (p["high-period"] as? NSNumber)?.doubleValue, lo = (p["low-period"] as? NSNumber)?.doubleValue
    let duty = hi.flatMap { h in lo.flatMap { l in h + l > 0 ? h / (h + l) : nil } }
    return (p["enabled"] as? Bool, duty)
}

func isLidClosed() -> Bool? {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(root) }
    return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool
}

func displays() -> (builtInOnline: Bool, external: Int) {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return (false, 0) }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return (false, 0) }
    let list = ids.prefix(Int(count))
    return (list.contains { CGDisplayIsBuiltin($0) != 0 }, list.filter { CGDisplayIsBuiltin($0) == 0 }.count)
}

struct Sample {
    var lidClosed: Bool?
    var logoEnabled: Bool?, logoDuty: Double?
    var kbdEnabled: Bool?, kbdDuty: Double?
    var factor: Double?, displayNits: Double?, appliedNits: Double?, finalNits: Double?, lux: Double?
    var logicalState: Int?
    var logoLit: Bool { logoEnabled == true && (logoDuty ?? 0) > 0.005 }
    var kbdLit: Bool { kbdEnabled == true && (kbdDuty ?? 0) > 0.005 }
}

func sample() -> Sample {
    let st = get("LEPWMState") as? [String: Any] ?? [:]
    func num(_ k: String) -> Double? { (st[k] as? NSNumber)?.doubleValue }
    let logo = led("bklb-backlight"), kbd = led("kbd-backlight")
    return Sample(lidClosed: isLidClosed(), logoEnabled: logo.enabled, logoDuty: logo.duty,
                  kbdEnabled: kbd.enabled, kbdDuty: kbd.duty, factor: num("Factor"),
                  displayNits: num("DisplayNits"), appliedNits: num("AppliedNits"), finalNits: num("FinalNits"),
                  lux: num("Lux"), logicalState: (get("DisplayLogicalState") as? NSNumber)?.intValue)
}

func describe(_ s: Sample) -> String {
    func f(_ v: Double?, _ fmt: String) -> String { v.map { String(format: fmt, $0) } ?? "?" }
    func onOff(_ v: Bool?) -> String { v.map { $0 ? "on " : "off" } ?? "?  " }
    return "lid=\(s.lidClosed.map { $0 ? "closed" : "OPEN  " } ?? "?     ")"
        + "  logo=\(onOff(s.logoEnabled)) \(f(s.logoDuty.map { $0 * 100 }, "%5.1f"))%"
        + "  kbd=\(onOff(s.kbdEnabled)) \(f(s.kbdDuty.map { $0 * 100 }, "%5.1f"))%"
        + "  factor=\(f(s.factor, "%.3f"))  displayNits=\(f(s.displayNits, "%.1f"))"
        + "  appliedNits=\(f(s.appliedNits, "%.1f"))  finalNits=\(f(s.finalNits, "%.1f"))"
        + "  lux=\(f(s.lux, "%.0f"))  logical=\(s.logicalState.map(String.init) ?? "?")"
}

// MARK: - Ctrl-C

let stopLock = NSLock()
var stopRequested = false
var stopping: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopRequested }
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigint.setEventHandler { stopLock.lock(); stopRequested = true; stopLock.unlock() }
sigint.resume()

/// Samples every 0.25 s for `seconds`, printing each, and returns them.
func watch(_ seconds: Double) -> [Sample] {
    var out: [Sample] = []
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds, !stopping {
        let s = sample()
        out.append(s)
        say(String(format: "    +%4.1fs  ", Date().timeIntervalSince(t0)) + describe(s))
        Thread.sleep(forTimeInterval: 0.25)
    }
    return out
}

func pause(_ seconds: Double) {
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds, !stopping { Thread.sleep(forTimeInterval: 0.05) }
}

/// Back to normal, as in tools/probes/README.md, then the real lid state, so every module agrees with it.
func restoreNormal() {
    say("== Restoring normal lighting")
    set("LEPWMFactorFadeDuration", NSNumber(value: 0.5)); Thread.sleep(forTimeInterval: 0.05)
    set("DisplayLogicalState", NSNumber(value: 1)); Thread.sleep(forTimeInterval: 0.05)
    set("DisplayLogicalState", NSNumber(value: 2)); Thread.sleep(forTimeInterval: 1)
    set("LEPWMFactorFadeDuration", NSNumber(value: 0)); Thread.sleep(forTimeInterval: 0.3)
    let closed = isLidClosed() ?? true
    set("ClamshellUpdate", NSNumber(value: closed))
    Thread.sleep(forTimeInterval: 1)
    say("    after restore: " + describe(sample()))
}

// MARK: - Run

setvbuf(stdout, nil, _IOLBF, 0)
/// Speaks a cue aloud: a `!` command shows its output only when it ends.
func speak(_ words: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = [words]
    try? p.run()
}

let args = Set(CommandLine.arguments.dropFirst())
let start = sample()
let screens = displays()
say("clamshell probe, \(Date())")
say("displays: built-in \(screens.builtInOnline ? "online" : "offline"), \(screens.external) external; "
    + "keyboards \(keyboardIDs); CBClamshellState=\(get("CBClamshellState") ?? "?"); LEBacklightMode=\(get("LEBacklightMode") ?? "?")")
say("now: " + describe(start))
if args.contains("--sample-only") { exit(0) }

let pgrep = Process()
pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
pgrep.arguments = ["-x", "LogoLight"]
pgrep.standardOutput = FileHandle.nullDevice
try? pgrep.run(); pgrep.waitUntilExit()
if pgrep.terminationStatus == 0 { say("Quit LogoLight first: its effects would fight the probe."); exit(1) }
if (get("LEBacklightMode") as? NSNumber)?.intValue != 2 {
    say("Turn the logo on first (LEBacklightMode is not 2): with the setting off nothing can light it."); exit(1)
}
if screens.external == 0 {
    say("No external display is online. Without one, closing the lid puts the Mac to sleep."); exit(1)
}
if isLidClosed() != true {
    say("Close the lid now (keep the external display on). Waiting up to 300 s...")
    let t0 = Date()
    var lastCue = Date.distantPast
    while isLidClosed() != true, Date().timeIntervalSince(t0) < 300, !stopping {
        if Date().timeIntervalSince(lastCue) >= 30 { speak("Close the lid now."); lastCue = Date() }
        Thread.sleep(forTimeInterval: 0.5)
    }
    guard isLidClosed() == true else {
        say("The lid wasn't closed; nothing was changed."); speak("The lid wasn't closed. Nothing was changed."); exit(1)
    }
    speak("Lid closed. Testing for about half a minute. Keep it closed.")
    say("Lid closed. Letting corebrightnessd settle for 5 s...")
    pause(5)
}

struct Result { var name: String; var samples: [Sample] }
var results: [Result] = []

say("== Baseline, lid closed, nothing changed")
results.append(Result(name: "baseline", samples: watch(3)))

if !stopping {
    say("== A: DisplayLogicalState Blank -> Unblank")
    set("LEPWMFactorFadeDuration", NSNumber(value: 0.3))
    set("DisplayLogicalState", NSNumber(value: 1)); pause(0.5)
    set("DisplayLogicalState", NSNumber(value: 2))
    results.append(Result(name: "A Unblank", samples: watch(3)))
    set("LEPWMFactorFadeDuration", NSNumber(value: 0))
    pause(2)
}

if !stopping {
    say("== B: ClamshellUpdate = false")
    set("ClamshellUpdate", NSNumber(value: false))
    results.append(Result(name: "B ClamshellUpdate=false", samples: watch(3)))
    say("   B2: ClamshellUpdate = true, keyboards only (should the keyboard have lit, it should go dark; the logo should stay lit)")
    setKeyboards("ClamshellUpdate", NSNumber(value: true))
    results.append(Result(name: "B2 +keyboards told closed", samples: watch(2.5)))
    say("   restore: ClamshellUpdate = true (the lid really is closed)")
    set("ClamshellUpdate", NSNumber(value: true))
    results.append(Result(name: "B restored (expect dark)", samples: watch(2.5)))
    pause(1)
}

if !stopping {
    say("== C: ClamshellUpdate = false, then Blank -> Unblank")
    set("ClamshellUpdate", NSNumber(value: false))
    set("LEPWMFactorFadeDuration", NSNumber(value: 0.3))
    set("DisplayLogicalState", NSNumber(value: 1)); pause(0.5)
    set("DisplayLogicalState", NSNumber(value: 2))
    results.append(Result(name: "C ClamshellUpdate=false+Unblank", samples: watch(3)))
    set("LEPWMFactorFadeDuration", NSNumber(value: 0))
    set("ClamshellUpdate", NSNumber(value: true))
    pause(2)
}

if !stopping, args.contains("--power-event") {
    say("== D: ClamshellUpdate = false, DisplayPowerStateEvent = 2 (DidWake)")
    set("ClamshellUpdate", NSNumber(value: false))
    set("DisplayPowerStateEvent", NSNumber(value: 2))
    results.append(Result(name: "D +DisplayPowerStateEvent=2", samples: watch(3)))
    set("ClamshellUpdate", NSNumber(value: true))
    pause(2)
}

if stopping { say("Interrupted.") }
restoreNormal()
speak("Done. You can open the lid.")

// MARK: - Summary

say("")
say("== Summary")
let lidStayedClosed = results.allSatisfy { $0.samples.allSatisfy { $0.lidClosed == true } }
if !lidStayedClosed { say("!! The lid was opened during the run, so these results don't show the lid-closed case.") }
for r in results {
    let lit = r.samples.filter(\.logoLit)
    let maxDuty = r.samples.compactMap(\.logoDuty).max() ?? 0
    let maxFactor = r.samples.compactMap(\.factor).max() ?? 0
    let kbd = r.samples.contains(where: \.kbdLit)
    let nits = r.samples.compactMap(\.displayNits)
    say(r.name.padding(toLength: 34, withPad: " ", startingAt: 0) + String(format: " logo %@ (lit in %d/%d samples, max duty %.1f%%, max factor %.3f)  keyboard %@  displayNits %@",
               (lit.isEmpty ? "dark" : "LIT ") as NSString, lit.count, r.samples.count,
               maxDuty * 100, maxFactor, (kbd ? "lit" : "dark") as NSString,
               (nits.isEmpty ? "?" : String(format: "%.1f-%.1f", nits.min()!, nits.max()!)) as NSString))
}
let attempts = results.filter { !["baseline", "B restored (expect dark)"].contains($0.name) }
if let winner = attempts.first(where: { $0.samples.contains(where: \.logoLit) }) {
    say("=> \(winner.name) lit the logo with the lid closed.")
} else {
    say("=> Nothing lit the logo with the lid closed.")
    if results.contains(where: { $0.samples.contains { ($0.displayNits ?? 1) <= 0 } }) {
        say("   DisplayNits read 0: corebrightnessd's 'display brightness zero' gate keeps the logo's target at 0.")
    }
    if results.contains(where: { $0.samples.contains { ($0.factor ?? 0) > 0.5 && !$0.logoLit } }) {
        say("   The fade factor rose but the LED stayed off: something below the factor (the driver or the hardware) gates it.")
    }
}

let file = "clamshell-probe-\(Int(Date().timeIntervalSince1970)).txt"
try? log.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
print("Saved to \(FileManager.default.currentDirectoryPath)/\(file)")
