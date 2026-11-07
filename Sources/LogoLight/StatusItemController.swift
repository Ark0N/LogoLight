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

    private let panel = ControlPanel()
    private let panelItem = NSMenuItem()
    private let passwordlessItem = NSMenuItem()
    private let launchAtLoginItem = NSMenuItem()

    private var status = LogoStatus.unsupported
    private var isBusy = false
    private var backgroundRefresh: Timer?
    private var liveRefresh: Timer?
    private var liveView: Timer?
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
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refresh()
        // Pick up changes made elsewhere, e.g. from Terminal.
        backgroundRefresh = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        panelItem.view = panel
        panel.onLogoSwitched = { [weak self] isOn in self?.setLogo(on: isOn) }
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
        refresh()
        // Keep the panel current while the menu is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        liveRefresh = timer

        // The live view reads the real logo on every frame, so it's only drawn while it's visible.
        panel.showGlow(controller.liveGlow)
        let frames = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.showGlow(self.controller.liveGlow)
            }
        }
        RunLoop.main.add(frames, forMode: .eventTracking)
        liveView = frames
    }

    func menuDidClose(_ menu: NSMenu) {
        liveRefresh?.invalidate()
        liveRefresh = nil
        liveView?.invalidate()
        liveView = nil
        statusItem.menu = nil
    }

    // MARK: - State

    private func refresh() {
        status = controller.status()
        updateIcon()
        updateMenu()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let (symbol, description): (String, String) = switch (status.isSupported, status.setting) {
        case (false, _): ("lightbulb.slash", "No illuminated logo on this Mac")
        case (true, .off): ("lightbulb.slash", "Logo illumination off")
        case (true, .on): ("lightbulb.fill", "Logo illumination on")
        case (true, nil): ("lightbulb", "Logo illumination unknown")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !status.isSupported
        button.toolTip = "LogoLight: \(description)\nOption-click to toggle"
    }

    private func updateMenu() {
        panel.update(PanelState(
            isSupported: status.isSupported,
            isOn: status.setting != .off,
            isBusy: isBusy,
            canAnimate: controller.canControlDirectly,
            effect: controller.effect,
            brightness: controller.brightness,
            footer: status.isSupported ? "" : "Needs a MacBook Pro with PROLED XDR Display"
        ))

        // Only needed when the logo can't be controlled directly; kept visible if a rule is
        // already installed, so it can be removed.
        passwordlessItem.isHidden = controller.canControlDirectly && !controller.isPasswordlessEnabled
        passwordlessItem.state = controller.isPasswordlessEnabled ? .on : .off
        passwordlessItem.isEnabled = status.isSupported && !isBusy
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func toggleLogo() {
        perform { [controller] in try await controller.toggle() }
    }

    private func setLogo(on isOn: Bool) {
        perform { [controller] in try await controller.set(isOn ? .on : .off) }
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
            show(error, title: "Couldn't change Launch at Login")
        }
        updateMenu()
    }

    /// Runs a privileged operation, then refreshes and reports any error.
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        updateMenu()
        Task { @MainActor in
            defer {
                isBusy = false
                refresh()
            }
            do {
                try await operation()
            } catch LogoLightError.cancelled {
                // The user closed the password dialog.
            } catch {
                show(error, title: "LogoLight couldn't make the change")
            }
        }
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
