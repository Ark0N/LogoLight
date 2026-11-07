import Foundation
import LogoLightCore

/// A simulated PROLED MacBook Pro, modelled on how the real one behaves: the LED follows
/// the `LEBacklightMode` default immediately, but the NVRAM copy keeps its value from boot.
final class SimulatedMac: HardwareReading, @unchecked Sendable {
    /// The root `com.apple.CoreBrightness` `LEBacklightMode` value, `nil` when deleted.
    var backlightMode: Int?
    var hasLogo = true
    var displayAwake = true
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
/// sent to anything, even if that was only the keyboard.
///
/// Fades move in one of two ways. By default each read moves them a step (`stepPerRead`).
/// With `timeDriven` (and `stepPerRead = 0`), time passing moves them instead, at the real
/// hardware's speed: `Fixture` passes it every sleep through `FakeClock.onSleep`.
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
    /// The highest level seen since the test set it.
    var peak = 0.0
    /// The `DisplayLogicalState` the keyboard backlight follows, which is dark on 1.
    var keyboardState = 2
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

    /// Time passing (time-driven mode only). A fade started at the hold duration moves too,
    /// but far too slowly to see.
    func elapse(_ seconds: Double) {
        guard timeDriven, var fade else { return }
        fade.elapsed += seconds
        let end: Double = state == 2 ? 1 : 0
        let s = fade.elapsed / fade.length
        level = fade.from + (end - fade.from) * Self.progress(s)
        peak = max(peak, level)
        self.fade = s >= 1 ? nil : fade
    }

    func value(forKey key: String) -> Any? {
        keysRead.append(key)
        switch key {
        case "LEBacklightMode": return NSNumber(value: mode)
        case "DisplayLogicalState": return NSNumber(value: lastStateSent)
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
        guard acceptsChanges else { return false }
        guard appliesChanges else { return true }
        switch key {
        case "LEBacklightMode": mode = value.intValue
        case "LEPWMFactorFadeDuration": fadeDuration = value.doubleValue
        case "DisplayLogicalState":
            lastStateSent = value.intValue
            keyboardState = value.intValue
            guard value.intValue != state else { break }
            state = value.intValue
            isMoving = !isHolding
            // A new fade starts from rest, wherever the last one had got to.
            fade = (from: level, length: fadeDuration > 0 ? fadeDuration : Self.automaticFadeDuration, elapsed: 0)
            if stepPerRead >= 1 { advance(by: 1) }
        default: break
        }
        return true
    }

    func setKeyboardValue(_ value: NSNumber, forKey key: String) {
        guard key == "DisplayLogicalState" else { return }
        keyboardState = value.intValue
        lastStateSent = value.intValue
    }

    private func advance(by step: Double) {
        guard isMoving, step > 0 else { return }
        let end: Double = state == 2 ? 1 : 0
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

    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        slept.append(seconds)
        budget -= 1
        if budget < 0 { throw CancellationError() }
        now += seconds
        onSleep?(seconds)
        await Task.yield()
        try Task.checkCancellation()
    }
}

@MainActor
struct Fixture {
    let mac: SimulatedMac
    let admin: FakeAdminShell
    let sudo: FakeSudo
    let daemon: FakeDaemon
    let clock: FakeClock
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
        controller = LogoController(
            reader: LogoStatusReader(hardware: mac),
            emitter: direct ? LightEmitter(service: daemon) : nil,
            admin: admin,
            sudo: sudo,
            isRuleInstalled: { [mac] in mac.ruleInstalled },
            verificationTimeout: .milliseconds(300),
            sleep: { try await clock.sleep($0) }
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
    }

    await t.test("a rule that fails to install doesn't stop the switch") {
        let f = Fixture()
        f.controller.autoEnablesPasswordless = true
        f.mac.installsRule = false
        try await f.controller.set(.off)
        t.expectEqual(f.mac.backlightMode, 0)
        t.expect(!f.controller.isPasswordlessEnabled)
    }

    await t.test("after the rule was removed on purpose, the dialog only runs the command") {
        let f = Fixture()
        f.controller.autoEnablesPasswordless = false
        try await f.controller.set(.off)
        t.expectEqual(f.admin.scripts, [CoreBrightnessSetting.command(for: .off).shellString])
        t.expectEqual(f.admin.prompts, ["LogoLight wants to turn off the illuminated Apple logo."])
        t.expect(!f.controller.isPasswordlessEnabled)
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
