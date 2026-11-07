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
    /// What corebrightnessd is currently applying.
    private var appliedOn: Bool
    /// The NVRAM copy, written at boot and not again during the session.
    let nvramCopy: String

    init(backlightMode: Int? = nil) {
        self.backlightMode = backlightMode
        appliedOn = backlightMode != 0
        nvramCopy = appliedOn ? "true" : "false"
    }

    /// Applies a command as root, the way `defaults` would.
    func execute(_ shellString: String) throws {
        switch shellString {
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
            return // e.g. the sudoers install script
        }
        if daemonResponds {
            appliedOn = backlightMode != 0
            onDefaultChanged?(backlightMode)
        }
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
    var error: Error?

    init(mac: SimulatedMac) { self.mac = mac }

    func run(script: String, prompt: String) throws {
        scripts.append(script)
        if let error { throw error }
        try mac.execute(script)
    }
}

final class FakeSudo: PasswordlessSudo, @unchecked Sendable {
    let mac: SimulatedMac
    var allowed: Bool
    var commands: [PrivilegedCommand] = []

    init(mac: SimulatedMac, allowed: Bool) {
        self.mac = mac
        self.allowed = allowed
    }

    func run(_ command: PrivilegedCommand) async throws {
        commands.append(command)
        guard allowed else { throw LogoLightError.commandFailed(exitCode: 1, message: "sudo: a password is required") }
        try mac.execute(command.shellString)
    }

    func canRun(_ command: PrivilegedCommand) async -> Bool { allowed }
}

/// A stand-in for corebrightnessd's light emitter module. It logs every change it's sent,
/// using the real key names, so tests can check the exact sequence. Like the real one, it
/// ignores a `DisplayLogicalState` it's already in, a fade started with a huge duration doesn't
/// move (which is how a level is held), and reading `DisplayLogicalState` gives the last value
/// sent to anything, even if that was only the keyboard.
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
    /// The highest level seen since the test set it.
    var peak = 0.0
    /// The `DisplayLogicalState` the keyboard backlight follows, which is dark on 1.
    var keyboardState = 2
    private var lastStateSent = 2
    private var isMoving = false
    /// When false, every change is rejected (as if the client API stopped working).
    var acceptsChanges = true
    /// When false, changes are accepted but have no effect.
    var appliesChanges = true
    var log: [String] = []

    var lit: Bool { level >= 0.999 }
    var isHolding: Bool { fadeDuration >= 1e6 }

    /// Puts the logo at a level, as if a fade had stopped there.
    func setHeld(at level: Double, state: Int) {
        self.level = level
        self.state = state
        lastStateSent = state
        isMoving = false
        peak = level
    }

    func value(forKey key: String) -> Any? {
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
        guard isMoving else { return }
        let end: Double = state == 2 ? 1 : 0
        level = end > level ? min(end, level + step) : max(end, level - step)
        peak = max(peak, level)
        if level == end { isMoving = false }
    }
}

/// Records sleeps and lets them return immediately. After `budget` sleeps it throws,
/// which ends an effect loop so tests can inspect what it did.
final class FakeClock: @unchecked Sendable {
    var slept: [Double] = []
    var budget = Int.max

    func sleep(_ seconds: Double) async throws {
        slept.append(seconds)
        budget -= 1
        if budget < 0 { throw CancellationError() }
        await Task.yield()
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
    init(backlightMode: Int? = nil, ruleInstalled: Bool = false, sudoAllows: Bool? = nil, direct: Bool = false) {
        mac = SimulatedMac(backlightMode: backlightMode)
        admin = FakeAdminShell(mac: mac)
        sudo = FakeSudo(mac: mac, allowed: sudoAllows ?? ruleInstalled)
        daemon = FakeDaemon()
        daemon.mode = backlightMode == 0 ? 0 : 2
        mac.onDefaultChanged = { [daemon] in daemon.mode = $0 == 0 ? 0 : 2 }
        let clock = FakeClock()
        self.clock = clock
        controller = LogoController(
            reader: LogoStatusReader(hardware: mac),
            emitter: direct ? LightEmitter(service: daemon) : nil,
            admin: admin,
            sudo: sudo,
            isRuleInstalled: { ruleInstalled },
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
    }
}
