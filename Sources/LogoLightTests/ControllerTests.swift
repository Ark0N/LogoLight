import Foundation
import LogoLightCore

/// A simulated PROLED MacBook Pro, modelled on how the real one behaves: the LED follows
/// the `LEBacklightMode` default immediately, but the NVRAM copy keeps its value from boot.
final class SimulatedMac: HardwareReading, @unchecked Sendable {
    /// The root `com.apple.CoreBrightness` `LEBacklightMode` value, `nil` when deleted.
    var backlightMode: Int?
    var hasLogo = true
    /// The built-in display: off while it sleeps and while the lid is closed.
    var displayAwake = true
    var externalDisplayAwake = false
    /// When false, corebrightnessd ignores changes to the default.
    var daemonResponds = true
    /// Called when the root default changes, as corebrightnessd observes it.
    var onDefaultChanged: ((Int?) -> Void)?
    /// Whether the password-free rule is installed (`/etc/sudoers.d/logolight`).
    var ruleInstalled = false
    /// When false, installing the rule fails.
    var installsRule = true
    /// What corebrightnessd is currently applying.
    private var appliedOn: Bool
    /// The NVRAM copy, written at boot and not again during the session.
    let nvramCopy: String

    init(backlightMode: Int? = nil) {
        self.backlightMode = backlightMode
        appliedOn = backlightMode != 0
        nvramCopy = appliedOn ? "true" : "false"
    }

    /// Runs a root shell script the way `/bin/sh` would: one of the two commands (as `defaults` would),
    /// the rule's install or removal, or the install followed by a command, whose result is the script's.
    func execute(_ script: String) throws {
        let rule = try? PasswordlessRule()
        for target in LogoIllumination.allCases {
            let command = CoreBrightnessSetting.command(for: target)
            if let rule, script == rule.installScript(thenRunning: command) {
                try? installRule()
                return try execute(command.shellString)
            }
        }
        if script == rule?.installScript { return try installRule() }
        if script == PasswordlessRule.removeScript {
            ruleInstalled = false
            return
        }
        switch script {
        case CoreBrightnessSetting.command(for: .off).shellString:
            backlightMode = 0
        case CoreBrightnessSetting.command(for: .on).shellString:
            guard backlightMode != nil else {
                throw LogoLightError.commandFailed(
                    exitCode: 1,
                    message: "Error: Domain 'com.apple.CoreBrightness' not found.\nDefaults have not been changed.")
            }
            backlightMode = nil
        default:
            return
        }
        if daemonResponds {
            appliedOn = backlightMode != 0
            onDefaultChanged?(backlightMode)
        }
    }

    private func installRule() throws {
        guard installsRule else {
            throw LogoLightError.commandFailed(exitCode: 1, message: "install: Operation not permitted")
        }
        ruleInstalled = true
    }

    func nvramValue(forKey key: String) -> Data? {
        hasLogo && key == LogoHardware.nvramKey ? Data(nvramCopy.utf8) : nil
    }

    func serviceProperties(named name: String) -> [String: Any]? {
        guard hasLogo, name == LogoHardware.pwmDeviceName else { return nil }
        return ["enabled": appliedOn && displayAwake, "high-period": 201, "low-period": 759]
    }

    func isBuiltInDisplayAwake() -> Bool? { displayAwake }
    func isExternalDisplayAwake() -> Bool? { externalDisplayAwake }
}

@MainActor
final class FakeAdminShell: AdminShell {
    let mac: SimulatedMac
    var scripts: [String] = []
    var prompts: [String] = []
    var error: Error?

    init(mac: SimulatedMac) { self.mac = mac }

    func run(script: String, prompt: String) throws {
        scripts.append(script)
        prompts.append(prompt)
        if let error { throw error }
        try mac.execute(script)
    }
}

final class FakeSudo: PasswordlessSudo, @unchecked Sendable {
    let mac: SimulatedMac
    /// Whether sudo runs the logo commands without a password. `nil`: when the rule is installed.
    var allowed: Bool?
    var commands: [PrivilegedCommand] = []

    init(mac: SimulatedMac, allowed: Bool?) {
        self.mac = mac
        self.allowed = allowed
    }

