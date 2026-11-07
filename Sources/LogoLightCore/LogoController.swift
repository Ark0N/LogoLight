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
    /// The setting as of the last `status()` or switch, so the live view needn't read it every frame.
    private var knownSetting: LogoIllumination?
    /// The switch's fade in progress, so the display sleeping can cut it short.
    private var switchFadeTask: Task<Void, Error>?
    /// A wake waiting to be handled (see `scheduleWake(after:then:)`).
    private var pendingWake: Task<Void, Never>?

    /// Plays effects and holds the brightness. `nil` when the logo can't be controlled directly.
    public let animator: LogoAnimator?

    /// How long the logo fades when it's switched on or off directly. 0 switches instantly.
    public var switchFadeDuration: Double = 1.0

    /// Whether the first password dialog also installs the password-free rule (fallback path only).
    /// The dialog then says so, and later switches use `sudo` without asking. The app turns this off
    /// once the user has removed the rule, so it isn't installed again. It also goes off when the
    /// install didn't work, so later dialogs don't promise it again.
    public var autoEnablesPasswordless = false

    /// Awaited just before a password dialog is shown while switching. The dialog blocks the app
    /// until it's answered, so the app closes its menu here, which would otherwise sit frozen under
    /// it. Not called when `sudo` makes the switch without a dialog.
    public var willPromptForPassword: (@MainActor () async -> Void)?

    /// Whether the logo is being switched on or off (`set(_:)` is running, one at a time).
    /// Meanwhile, choosing an effect or a brightness only records it, and a wake doesn't restart
    /// anything: the switch applies the latest choices when it's done.
    public private(set) var isSwitching = false

    public init(
        reader: LogoStatusReader,
        emitter: LightEmitter?,
        admin: AdminShell,
        sudo: PasswordlessSudo,
        isRuleInstalled: @escaping @MainActor () -> Bool,
        verificationTimeout: Duration = .seconds(3),
        // A small tolerance: by default, sleeps can run tens of ms late, which shows in effects.
        sleep: @escaping LogoAnimator.Sleep = { try await Task.sleep(for: .seconds($0), tolerance: .milliseconds(2)) }
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
        knownSetting = status.setting
        return status
    }

    public var isPasswordlessEnabled: Bool { isRuleInstalled() }

    /// Turns the logo on or off, and waits until the hardware reflects it.
    @discardableResult
    public func set(_ target: LogoIllumination) async throws -> LogoStatus {
        guard status().isSupported else { throw LogoLightError.unsupportedMac }
        isSwitching = true
        defer { isSwitching = false }

        if let emitter {
            let outcome = try await setDirectly(target, emitter: emitter)
            if outcome != .notApplied {
                didApply(target, atChosenLevel: outcome == .appliedAtLevel)
                return status()
            }
            // corebrightnessd didn't take the change; fall back to the documented command.
        }

        do {
            try await runAsRoot(target)
        } catch where target == .on && CoreBrightnessSetting.isMissingKeyError(error) {
            // Nothing to delete: the setting is already at its default (on).
        }
        lastApplied = target // so a status read while the screen is off shows it
        // At the end, so a choice made while waiting is applied too.
        defer { didApply(target, atChosenLevel: false) }
        return try await waitForSetting(target)
    }

    /// After the setting has changed: starts the chosen effect or brightness, unless the logo is
    /// already held at that brightness.
    private func didApply(_ target: LogoIllumination, atChosenLevel: Bool) {
        lastApplied = target
        if target == .on, !atChosenLevel, isDisplayAwake { animator?.resume() }
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
        guard !isSwitching else { return }
        if isLitAndAwake { animator.resume() } else { animator.pause() }
    }

    /// How bright the logo is (or how bright effects peak), from 0 (dimmest) to 1 (normal).
    public var brightness: Double { animator?.brightness ?? 1 }

    public func setBrightness(_ brightness: Double) {
        guard let animator else { return }
        animator.brightness = brightness
        if !isSwitching, isLitAndAwake { animator.brightnessDidChange() }
    }

    /// How brightly the logo is glowing at this moment, from 0 (dark) to 1 (fully lit), for a live
    /// view. The fade level is read from the hardware on every call, so it follows effects and
    /// changes made elsewhere. The on/off setting comes from the last `status()` (refresh it now
    /// and then), or is read when that isn't known yet. It's scaled about like the brightness
    /// slider rather than in raw light output.
    public var liveGlow: Double {
        guard let emitter else { return status().isLit == true ? 1 : 0 }
        if knownSetting == nil { knownSetting = emitter.setting }
        guard knownSetting == .on, let level = emitter.fadeLevel else { return 0 }
        return min(max(level, 0), 1).squareRoot()
    }

    /// Call when the display or the Mac goes to sleep.
    public func displayDidSleep() {
        pendingWake?.cancel()
        pendingWake = nil
        animator?.pause()
        switchFadeTask?.cancel()
        // So corebrightnessd's own fades (when the display sleeps and wakes) work normally,
        // instead of using a brightness hold's endless duration.
        emitter?.setFadeDuration(0)
        // A fade just before the display slept may have told the keyboard it was still on.
        emitter?.displayDidChange(isAwake: false)
    }

    /// Handles a wake after `delay` seconds (using the injected sleep). Another call before then restarts the
    /// wait, and `displayDidSleep()` cancels it. `completion` runs after a wake is handled.
    ///
    /// A system wake posts more than one notification, and corebrightnessd relights the logo
    /// itself first, so the wake is handled once, a moment later.
    public func scheduleWake(after delay: Double, then completion: @escaping @MainActor () -> Void) {
        pendingWake?.cancel()
        pendingWake = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            pendingWake = nil
            displayDidWake()
            completion()
        }
    }

    /// Call when the display wakes up, to handle it straight away.
    public func displayDidWake() {
        guard isDisplayAwake else { return }
        emitter?.displayDidChange(isAwake: true)
        if !isSwitching, status().setting == .on { animator?.resume() }
    }

    /// Returns the logo to normal (fully lit), e.g. before quitting or after an effect was
    /// interrupted by a crash. The chosen effect and brightness are kept.
    public func restoreNormalLighting() {
        animator?.reset()
    }

    /// Applies the saved choices at launch, after anything a previous run left behind.
    ///
    /// A previous run that didn't quit cleanly may have left the logo held at a level, with the
    /// endless fade duration. If the logo is on and a level or an effect is chosen, it goes
    /// straight there: the fades' own writes replace that duration, without first relighting to
    /// full. Otherwise it's returned to normal, which ends that duration too.
    public func start(brightness: Double?, effect: LogoEffect) {
        guard let animator else { return }
        if let brightness { animator.brightness = brightness }
        animator.select(effect)
        if isLitAndAwake, animator.level < 1 || effect != .none {
            animator.resume()
        } else {
            animator.reset()
        }
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

    /// What `setDirectly` did.
    private enum SwitchOutcome {
        /// corebrightnessd didn't take the change.
        case notApplied
        /// The setting changed. The chosen effect or brightness still needs starting.
        case applied
        /// The setting changed, and the logo is at the chosen brightness, with no effect chosen.
        case appliedAtLevel
    }

    /// Switches through `corebrightnessd`, fading if the display is on.
    ///
    /// The display can sleep or wake during a fade, so it's checked again after each one.
    private func setDirectly(_ target: LogoIllumination, emitter: LightEmitter) async throws -> SwitchOutcome {
        animator?.pause()
        // Like the animator, hold off App Nap, so the fades stop on time.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Switching the Apple logo on or off")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let fade = isDisplayAwake ? switchFadeDuration : 0

        if target == .off {
            if fade > 0 { await switchFade(to: 0, over: fade, emitter: emitter) }
            let applied = emitter.setSetting(.off) && emitter.setting == .off
            if applied { knownSetting = .off }
            // Back to normal. While the setting is off, relighting has no visible effect.
            emitter.restore(displayAwake: isDisplayAwake)
            return applied ? .applied : .notApplied
        }

        // Start from dark, so turning on doesn't flash before the fade begins.
        if fade > 0 { await switchFade(to: 0, over: 0.05, emitter: emitter) }
        guard emitter.setSetting(.on), emitter.setting == .on else {
            emitter.restore(displayAwake: isDisplayAwake)
            return .notApplied
        }
        knownSetting = .on // so the live view shows the fade in
        if fade > 0, isDisplayAwake {
            // An effect takes over from dark, starting with a rising step.
            if effect != .none { return .applied }
            let level = animator?.level ?? 1
            await switchFade(to: level, over: fade, emitter: emitter)
            if isDisplayAwake {
                // Below full it's now held at the level; at full it goes back to normal.
                if level >= 1 { emitter.restore(displayAwake: true) }
                // An effect or brightness chosen during the fade still needs applying.
                return effect == .none && animator?.level == level ? .appliedAtLevel : .applied
            }
        }
        emitter.restore(displayAwake: isDisplayAwake)
        return .applied
    }

    /// One of the switch's fades. `displayDidSleep()` cancels it, so it stops without a hold,
    /// which would relight the keyboard and bring back the endless fade duration.
    private func switchFade(to level: Double, over duration: Double, emitter: LightEmitter) async {
        let task = Task { [sleep] in try await emitter.fade(to: level, over: duration, sleep: sleep) }
        switchFadeTask = task
        _ = await task.result
        switchFadeTask = nil
    }

    /// Runs the documented command for `target` as root: through `sudo` if the password-free rule is
    /// installed, otherwise through the password dialog.
    private func runAsRoot(_ target: LogoIllumination) async throws {
        let command = CoreBrightnessSetting.command(for: target)
        if isRuleInstalled() {
            do {
                try await sudo.run(command)
                return
            } catch where CoreBrightnessSetting.isMissingKeyError(error) {
                throw error
            } catch {
                // The rule is missing or out of date; fall back to the password dialog.
            }
        } else if autoEnablesPasswordless, let rule = try? PasswordlessRule() {
            // The same dialog installs the rule, so this is the last time a password is needed. The
            // command's result is the script's, and a failed install doesn't stop it.
            await willPromptForPassword?()
            do {
                try admin.run(script: rule.installScript(thenRunning: command),
                              prompt: Self.prompt(for: target, enablingPasswordless: true))
            } catch {
                // A cancelled dialog ran nothing, and the next one offers the rule again.
                if (error as? LogoLightError) != .cancelled { await stopAutoEnablingUnlessRuleWorks(for: command) }
                throw error
            }
            await stopAutoEnablingUnlessRuleWorks(for: command)
            return
        }
        await willPromptForPassword?()
        try admin.run(script: command.shellString, prompt: Self.prompt(for: target))
    }

    /// After a dialog that also installed the rule: if the rule isn't there (e.g. a managed Mac refused
    /// it) or `sudo` doesn't honor it, later dialogs only run the command, rather than promising again
    /// what they can't do. For this session only: it isn't the user's choice, so the app doesn't save it.
    private func stopAutoEnablingUnlessRuleWorks(for command: PrivilegedCommand) async {
        let works = isRuleInstalled() ? await sudo.canRun(command) : false
        if !works { autoEnablesPasswordless = false }
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

    static func prompt(for target: LogoIllumination, enablingPasswordless: Bool = false) -> String {
        let action = switch target {
        case .off: "LogoLight wants to turn off the illuminated Apple logo."
        case .on: "LogoLight wants to turn the illuminated Apple logo back on."
        }
        guard enablingPasswordless else { return action }
        return action + " After this, you can turn it on and off without your password "
            + "(change this with Disable Password in LogoLight's menu)."
    }
}
