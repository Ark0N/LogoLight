// lidawake: can the logo light with the lid closed and no external display?
//
// Without an external display a closed lid puts the Mac to sleep, so this first keeps it awake (a
// PreventSystemSleep assertion, an idle-sleep assertion and the root domain's
// kPMSetClamshellSleepState, all three at once), waits for the lid to close, and then tries each way
// of relighting the logo a few seconds apart, reading the LEDs from the I/O Registry:
//   B  ClamshellUpdate = false, then true to the keyboards only
//   C  + Blank -> Unblank          D  + DisplayPowerStateEvent = 2 (DidWake)   E, F  variations
//   G  a slow fade out and in      H  left alone for 10 s
// Every line is written to the log at once with the time since the start, so a sleep shows as a gap.
// On 2026-11-10 (Mac17,13, macOS 27.2, on power) the Mac stayed awake and B alone lit the logo.
//
//   ./lidawake [logfile]     # asks aloud for the lid to be closed, runs about a minute, says when done
//
// Quit LogoLight first. It puts the lid state and lid sleep back at the end.
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

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
let logPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "lidawake.log"
FileManager.default.createFile(atPath: logPath, contents: nil)
let logFile = FileHandle(forWritingAtPath: logPath)!
let clock0 = Date()
/// Every line goes to the file at once, with the wall clock, so a sleep shows as a gap and nothing is lost.
func say(_ line: String) {
    let stamped = String(format: "[%7.2f] ", Date().timeIntervalSince(clock0)) + line
    print(stamped); log.append(stamped)
    logFile.write((stamped + "\n").data(using: .utf8)!); try? logFile.synchronize()
}

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


// MARK: - Keeping the Mac awake with the lid closed

func setClamshellSleepDisabled(_ disabled: Bool) -> kern_return_t {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(root) }
    var connect: io_connect_t = 0
    let kr = IOServiceOpen(root, mach_task_self_, 0, &connect)
    guard kr == KERN_SUCCESS else { return kr }
    defer { IOServiceClose(connect) }
    var input: UInt64 = disabled ? 1 : 0
    return IOConnectCallScalarMethod(connect, 12, &input, 1, nil, nil) // kPMSetClamshellSleepState
}
func builtInState() -> String {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    let builtIn = ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    return "online=\(count) builtIn=\(builtIn.map { "asleep=\(CGDisplayIsAsleep($0)) active=\(CGDisplayIsActive($0))" } ?? "gone")"
}

// MARK: - Run

setvbuf(stdout, nil, _IOLBF, 0)
func speak(_ words: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = [words]; try? p.run()
}
say("lid-awake probe, \(Date()); keyboards \(keyboardIDs); LEBacklightMode=\(get("LEBacklightMode") ?? "?")")
say("now: " + describe(sample()) + "  " + builtInState())
var ids: [IOPMAssertionID] = []
for type in ["PreventSystemSleep", "PreventUserIdleSystemSleep"] {
    var id: IOPMAssertionID = 0
    let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "LogoLight lid probe" as CFString, &id)
    say("assertion \(type): \(r)"); ids.append(id)
}
say("clamshell sleep disabled: kr=\(setClamshellSleepDisabled(true))")
func finish() {
    say("clamshell sleep enabled again: kr=\(setClamshellSleepDisabled(false))")
    for id in ids { IOPMAssertionRelease(id) }
}
if isLidClosed() != true {
    say("Waiting up to 300 s for the lid to close...")
    let t0 = Date(); var lastCue = Date.distantPast
    while isLidClosed() != true, Date().timeIntervalSince(t0) < 300, !stopping {
        if Date().timeIntervalSince(lastCue) >= 20 { speak("Close the lid now, and keep it closed until I say done."); lastCue = Date() }
        Thread.sleep(forTimeInterval: 0.25)
    }
    guard isLidClosed() == true else { say("The lid wasn't closed; nothing was changed."); finish(); speak("The lid was not closed. Nothing was changed."); exit(1) }
}
say("Lid closed. CBClamshellState=\(get("CBClamshellState") ?? "?")")
struct Result { var name: String; var samples: [Sample] }
var results: [Result] = []
func attempt(_ name: String, _ seconds: Double, _ body: () -> Void) {
    guard !stopping else { return }
    say("== \(name)   [\(builtInState()) CBClamshellState=\(get("CBClamshellState") ?? "?")]")
    body()
    results.append(Result(name: name, samples: watch(seconds)))
}
attempt("baseline", 8) {}
attempt("B ClamshellUpdate=0", 4) { set("ClamshellUpdate", NSNumber(value: false)) }
attempt("B2 keyboards told closed", 2) { setKeyboards("ClamshellUpdate", NSNumber(value: true)) }
attempt("C +Blank->Unblank", 4) {
    set("LEPWMFactorFadeDuration", NSNumber(value: 0.3))
    set("DisplayLogicalState", NSNumber(value: 1)); pause(0.5)
    set("DisplayLogicalState", NSNumber(value: 2))
}
attempt("D +DisplayPowerStateEvent=2 (DidWake)", 4) { set("DisplayPowerStateEvent", NSNumber(value: 2)) }
attempt("D2 keyboards told closed again", 2) { setKeyboards("ClamshellUpdate", NSNumber(value: true)) }
attempt("E +Blank->Unblank after DidWake", 4) {
    set("DisplayLogicalState", NSNumber(value: 1)); pause(0.5)
    set("DisplayLogicalState", NSNumber(value: 2))
}
attempt("F WillWake then DidWake", 4) {
    set("DisplayPowerStateEvent", NSNumber(value: 1)); pause(0.3)
    set("DisplayPowerStateEvent", NSNumber(value: 2))
}
attempt("G slow fade out (1.5 s)", 3) { set("LEPWMFactorFadeDuration", NSNumber(value: 1.5)); set("DisplayLogicalState", NSNumber(value: 1)) }
attempt("G2 slow fade in (1.5 s)", 4) { set("DisplayLogicalState", NSNumber(value: 2)) }
attempt("H left alone for 10 s: does it stay lit, does the Mac stay awake", 10) { set("LEPWMFactorFadeDuration", NSNumber(value: 0)) }
say("== Putting things back")
set("DisplayPowerStateEvent", NSNumber(value: 4))
restoreNormal()
say("after: " + describe(sample()) + "  " + builtInState())
say("")
say("== Summary")
for r in results {
    let lit = r.samples.filter(\.logoLit)
    say(r.name.padding(toLength: 62, withPad: " ", startingAt: 0) + String(format: " logo %@ (%d/%d lit, max duty %.1f%%, max factor %.3f) keyboard %@ lid closed %d/%d",
        (lit.isEmpty ? "dark" : "LIT ") as NSString, lit.count, r.samples.count, (r.samples.compactMap(\.logoDuty).max() ?? 0) * 100,
        r.samples.compactMap(\.factor).max() ?? 0, (r.samples.contains(where: \.kbdLit) ? "lit" : "dark") as NSString,
        r.samples.filter { $0.lidClosed == true }.count, r.samples.count))
}
speak("Done. You can open the lid.")
pause(4)
finish()