    private var isAllowed: Bool { allowed ?? mac.ruleInstalled }

    func run(_ command: PrivilegedCommand) async throws {
        commands.append(command)
        guard isAllowed else { throw LogoLightError.commandFailed(exitCode: 1, message: "sudo: a password is required") }
        try mac.execute(command.shellString)
    }

    func canRun(_ command: PrivilegedCommand) async -> Bool { isAllowed }
}

/// A stand-in for corebrightnessd's light emitter module. It logs every change it's sent,
/// using the real key names, so tests can check the exact sequence. Like the real one, it
/// ignores a `DisplayLogicalState` it's already in, a fade started with a huge duration doesn't
/// move (which is how a level is held), and reading `DisplayLogicalState` gives the last value
/// sent to anything, even if that was only the keyboard. While the logo has been told the lid is
/// closed (`ClamshellUpdate`), it fades out and stays dark whatever `DisplayLogicalState` says, and
/// `CBClamshellState` reads the lid as the daemon itself last saw it (`moveLid(closed:)`). A change
/// that leaves the logo heading where it was (to dark, for a closed lid) starts no fade, so a hold
/// heading for dark survives the lid closing, as on the real Mac.
///
/// Fades move in one of two ways. By default each read moves them a step (`stepPerRead`).
/// With `timeDriven` (and `stepPerRead = 0`), time passing moves them instead, at the real
/// hardware's speed: `Fixture` passes it every sleep through `FakeClock.onSleep`. Like the real
/// one, a time-driven fade moves in frames (`frameInterval`), counted from when it started, so a
/// new fade first moves a frame after it's started and stops where its last frame put it.
@MainActor
final class FakeDaemon: LightEmitterService {
    var mode = 2
    var fadeDuration = 0.0
    /// The fade level (`LEPWMState.Factor`), and the `DisplayLogicalState` it's heading for.
    var level = 1.0
    var state = 2
    /// How far the level moves toward 0 or 1 each time it's read during a fade.
    /// 1 jumps straight there.
    var stepPerRead = 1.0
    /// When true, `elapse(_:)` moves a fade along the hardware's curve.
    var timeDriven = false
    /// How often a time-driven fade moves: measured as about every 17.5 ms, and a restarted fade
    /// first moved 18–20 ms after it was started. 0 moves it continuously.
    var frameInterval = 0.0175
    /// When set, the time to each next frame comes from here instead (the real frames come
    /// 12–19 ms apart).
    var frameIntervals: (() -> Double)?
    private var lastFrame = 0.0
    private var nextFrame = 0.0
    /// The time passed through `elapse(_:)` so far.
    private(set) var time = 0.0
    /// When set, `elapse(_:)` adds the level here every millisecond.
    var trace: [(time: Double, level: Double)]?
    /// Each change sent, as in `log`, with the time it was sent.
    var timeline: [(time: Double, entry: String)] = []
    /// The highest level seen since the test set it.
    var peak = 0.0
    /// The `DisplayLogicalState` the keyboard backlight follows, which is dark on 1.
    var keyboardState = 2
    /// How long a rise from dark (a level of exactly 0) is held back before it starts (time-driven
    /// mode): the real daemon's display-ready gate waits for the display to show a frame, which
    /// took up to 0.17 s with an idle screen. 0 by default.
    var riseDelay = 0.0
    /// The lid as corebrightnessd's own lid handling last saw it (`CBClamshellState`), or `nil`
    /// for a macOS without the key.
    var lidClosed: Bool? = false
    /// The lid as the logo's module and the keyboard were last told (`ClamshellUpdate`).
    private(set) var logoToldLidClosed = false
    private(set) var keyboardToldLidClosed = false
    /// Whether the keyboard backlight is lit: it's dark on Blank, or once told the lid is closed.
    var isKeyboardLit: Bool { keyboardState == 2 && !keyboardToldLidClosed }
    private var lastStateSent = 2
    private var isMoving = false
    /// The time-driven fade in progress: where it started, how long it takes, how long it has run.
    private var fade: (from: Double, length: Double, elapsed: Double)?
    /// When false, every change is rejected (as if the client API stopped working).
    var acceptsChanges = true
    /// When false, changes are accepted but have no effect.
    var appliesChanges = true
    var log: [String] = []
    /// Every key read, in order.
    var keysRead: [String] = []

