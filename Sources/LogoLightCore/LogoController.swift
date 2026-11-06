import Foundation

/// Reads and changes the illuminated logo setting.
@MainActor
public final class LogoController {
    private let reader: LogoStatusReader
    private let admin: AdminShell
    private let sudo: PasswordlessSudo
    private let isRuleInstalled: @MainActor () -> Bool
    private let verificationTimeout: Duration

    public init(
        reader: LogoStatusReader = LogoStatusReader(),
        admin: AdminShell = AppleScriptAdminShell(),
        sudo: PasswordlessSudo = SudoRunner(),
        isRuleInstalled: @escaping @MainActor () -> Bool = { PasswordlessRule.isInstalled },
        verificationTimeout: Duration = .seconds(3)
    ) {
        self.reader = reader
        self.admin = admin
        self.sudo = sudo
        self.isRuleInstalled = isRuleInstalled
        self.verificationTimeout = verificationTimeout
    }

    public func status() -> LogoStatus { reader.read() }

    public var isPasswordlessEnabled: Bool { isRuleInstalled() }

    /// Turns the logo on or off, and waits until the hardware reflects it.
    @discardableResult
    public func set(_ target: LogoIllumination) async throws -> LogoStatus {
        guard status().isSupported else { throw LogoLightError.unsupportedMac }

        do {
            try await runAsRoot(CoreBrightnessSetting.command(for: target), prompt: Self.prompt(for: target))
        } catch where target == .on && CoreBrightnessSetting.isMissingKeyError(error) {
            // Nothing to delete: the setting is already at its default (on).
        }
        return try await waitForSetting(target)
    }

    /// Flips the current setting.
    @discardableResult
    public func toggle() async throws -> LogoStatus {
        let current = status()
        guard current.isSupported else { throw LogoLightError.unsupportedMac }
        return try await set((current.setting ?? .on).toggled)
    }

    /// Installs the sudoers rule so toggling no longer asks for a password.
    public func enablePasswordless() async throws {
        let rule = try PasswordlessRule()
        try admin.run(
            script: rule.installScript,
            prompt: "LogoLight wants to let you turn the Apple logo on and off without entering your password."
        )
        guard await sudo.canRun(CoreBrightnessSetting.command(for: .off)) else {
            throw LogoLightError.passwordlessRuleNotHonored
        }
    }

    /// Removes the sudoers rule.
    public func disablePasswordless() throws {
        try admin.run(
            script: PasswordlessRule.removeScript,
            prompt: "LogoLight wants to require your password again for turning the Apple logo on and off."
        )
    }

    // MARK: - Private

    private func runAsRoot(_ command: PrivilegedCommand, prompt: String) async throws {
        if isRuleInstalled() {
            do {
                try await sudo.run(command)
                return
            } catch where CoreBrightnessSetting.isMissingKeyError(error) {
                throw error
            } catch {
                // The rule is missing or out of date; fall back to the password dialog.
            }
        }
        try admin.run(script: command.shellString, prompt: prompt)
    }

    private func waitForSetting(_ target: LogoIllumination) async throws -> LogoStatus {
        let deadline = ContinuousClock.now + verificationTimeout
        while true {
            let current = status()
            if current.setting == target { return current }
            if ContinuousClock.now >= deadline { throw LogoLightError.notApplied(expected: target) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    static func prompt(for target: LogoIllumination) -> String {
        switch target {
        case .off: "LogoLight wants to turn off the illuminated Apple logo."
        case .on: "LogoLight wants to turn the illuminated Apple logo back on."
        }
    }
}
