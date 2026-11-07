import Foundation

/// Reads and changes the illuminated logo setting, sets its brightness, and plays effects.
///
/// It controls the logo through `corebrightnessd` directly when it can (no password, smooth
/// fades, brightness, effects), and otherwise falls back to Apple's documented `defaults`
/// command as root.
@MainActor
public final class LogoController {
    private let reader: LogoStatusReader
    private let emitter: LightEmitter?
    private let admin: AdminShell
    private let sudo: PasswordlessSudo
    private let isRuleInstalled: @MainActor () -> Bool
    private let verificationTimeout: Duration
    private let sleep: LogoAnimator.Sleep
    /// The setting this process last applied, for when the hardware can't show it.
    private var lastApplied: LogoIllumination?

    /// Plays effects and holds the brightness. `nil` when the logo can't be controlled directly.
    public let animator: LogoAnimator?

    /// How long the logo fades when it's switched on or off directly. 0 switches instantly.
    public var switchFadeDuration: Double = 1.0

    public init(
        reader: LogoStatusReader,
        emitter: LightEmitter?,
        admin: AdminShell,
        sudo: PasswordlessSudo,
        isRuleInstalled: @escaping @MainActor () -> Bool,
        verificationTimeout: Duration = .seconds(3),
        sleep: @escaping LogoAnimator.Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.reader = reader
        self.emitter = emitter
        self.admin = admin
        self.sudo = sudo
        self.isRuleInstalled = isRuleInstalled
        self.verificationTimeout = verificationTimeout
        self.sleep = sleep
        animator = emitter.map { emitter in
            LogoAnimator(emitter: emitter, isDisplayAwake: { reader.isDisplayAwake() ?? false }, sleep: sleep)
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

    /// Whether the logo can be controlled without a password (and brightness and effects are available).
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
                if target == .on, isDisplayAwake { animator?.resume() }
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
        if target == .on, isDisplayAwake { animator?.resume() }
        return try await waitForSetting(target)
    }

    /// Flips the current setting.
    @discardableResult
    public func toggle() async throws -> LogoStatus {
        let current = status()
        guard current.isSupported else { throw LogoLightError.unsupportedMac }
        return try await set((current.setting ?? .on).toggled)
    }

    // MARK: - Effects and brightness

    /// The chosen effect.
    public var effect: LogoEffect { animator?.effect ?? .none }

    /// Chooses an effect, and plays it now if the logo is on and the display is awake.
    /// Choosing `.none` returns the logo to the chosen brightness.
    public func setEffect(_ effect: LogoEffect) {
        guard let animator else { return }
        animator.select(effect)
        if isLitAndAwake { animator.resume() } else { animator.pause() }
    }

    /// How bright the logo is (or how bright effects peak), from 0 (dimmest) to 1 (normal).
    public var brightness: Double { animator?.brightness ?? 1 }

    public func setBrightness(_ brightness: Double) {
        guard let animator else { return }
        animator.brightness = brightness
        if isLitAndAwake { animator.brightnessDidChange() }
    }

    /// How brightly the logo is glowing at this moment, from 0 (dark) to 1 (fully lit), for a live
    /// view. It's read from the hardware on every call, so it follows effects and changes made
    /// elsewhere, and it's scaled about like the brightness slider rather than in raw light output.
    public var liveGlow: Double {
        guard let emitter else { return status().isLit == true ? 1 : 0 }
        guard emitter.setting == .on, let level = emitter.fadeLevel else { return 0 }
        return min(max(level, 0), 1).squareRoot()
    }

    /// Call when the display or the Mac goes to sleep.
    public func displayDidSleep() {
        animator?.pause()
        // So corebrightnessd's own fades (when the display sleeps and wakes) work normally,
        // instead of using a brightness hold's endless duration.
        emitter?.setFadeDuration(0)
        // A fade just before the display slept may have told the keyboard it was still on.
        emitter?.displayDidChange(isAwake: false)
    }

    /// Call when the display wakes up.
    public func displayDidWake() {
        guard isDisplayAwake else { return }
        emitter?.displayDidChange(isAwake: true)
        if status().setting == .on { animator?.resume() }
    }

    /// Returns the logo to normal (fully lit), e.g. before quitting or after an effect was
    /// interrupted by a crash. The chosen effect and brightness are kept.
    public func restoreNormalLighting() {
        animator?.reset()
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

    private var isLitAndAwake: Bool { isDisplayAwake && status().setting == .on }

    /// Switches through `corebrightnessd`, fading if the display is on.
    /// Returns `false` if the daemon didn't take the change.
    private func setDirectly(_ target: LogoIllumination, emitter: LightEmitter) async throws -> Bool {
        animator?.pause()
        let awake = isDisplayAwake
        let fade = awake ? switchFadeDuration : 0

        if target == .off {
            if fade > 0 { try? await emitter.fade(to: 0, over: fade, sleep: sleep) }
            let applied = emitter.setSetting(.off) && emitter.setting == .off
            // Back to normal. While the setting is off, relighting has no visible effect.
            emitter.restore(displayAwake: awake)
            return applied
        }

        // Start from dark, so turning on doesn't flash before the fade begins.
        if fade > 0 { try? await emitter.fade(to: 0, over: 0.05, sleep: sleep) }
        let applied = emitter.setSetting(.on) && emitter.setting == .on
        if applied, fade > 0 {
            let level = animator?.level ?? 1
            try? await emitter.fade(to: level, over: fade, sleep: sleep)
            if level < 1 { return true } // Now held at the chosen brightness.
        }
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