    var lit: Bool { level >= 0.999 }
    var isHolding: Bool { fadeDuration >= 1e6 }
    /// Where the logo is heading: lit on Unblank, unless it has been told the lid is closed.
    private var end: Double { state == 2 && !logoToldLidClosed ? 1 : 0 }

    /// The fade duration the daemon uses when it's set to 0 (automatic).
    static let automaticFadeDuration = 0.3

    /// The hardware's fade curve, a critically damped spring fitted to the measurements in
    /// docs/corebrightnessd.md: the share of the way covered after `s` of the fade's duration.
    static func progress(_ s: Double) -> Double {
        let k = 6.51
        return s >= 1 ? 1 : 1 - (1 + k * s) * exp(-k * s)
    }

    /// Puts the logo at a level, as if a fade had stopped there.
    func setHeld(at level: Double, state: Int) {
        self.level = level
        self.state = state
        lastStateSent = state
        isMoving = false
        fade = nil
        peak = level
    }

    /// The lid really opening or closing (with an external display, so the Mac stays awake):
    /// corebrightnessd tells every module.
    func moveLid(closed: Bool) {
        lidClosed = closed
        keyboardToldLidClosed = closed
        tellLogo(lidClosed: closed)
    }

    private func tellLogo(lidClosed closed: Bool) {
        let heading = end
        logoToldLidClosed = closed
        if end != heading { startFade() }
    }

    /// A new fade starts from rest, wherever the last one had got to.
    private func startFade() {
        isMoving = !isHolding
        let delay = level <= 0 && end == 1 ? riseDelay : 0
        fade = (from: level, length: fadeDuration > 0 ? fadeDuration : Self.automaticFadeDuration, elapsed: -delay)
        lastFrame = 0
        nextFrame = frameIntervals?() ?? 0
        if stepPerRead >= 1 { advance(by: 1) }
    }

    /// Time passing (time-driven mode only). A fade started at the hold duration moves too,
    /// but far too slowly to see.
    func elapse(_ seconds: Double) {
        let steps = trace == nil ? 1 : max(1, Int((seconds / 0.001).rounded(.up)))
        for _ in 0..<steps { run(for: seconds / Double(steps)) }
    }

    private func run(for seconds: Double) {
        time += seconds
        defer { trace?.append((time, level)) }
        guard timeDriven, var fade else { return }
        fade.elapsed += seconds
        // Held back (`riseDelay`): it starts once that's over.
        guard fade.elapsed > 0 else { self.fade = fade; return }
        // Where its last frame put it, until it reaches the end at its duration.
        var frames = frameInterval > 0 ? (fade.elapsed / frameInterval + 1e-9).rounded(.down) * frameInterval
            : fade.elapsed
        if let frameIntervals {
            while fade.elapsed + 1e-9 >= nextFrame { lastFrame = nextFrame; nextFrame += frameIntervals() }
            frames = lastFrame
        }
        let s = fade.elapsed >= fade.length ? 1 : frames / fade.length
        level = fade.from + (end - fade.from) * Self.progress(s)
        peak = max(peak, level)
        self.fade = s >= 1 ? nil : fade
    }

    func value(forKey key: String) -> Any? {
        keysRead.append(key)
        switch key {
        case "LEBacklightMode": return NSNumber(value: mode)
        case "DisplayLogicalState": return NSNumber(value: lastStateSent)
        case "CBClamshellState": return lidClosed.map { NSNumber(value: $0) }
        case "LEPWMState":
            advance(by: stepPerRead)
            return ["Factor": NSNumber(value: level)]
        default: return nil
        }
    }

