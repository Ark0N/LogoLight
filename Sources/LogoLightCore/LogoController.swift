import Foundation

/// Reads and changes the illuminated logo setting, and plays effects.
///
/// It controls the logo through `corebrightnessd` directly when it can (no password, smooth
/// fades, effects), and otherwise falls back to Apple's documented `defaults` command as root.
@MainActor
public final class LogoController {
    private let reader: LogoStatusReader
    private let emitter: LightEmitter?
    private let admin: AdminShell
    private let sudo: PasswordlessSudo
    private let isRuleInstalled: @MainActor () -> Bool
    private let verificationTimeout: Duration
    private let sleep: EffectPlayer.Sleep
    /// The setting this process last applied, for when the hardware can't show it.
    private var lastApplied: LogoIllumination?

    /// Plays effects. `nil` when the logo can't be controlled directly.
    public let effects: EffectPlayer?

    /// How long the logo fades when it's switched on or off directly. 0 switches instantly.
    public var switchFadeDuration: Double = 1.0

    public init(
        reader: LogoStatusReader,
        emitter: LightEmitter?,
        admin: AdminShell,
        sudo: PasswordlessSudo,
        isRuleInstalled: @escaping @MainActor () -> Bool,
        verificationTimeout: Duration = .seconds(3),
        sleep: @escaping EffectPlayer.Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.reader = reader
        self.emitter = emitter
        self.admin = admin
        self.sudo = sudo
        self.isRuleInstalled = isRuleInstalled
        self.verificationTimeout = verificationTimeout
        self.sleep = sleep
        effects = emitter.map { emitter in
            EffectPlayer(emitter: emitter, isDisplayAwake: { reader.isDisplayAwake() ?? false }, sleep: sleep)
        }
    }

    /// The controller for this Mac's real hardware.
    public static func live() -> LogoController {
        LogoController(
            reader: LogoStatusReader(),
            emitter: CoreBrightnessService().map(LightEmitter.init),
            admin: AppleScriptAdminShell(),
            sudo: SudoRunner(),
            isRuleInstalled: { PasswordlessRule.isInstalled }
        )
    }

    /// Whether the logo can be controlled without a password (and effects are available).
    public var canControlDirectly: Bool { emitter != nil }

    public func status() -> LogoStatus {
        var status = reader.read()
        guard status.isSupported else { return status }
        if let setting = emitter?.setting {
            status.setting = setting
            status.source = .daemon
        } else if status.source != .led, let lastApplied {
            // When the LED can't tell us (screen off, lid closed), the NVRAM copy may be out of
            // date, but a setting we applied ourselves is known to be current.
            status.setting = lastApplied
            status.source = .lastApplied
        }
        return status
    }

    public var isPasswordlessEnabled: Bool { isRuleInstalled() }

    /// Turns the logo on or off, and waits until the hardware reflects it.
    @discardableResult
    public func set(_ target: LogoIllumination) async throws -> LogoStatus {
        guard status().isSupported else { throw LogoLightError.unsupportedMac }

        if let emitter {
            if try await setDirectly(target, emitter: emitter) {
                lastApplied = target
                if target == .on { effects?.resume() }
                return status()
            }
            // corebrightnessd didn't take the change; fall back to the documented command.
        }

        do {
            try await runAsRoot(CoreBrightnessSetting.command(for: target), prompt: Self.prompt(for: target))
        } catch where target == .on && CoreBrightnessSetting.isMissingKeyError(error) {
            // Nothing to delete: the setting is already at its default (on).
        }
        lastApplied = target
        if target == .on { effects?.resume() }
        return try await waitForSetting(target)
    }

    /// Flips the current setting.
    @discardableResult
    public func toggle() async throws -> LogoStatus {
        let current = status()
        guard current.isSupported else { throw LogoLightError.unsupportedMac }
        return try await set((current.setting ?? .on).toggled)
    }

    // MARK: - Effects

    /// The chosen effect.
    public var effect: LogoEffect { effects?.effect ?? .none }

    /// Chooses an effect, and plays it now if the logo is on and the display is awake.
    public func setEffect(_ effect: LogoEffect) {
        guard let effects else { return }
        effects.select(effect)
        if effect == .none {
            effects.stop()
        } else if status().setting == .on, isDisplayAwake {
            effects.resume()
        }
    }

    /// Call when the display or the Mac goes to sleep.
    public func displayDidSleep() {
        effects?.pause()
    }

    /// Call when the display wakes up.
    public func displayDidWake() {
        if effect != .none, status().setting == .on { effects?.resume() }
    }

    /// Returns the logo to normal, e.g. before quitting or after an effect was interrupted by a crash.
    public func restoreNormalLighting() {
        effects?.stop()
        emitter?.restore(displayAwake: isDisplayAwake)
    }

    // MARK: - Password-free rule (only used when direct control isn't available)

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

    private var isDisplayAwake: Bool { reader.isDisplayAwake() ?? false }

    /// Switches through `corebrightnessd`, fading if the display is on.
    /// Returns `false` if the daemon didn't take the change.
    private func setDirectly(_ target: LogoIllumination, emitter: LightEmitter) async throws -> Bool {
        effects?.pause()
        let awake = isDisplayAwake
        let fade = awake ? switchFadeDuration : 0

        if fade > 0 {
            if target == .off {
                emitter.setFadeDuration(fade)
                emitter.setLit(false)
                try? await sleep(fade)
            } else {
                // Start from dark, so turning on doesn't flash before the fade begins.
                emitter.setFadeDuration(0.01)
                emitter.setLit(false)
                try? await sleep(0.05)
            }
        }

        let applied = emitter.setSetting(target) && emitter.setting == target

        if applied, target == .on, fade > 0 {
            emitter.setFadeDuration(fade)
            emitter.setLit(true)
            try? await sleep(fade)
        }
        // Back to normal. While the setting is off, relighting has no visible effect.
        emitter.restore(displayAwake: awake)
        return applied
    }

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

    /// Waits for the hardware to follow the new setting, when it can be observed.
    private func waitForSetting(_ target: LogoIllumination) async throws -> LogoStatus {
        let deadline = ContinuousClock.now + verificationTimeout
        while true {
            let current = status()
            if ![.led, .daemon].contains(current.source) || current.setting == target { return current }
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
