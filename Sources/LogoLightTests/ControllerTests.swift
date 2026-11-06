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
        if daemonResponds { appliedOn = backlightMode != 0 }
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

@MainActor
private struct Fixture {
    let mac: SimulatedMac
    let admin: FakeAdminShell
    let sudo: FakeSudo
    let controller: LogoController

    init(backlightMode: Int? = nil, ruleInstalled: Bool = false, sudoAllows: Bool? = nil) {
        mac = SimulatedMac(backlightMode: backlightMode)
        admin = FakeAdminShell(mac: mac)
        sudo = FakeSudo(mac: mac, allowed: sudoAllows ?? ruleInstalled)
        controller = LogoController(
            reader: LogoStatusReader(hardware: mac),
            admin: admin,
            sudo: sudo,
            isRuleInstalled: { ruleInstalled },
            verificationTimeout: .milliseconds(300)
        )
    }
}

@MainActor
func controllerTests(_ t: TestHarness) async {
    print("\nController")

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