    func setValue(_ value: NSNumber, forKey key: String) -> Bool {
        switch key {
        case "LEBacklightMode": log.append("mode=\(value.intValue)")
        case "LEPWMFactorFadeDuration": log.append("fade=\(value.doubleValue)")
        case "DisplayLogicalState": log.append(value.intValue == 1 ? "blank" : value.intValue == 2 ? "unblank" : "state=\(value)")
        default: log.append("\(key)=\(value)")
        }
        timeline.append((time, log[log.count - 1]))
        guard acceptsChanges else { return false }
        guard appliesChanges else { return true }
        switch key {
        case "LEBacklightMode": mode = value.intValue
        case "LEPWMFactorFadeDuration": fadeDuration = value.doubleValue
        case "DisplayLogicalState":
            lastStateSent = value.intValue
            keyboardState = value.intValue
            guard value.intValue != state else { break }
            let heading = end
            state = value.intValue
            if end != heading { startFade() }
        case "ClamshellUpdate":
            keyboardToldLidClosed = value.boolValue
            tellLogo(lidClosed: value.boolValue)
        default: break
        }
        return true
    }

    func setKeyboardValue(_ value: NSNumber, forKey key: String) {
        switch key {
        case "DisplayLogicalState":
            keyboardState = value.intValue
            lastStateSent = value.intValue
        case "ClamshellUpdate":
            log.append("keyboard ClamshellUpdate=\(value)")
            timeline.append((time, log[log.count - 1]))
            keyboardToldLidClosed = value.boolValue
        default: break
        }
    }

    private func advance(by step: Double) {
        guard isMoving, step > 0 else { return }
        level = end > level ? min(end, level + step) : max(end, level - step)
        peak = max(peak, level)
        if level == end { isMoving = false; fade = nil }
    }
}

/// Records sleeps and lets them return straight away, after handing the time slept to
/// `onSleep` (which moves a time-driven `FakeDaemon`). Like `Task.sleep`, it throws if the
/// task is cancelled. After `budget` sleeps it throws too, which ends an effect loop so tests
/// can inspect what it did.
@MainActor
final class FakeClock {
    var slept: [Double] = []
    var budget = Int.max
    /// The total time slept so far, by every task.
    private(set) var now = 0.0
    var onSleep: (@MainActor (Double) -> Void)?
    /// When true, a sleep cancelled once its time has passed (in `onSleep`, or while it waits for
    /// the main actor) returns normally, as the real `Task.sleep` does. By default it throws,
    /// which ends loops sooner.
    var returnsWhenCancelledLate = false

    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        slept.append(seconds)
        budget -= 1
        if budget < 0 { throw CancellationError() }
        now += seconds
        onSleep?(seconds)
        await Task.yield()
        if !returnsWhenCancelledLate { try Task.checkCancellation() }
    }
}

/// A stand-in for the sound the Mac plays, so tests never tap the real audio. Its loudness is `level`,
/// or `script` evaluated at `time` (the fake daemon's), for beats.
@MainActor
final class FakeSound: SoundLevelSource {
    var level = 0.0
    var script: ((Double) -> Double)?
    var time: @MainActor () -> Double = { 0 }
    /// Thrown by `start()`, e.g. without permission to hear the sound.
    var error: Error?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var isListening = false

    func start() throws {
        if let error { throw error }
        starts += 1
        isListening = true
    }

    func stop() {
        if isListening { stops += 1 }
        isListening = false
    }

    var loudness: Double { script?(time()) ?? level }
}

/// A stand-in for the internal battery, so tests never read the real one.
@MainActor
final class FakeBattery {
    /// From 0 to 1, or `nil` when it can't be read.
    var charge: Double? = 1
    var reads = 0
    /// Whether it's charging, or `nil` when that (and whether it's plugged in) can't be read.
    var isCharging: Bool? = false
    /// Whether the Mac is plugged in. `nil` means exactly while it's charging.
    var isPluggedIn: Bool?
    /// How many times the charging light read the power.
    var chargingReads = 0
}

/// Holds the controller's waits that aren't animation (for charging to start after a plug-in) until
/// `fire()`, so they neither return at once nor move the fake clock, as `FakeClock`'s sleeps do.
@MainActor
final class FakeTimer {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// The length of every wait asked for.
    private(set) var requested: [Double] = []
    var pending: Int { waiting.count }

