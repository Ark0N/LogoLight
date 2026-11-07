import AppKit
import LogoLightCore

/// The menu bar icon and its menu, which starts with the control panel.
///
/// Click to open the menu; Option-click to toggle the logo straight away.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let controller: LogoController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let panel = ControlPanel(finish: MacFinish.current() ?? .spaceBlack)
    private let panelItem = NSMenuItem()
    private let passwordlessItem = NSMenuItem()
    private let launchAtLoginItem = NSMenuItem()

    private var status = LogoStatus.unsupported
    /// Waiting for a password or `sudo` (the fallback path).
    private var isBusy = false
    /// The setting the switch asked for, while it's being applied. The panel and the icon show it
    /// straight away, rather than the setting, which only changes after the fade.
    private var requestedSetting: LogoIllumination?
    /// A flip made while a direct switch is being applied: the latest one, applied next.
    private var queuedSetting: LogoIllumination?
    private var switchTask: Task<Void, Never>?
    private var isMenuOpen = false
    /// What's waiting for the menu to close (see `whenMenuClosed(_:)`).
    private var afterMenuCloses: [@MainActor () -> Void] = []
    /// Picks up changes made elsewhere, e.g. from Terminal: every 10 s, or every second while the
    /// menu is open.
    private var refreshTimer: Timer?
    /// Redraws the live view at the display's frame rate while the menu is open.
    private var glowLink: CADisplayLink?
    /// Launch at Login and the sudoers rule, read when the menu opens and after they're changed,
    /// rather than on every refresh.
    private var isLaunchAtLoginEnabled = false
    private var isPasswordlessEnabled = false
    /// The menu bar icon's symbol and description, so it's only replaced when they change.
    private var iconSymbol: (name: String, description: String)?
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let effectDefaultsKey = "Effect"
    private static let brightnessDefaultsKey = "Brightness"

    init(controller: LogoController) {
        self.controller = controller
        super.init()
        buildMenu()

        // Undo anything a previous run left behind (e.g. a crash mid-effect), then
        // bring back the brightness and effect chosen last time.
        controller.restoreNormalLighting()
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.brightnessDefaultsKey) != nil {
            controller.setBrightness(defaults.double(forKey: Self.brightnessDefaultsKey))
        }
        let saved = defaults.string(forKey: Self.effectDefaultsKey).flatMap(LogoEffect.init(rawValue:))
        controller.setEffect(saved ?? .none)
        observeSleepAndWake()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // On the press, like the other menu bar items, not when the button comes back up.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        readMenuSettings()
        refresh()
        scheduleRefresh(every: 10)
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        panelItem.view = panel
        panel.onLogoSwitched = { [weak self] isOn in self?.setLogo(isOn ? .on : .off) }
        panel.onBrightnessChanged = { [weak self] in self?.setBrightness($0) }
        panel.onEffectChosen = { [weak self] in self?.chooseEffect($0) }

        passwordlessItem.title = "Toggle Without Password"
        passwordlessItem.target = self
        passwordlessItem.action = #selector(togglePasswordless)
        passwordlessItem.toolTip = "Lets you turn the logo on and off without entering your password each time."

        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)

        // No ⌘Q: its shortcut column would make the whole menu wider than the panel.
        let quitItem = NSMenuItem(title: "Quit LogoLight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

        menu.items = [
            panelItem,
            .separator(),
            passwordlessItem, launchAtLoginItem,
            .separator(),
            quitItem,
        ]
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            toggleLogo()
        } else {
            openMenu()
        }
    }

    func openMenu() {
        // Attach the menu only while it's open, so Option-click can bypass it.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        readMenuSettings()
        refresh()
        scheduleRefresh(every: 1)

        // The live view reads the real logo on every frame, in step with the display, so it's only
        // drawn while it's visible. (`.common` includes the menu's event-tracking mode.)
        panel.showGlow(controller.liveGlow)
        let link = panel.displayLink(target: self, selector: #selector(showLiveGlow))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        glowLink = link
    }

    @objc private func showLiveGlow(_ link: CADisplayLink) {
        panel.showGlow(controller.liveGlow)
    }

    func menuDidClose(_ menu: NSMenu) {
        scheduleRefresh(every: 10)
        // The link keeps its target alive until it's invalidated.
        glowLink?.invalidate()
        glowLink = nil
        statusItem.menu = nil

        isMenuOpen = false
        let actions = afterMenuCloses
        afterMenuCloses = []
        // On the next turn, once the menu's tracking has ended.
        if !actions.isEmpty {
            DispatchQueue.main.async { MainActor.assumeIsolated { actions.forEach { $0() } } }
        }
    }

    /// Runs `action` once the menu is closed, closing it first if it's open. The password dialog
    /// blocks the app until it's answered, and an alert can't be used inside an open menu, so either
    /// would otherwise sit over a frozen menu.
    private func whenMenuClosed(_ action: @escaping @MainActor () -> Void) {
        guard isMenuOpen else { return action() }
        afterMenuCloses.append(action)
        menu.cancelTracking()
    }

    // MARK: - State

    private func refresh() {
        status = controller.status()
        updateMenu()
    }

    /// Runs `refresh()` every `interval` seconds, replacing the previous timer. It runs in the menu's
    /// event-tracking mode too.
    private func scheduleRefresh(every interval: TimeInterval) {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func readMenuSettings() {
        isLaunchAtLoginEnabled = LaunchAtLogin.isEnabled
        isPasswordlessEnabled = controller.isPasswordlessEnabled
    }

    private var panelState: PanelState {
        PanelState(status: status, requested: requestedSetting, canControlDirectly: controller.canControlDirectly,
                   effect: controller.effect, brightness: controller.brightness, isBusy: isBusy)
    }

    /// Brings the icon, the panel and the menu items up to date with the last status and the choices.
    private func updateMenu() {
        let state = panelState
        updateIcon(state)
        panel.update(state)

        // Only needed when the logo can't be controlled directly; kept visible if a rule is
        // already installed, so it can be removed.
        passwordlessItem.isHidden = controller.canControlDirectly && !isPasswordlessEnabled
        passwordlessItem.state = isPasswordlessEnabled ? .on : .off
        passwordlessItem.isEnabled = status.isSupported && !isBusy
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
    }

    private func updateIcon(_ state: PanelState) {
        guard let button = statusItem.button,
              iconSymbol?.name != state.symbolName || iconSymbol?.description != state.symbolDescription
        else { return }
        iconSymbol = (state.symbolName, state.symbolDescription)
        let image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: state.symbolDescription)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !state.isSupported
        button.toolTip = "LogoLight: \(state.symbolDescription)\nOption-click to toggle"
    }

    // MARK: - Actions

    /// Option-click: flips what the switch shows.
    private func toggleLogo() {
        setLogo((requestedSetting ?? controller.status().setting ?? .on).toggled)
    }

    /// Turns the logo on or off. The switch shows it at once, and the rest of the panel follows.
    ///
    /// With direct control the switch stays usable while the logo fades. A flip made meanwhile is
    /// applied when the fade is done (only the latest, and only if it differs from what was just
    /// applied). Without direct control a password may be needed, and the switch is disabled until
    /// that's done.
    private func setLogo(_ target: LogoIllumination) {
        guard controller.canControlDirectly else {
            guard !isBusy else { return }
            requestedSetting = target
            perform { [controller] in try await controller.set(target) }
            return
        }
        requestedSetting = target
        refresh()
        guard switchTask == nil else {
            queuedSetting = target
            return
        }
        switchTask = Task { [weak self] in await self?.switchDirectly(to: target) }
    }

    private func switchDirectly(to target: LogoIllumination) async {
        var next: LogoIllumination? = target
        while let target = next {
            do {
                try await controller.set(target)
            } catch LogoLightError.cancelled {
                // The user closed the password dialog (corebrightnessd didn't take the change).
            } catch {
                report(error, title: "LogoLight couldn't make the change")
            }
            next = queuedSetting == target ? nil : queuedSetting
            queuedSetting = nil
        }
        switchTask = nil
        requestedSetting = nil
        refresh()
    }

    private func setBrightness(_ brightness: Double) {
        controller.setBrightness(brightness)
        UserDefaults.standard.set(brightness, forKey: Self.brightnessDefaultsKey)
    }

    private func chooseEffect(_ effect: LogoEffect) {
        controller.setEffect(effect)
        UserDefaults.standard.set(effect.rawValue, forKey: Self.effectDefaultsKey)
        refresh()
    }

    /// Returns the logo to normal before the app quits.
    func prepareToQuit() {
        controller.restoreNormalLighting()
    }

    /// Effects pause while the display or the Mac sleeps, and resume on wake.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.displayDidSleep() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Give corebrightnessd a moment to relight the logo for the display first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated {
                        self?.controller.displayDidWake()
                        self?.refresh()
                    }
                }
            })
        }
    }

    @objc private func togglePasswordless() {
        if controller.isPasswordlessEnabled {
            perform { [controller] in try controller.disablePasswordless() }
        } else if confirmEnablingPasswordless() {
            perform { [controller] in try await controller.enablePasswordless() }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
        } catch {
            report(error, title: "Couldn't change Launch at Login")
        }
        isLaunchAtLoginEnabled = LaunchAtLogin.isEnabled
        updateMenu()
    }

    /// Runs a privileged operation, which may ask for a password, once the menu has closed. Then
    /// refreshes and reports any error.
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        updateMenu()
        whenMenuClosed { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    isBusy = false
                    if switchTask == nil { requestedSetting = nil }
                    // The rule may have been added or removed.
                    isPasswordlessEnabled = controller.isPasswordlessEnabled
                    refresh()
                }
                do {
                    try await operation()
                } catch LogoLightError.cancelled {
                    // The user closed the password dialog.
                } catch {
                    report(error, title: "LogoLight couldn't make the change")
                }
            }
        }
    }

    /// Shows an error once the menu has closed.
    private func report(_ error: Error, title: String) {
        whenMenuClosed { [weak self] in self?.show(error, title: title) }
    }

    private func confirmEnablingPasswordless() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Toggle the logo without a password?"
        alert.informativeText = """
            LogoLight will add a rule to /etc/sudoers.d that lets \(NSUserName()) run only the two \
            commands that turn the illuminated Apple logo off and on, without entering a password.

            You'll be asked for your password once. Turn this option off at any time to remove the rule.
            """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func show(_ error: Error, title: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