    func sleep(_ seconds: Double) async throws {
        requested.append(seconds)
        await withCheckedContinuation { waiting.append($0) }
        try Task.checkCancellation()
    }

    /// Ends every wait. A cancelled one then throws, as `Task.sleep` does.
    func fire() {
        let ending = waiting
        waiting = []
        for wait in ending { wait.resume() }
    }
}

@MainActor
struct Fixture {
    let mac: SimulatedMac
    let admin: FakeAdminShell
    let sudo: FakeSudo
    let daemon: FakeDaemon
    let clock: FakeClock
    let battery = FakeBattery()
    let sound = FakeSound()
    let timer = FakeTimer()
    let controller: LogoController

    /// `direct: true` gives the controller a (fake) corebrightnessd to control the logo through.
    /// `timeDriven: true` makes its fades move as the controller sleeps, at the hardware's speed.
    init(backlightMode: Int? = nil, ruleInstalled: Bool = false, sudoAllows: Bool? = nil, direct: Bool = false,
         timeDriven: Bool = false) {
        mac = SimulatedMac(backlightMode: backlightMode)
        mac.ruleInstalled = ruleInstalled
        admin = FakeAdminShell(mac: mac)
        sudo = FakeSudo(mac: mac, allowed: sudoAllows)
        daemon = FakeDaemon()
        daemon.mode = backlightMode == 0 ? 0 : 2
        if timeDriven {
            daemon.timeDriven = true
            daemon.stepPerRead = 0
        }
        mac.onDefaultChanged = { [daemon] in daemon.mode = $0 == 0 ? 0 : 2 }
        let clock = FakeClock()
        clock.onSleep = { [daemon] in daemon.elapse($0) }
        self.clock = clock
        sound.time = { [daemon] in daemon.time }
        controller = LogoController(
            reader: LogoStatusReader(hardware: mac),
            emitter: direct ? LightEmitter(service: daemon, clock: { [daemon] in daemon.time }) : nil,
            admin: admin,
            sudo: sudo,
            isRuleInstalled: { [mac] in mac.ruleInstalled },
            verificationTimeout: .milliseconds(300),
            sleep: { try await clock.sleep($0) },
            batteryCharge: { [battery] in
                battery.reads += 1
                return battery.charge
            },
            powerState: { [battery] in
                battery.chargingReads += 1
                guard let charging = battery.isCharging else { return nil }
                return Battery.PowerState(isPluggedIn: battery.isPluggedIn ?? charging, isCharging: charging,
                                          isFull: (battery.charge ?? 0) >= 1)
            },
            wait: { [timer] in try await timer.sleep($0) },
            soundSource: sound
        )
    }
}

@MainActor
func controllerTests(_ t: TestHarness) async {
    print("\nController: documented defaults command (no direct control)")

    await t.test("turns the logo off through the password dialog") {
        let f = Fixture()
        let status = try await f.controller.set(.off)
        t.expectEqual(status.setting, .off)
        t.expectEqual(status.source, .led)
        t.expectEqual(status.isLit, false)
        t.expectEqual(f.mac.backlightMode, 0)
        t.expectEqual(f.admin.scripts, [CoreBrightnessSetting.command(for: .off).shellString])
        t.expect(f.sudo.commands.isEmpty, "sudo shouldn't be tried without the rule")
    }

    await t.test("turns the logo back on by deleting the default") {
        let f = Fixture(backlightMode: 0)
        let status = try await f.controller.set(.on)
        t.expectEqual(status.setting, .on)
        t.expectEqual(f.mac.backlightMode, nil)
    }

    await t.test("treats turning on an already-default logo as success") {
        let f = Fixture(backlightMode: nil)
        let status = try await f.controller.set(.on)
        t.expectEqual(status.setting, .on)
    }

    await t.test("toggle flips the current setting both ways") {
        let f = Fixture()
        t.expectEqual(try await f.controller.toggle().setting, .off)
        t.expectEqual(try await f.controller.toggle().setting, .on)
    }

    await t.test("uses sudo without a dialog when the password-free rule is installed") {
        let f = Fixture(ruleInstalled: true)
        try await f.controller.set(.off)
        t.expectEqual(f.sudo.commands, [CoreBrightnessSetting.command(for: .off)])
        t.expect(f.admin.scripts.isEmpty, "no password dialog expected")
    }

    await t.test("falls back to the dialog if sudo still wants a password") {
        let f = Fixture(ruleInstalled: true, sudoAllows: false)
        try await f.controller.set(.off)
        t.expectEqual(f.sudo.commands.count, 1)
        t.expectEqual(f.admin.scripts.count, 1)
        t.expectEqual(f.mac.backlightMode, 0)
    }

    await t.test("doesn't fall back to the dialog when sudo reports the logo is already on") {
        let f = Fixture(backlightMode: nil, ruleInstalled: true)
        try await f.controller.set(.on)
        t.expect(f.admin.scripts.isEmpty, "no password dialog expected")
    }

    await t.test("reports cancellation of the password dialog") {
        let f = Fixture()
        f.admin.error = LogoLightError.cancelled
        do { try await f.controller.set(.off); t.expect(false, "should throw") }
        catch { t.expectEqual(error as? LogoLightError, .cancelled) }
        t.expectEqual(f.mac.backlightMode, nil)
    }

    await t.test("reports when the hardware doesn't follow the setting") {
        let f = Fixture()
        f.mac.daemonResponds = false
        do { try await f.controller.set(.off); t.expect(false, "should throw") }
        catch { t.expectEqual(error as? LogoLightError, .notApplied(expected: .off)) }
    }

    await t.test("reports the new setting even though the NVRAM copy is stale") {
        let f = Fixture()
        try await f.controller.set(.off)
        t.expectEqual(f.mac.nvramCopy, "true")
        t.expectEqual(f.controller.status().setting, .off)
    }

    await t.test("trusts the setting it applied while the screen is off") {
        let f = Fixture()
        f.mac.displayAwake = false
        let status = try await f.controller.set(.off)
        t.expectEqual(status.setting, .off)
        t.expectEqual(status.source, .lastApplied)
        t.expectEqual(f.controller.status().setting, .off)

        f.mac.displayAwake = true
        t.expectEqual(f.controller.status().source, .led)
        t.expectEqual(f.controller.status().setting, .off)
    }

    await t.test("refuses to run on a Mac without an illuminated logo") {
        let f = Fixture()
        f.mac.hasLogo = false
        do { try await f.controller.toggle(); t.expect(false, "should throw") }
        catch { t.expectEqual(error as? LogoLightError, .unsupportedMac) }
        t.expect(f.admin.scripts.isEmpty, "nothing should run")
    }

    await t.test("installs the password-free rule through the dialog and verifies it") {
        let f = Fixture(sudoAllows: true)
        try await f.controller.enablePasswordless()
        t.expectEqual(f.admin.scripts.count, 1)
        t.expect(f.admin.scripts[0].contains("/usr/sbin/visudo"), "install script should validate the rule")
    }

    await t.test("reports a rule that sudo doesn't honor") {
        let f = Fixture(sudoAllows: false)
        do { try await f.controller.enablePasswordless(); t.expect(false, "should throw") }
        catch { t.expectEqual(error as? LogoLightError, .passwordlessRuleNotHonored) }
    }

    t.test("removes the password-free rule through the dialog") {
        let f = Fixture(ruleInstalled: true)
        try f.controller.disablePasswordless()
        t.expectEqual(f.admin.scripts, [PasswordlessRule.removeScript])
        t.expect(!f.controller.isPasswordlessEnabled)
    }

    print("\nController: a password only once")

    await t.test("the first password dialog also installs the rule, and the next switch needs none") {
        let f = Fixture()
        f.controller.autoEnablesPasswordless = true
        try await f.controller.set(.off)
        t.expectEqual(f.admin.scripts.count, 1)
        let script = f.admin.scripts.first ?? ""
        t.expect(script.contains("/usr/sbin/visudo"), "the dialog's script should install the rule")
        t.expect(script.hasSuffix(CoreBrightnessSetting.command(for: .off).shellString), "and then run the command")
        t.expect(f.admin.prompts.first?.contains("without your password") == true, "the dialog should say so")
        t.expectEqual(f.mac.backlightMode, 0)
        t.expect(f.controller.isPasswordlessEnabled)

        try await f.controller.set(.on)
        t.expectEqual(f.admin.scripts.count, 1)
        t.expectEqual(f.sudo.commands, [CoreBrightnessSetting.command(for: .on)])
        t.expectEqual(f.mac.backlightMode, nil)
    }

    await t.test("turning on when it's already on still succeeds when the rule is installed with it") {
        let f = Fixture(backlightMode: nil)
        f.controller.autoEnablesPasswordless = true
        let status = try await f.controller.set(.on)
        t.expectEqual(status.setting, .on)
        t.expectEqual(f.admin.scripts.count, 1)
        t.expect(f.controller.isPasswordlessEnabled)
        // The script failed (nothing to delete), but the rule works, so it isn't given up on.
        t.expect(f.controller.autoEnablesPasswordless)
    }

    await t.test("a rule that fails to install doesn't stop the switch") {
        let f = Fixture()
        f.controller.autoEnablesPasswordless = true
        f.mac.installsRule = false
        try await f.controller.set(.off)
        t.expectEqual(f.mac.backlightMode, 0)
        t.expect(!f.controller.isPasswordlessEnabled)
    }

    await t.test("after a rule that fails to install, the next dialog doesn't promise it again") {
        // In the second order the first command fails too (the logo is already on), which set()
        // takes as success.
        for targets in [[LogoIllumination.off, .on], [.on, .off]] {
            let f = Fixture()
            f.controller.autoEnablesPasswordless = true
            f.mac.installsRule = false
            for target in targets { try await f.controller.set(target) }
            t.expectEqual(f.admin.prompts.map { $0.contains("without your password") }, [true, false])
            t.expectEqual(f.admin.scripts.last, CoreBrightnessSetting.command(for: targets[1]).shellString)
            t.expect(!f.controller.autoEnablesPasswordless)
        }
    }

    await t.test("after a rule that sudo doesn't honor, the next dialog doesn't promise it again") {
        let f = Fixture(sudoAllows: false)
        f.controller.autoEnablesPasswordless = true
        try await f.controller.set(.off)
        t.expect(f.controller.isPasswordlessEnabled)
        t.expect(!f.controller.autoEnablesPasswordless)
    }

    await t.test("after Disable Password's own install fails, the next dialog doesn't promise the rule") {
        let f = Fixture()
        f.controller.autoEnablesPasswordless = true
        f.mac.installsRule = false
        do { try await f.controller.enablePasswordless(); t.expect(false, "should throw") } catch {}
        t.expect(!f.controller.autoEnablesPasswordless)
        try await f.controller.set(.off)
        t.expectEqual(f.admin.prompts.map { $0.contains("without your password") }, [false, false])
        t.expectEqual(f.admin.scripts.last, CoreBrightnessSetting.command(for: .off).shellString)
    }

    await t.test("a cancelled dialog offers the rule again next time") {
        let f = Fixture()
        f.controller.autoEnablesPasswordless = true
        f.admin.error = LogoLightError.cancelled
        do { try await f.controller.set(.off) } catch {}
        t.expect(f.controller.autoEnablesPasswordless)
        f.admin.error = nil
        try await f.controller.set(.off)
        t.expect(f.admin.prompts.map { $0.contains("without your password") } == [true, true], "\(f.admin.prompts)")
        t.expect(f.controller.isPasswordlessEnabled)
    }

    await t.test("after the rule was removed on purpose, the dialog only runs the command") {
        let f = Fixture()
        f.controller.autoEnablesPasswordless = false
        try await f.controller.set(.off)
        t.expectEqual(f.admin.scripts, [CoreBrightnessSetting.command(for: .off).shellString])
        t.expectEqual(f.admin.prompts, ["LogoLight wants to turn off the illuminated Apple logo."])
        t.expect(!f.controller.isPasswordlessEnabled)
    }

    await t.test("checking Disable Password turns installing with the password back on, once it has worked") {
        let f = Fixture()
        f.controller.autoEnablesPasswordless = false // unchecked before
        f.admin.error = LogoLightError.cancelled
        do { try await f.controller.enablePasswordless(); t.expect(false, "should throw") } catch {}
        t.expect(!f.controller.autoEnablesPasswordless, "a cancelled dialog keeps the earlier choice")
        f.admin.error = nil
        try await f.controller.set(.off)
        t.expectEqual(f.admin.scripts.last, CoreBrightnessSetting.command(for: .off).shellString)

        try await f.controller.enablePasswordless()
        t.expect(f.controller.autoEnablesPasswordless)
    }

    t.test("unchecking Disable Password turns installing with the password off, once it has worked") {
        let f = Fixture(ruleInstalled: true)
        f.controller.autoEnablesPasswordless = true
        f.admin.error = LogoLightError.cancelled
        t.expectThrows { try f.controller.disablePasswordless() }
        t.expect(f.controller.autoEnablesPasswordless, "a cancelled dialog keeps the earlier choice")
        t.expect(f.controller.isPasswordlessEnabled)
        f.admin.error = nil
        try f.controller.disablePasswordless()
        t.expect(!f.controller.autoEnablesPasswordless)
    }

    await t.test("a rule that sudo doesn't honor falls back to a dialog that only runs the command") {
        let f = Fixture(ruleInstalled: true, sudoAllows: false)
        f.controller.autoEnablesPasswordless = true
        try await f.controller.set(.off)
        t.expectEqual(f.admin.scripts, [CoreBrightnessSetting.command(for: .off).shellString])
    }

    await t.test("with direct control, nothing is installed") {
        let f = Fixture(direct: true)
        f.controller.autoEnablesPasswordless = true
        f.controller.switchFadeDuration = 0
        try await f.controller.set(.off)
        try await f.controller.set(.on)
        t.expect(f.admin.scripts.isEmpty, "no password dialog expected")
        t.expect(!f.controller.isPasswordlessEnabled)
    }

    print("\nController: before a password dialog")

    await t.test("waits for the app before showing the dialog, with or without the rule's install") {
        for autoEnables in [false, true] {
            let f = Fixture()
            f.controller.autoEnablesPasswordless = autoEnables
            let hook = PromptHook(f)
            try await f.controller.set(.off)
            t.expectEqual(hook.dialogsShownByThen, [0])
            t.expectEqual(f.admin.scripts.count, 1)
        }
    }

    await t.test("doesn't call the app when sudo switches without a dialog") {
        let f = Fixture(ruleInstalled: true)
        let hook = PromptHook(f)
        try await f.controller.set(.off)
        try await f.controller.set(.on)
        t.expectEqual(hook.dialogsShownByThen, [])
        t.expectEqual(f.sudo.commands.count, 2)
    }

    await t.test("calls the app when sudo wants a password after all") {
        let f = Fixture(ruleInstalled: true, sudoAllows: false)
        let hook = PromptHook(f)
        try await f.controller.set(.off)
        t.expectEqual(f.sudo.commands.count, 1)
        t.expectEqual(hook.dialogsShownByThen, [0])
        t.expectEqual(f.admin.scripts.count, 1)
    }

    await t.test("calls the app when corebrightnessd rejects a direct switch") {
        let f = Fixture(direct: true)
        f.daemon.acceptsChanges = false
        f.controller.switchFadeDuration = 0
        let hook = PromptHook(f)
        try await f.controller.set(.off)
        t.expectEqual(hook.dialogsShownByThen, [0])
        t.expectEqual(f.admin.scripts.count, 1)
        t.expectEqual(f.mac.backlightMode, 0)
    }
}

/// Stands in for the app's `willPromptForPassword`, which waits for its menu to close: it takes a
/// moment, then records how many dialogs had been shown by then.
@MainActor
final class PromptHook {
    private(set) var dialogsShownByThen: [Int] = []

    init(_ f: Fixture) {
        f.controller.willPromptForPassword = { [self, admin = f.admin] in
            for _ in 0..<5 { await Task.yield() }
            dialogsShownByThen.append(admin.scripts.count)
        }
    }
}
