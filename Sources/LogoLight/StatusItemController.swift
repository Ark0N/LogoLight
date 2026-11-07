import AppKit
import LogoLightCore

/// The menu bar icon and its menu.
///
/// Click to open the menu; Option-click to toggle the logo straight away.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let controller: LogoController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let headerItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let effectItem = NSMenuItem(title: "Effect", action: nil, keyEquivalent: "")
    private let effectMenu = NSMenu()
    private let passwordlessItem = NSMenuItem()
    private let launchAtLoginItem = NSMenuItem()

    private var status = LogoStatus.unsupported
    private var isBusy = false
    private var backgroundRefresh: Timer?
    private var liveRefresh: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let effectDefaultsKey = "Effect"

    init(controller: LogoController) {
        self.controller = controller
        super.init()
        buildMenu()

        // Undo anything a previous run left behind (e.g. a crash mid-effect), then
        // bring back the effect chosen last time.
        controller.restoreNormalLighting()
        let saved = UserDefaults.standard.string(forKey: Self.effectDefaultsKey).flatMap(LogoEffect.init(rawValue:))
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

        headerItem.isEnabled = false
        detailItem.isEnabled = false

        toggleItem.target = self
        toggleItem.action = #selector(toggleLogo)
        toggleItem.keyEquivalent = "t"

        for effect in LogoEffect.allCases {
            let item = NSMenuItem(title: effect.title, action: #selector(chooseEffect(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = effect.rawValue
            effectMenu.addItem(item)
            if effect == .none { effectMenu.addItem(.separator()) }
        }
        effectMenu.autoenablesItems = false
        effectItem.submenu = effectMenu

        passwordlessItem.title = "Toggle Without Password"
        passwordlessItem.target = self
        passwordlessItem.action = #selector(togglePasswordless)
        passwordlessItem.toolTip = "Lets you turn the logo on and off without entering your password each time."

        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)

        let aboutItem = NSMenuItem(title: "About LogoLight", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        let quitItem = NSMenuItem(title: "Quit LogoLight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.items = [
            headerItem, detailItem,
            .separator(),
            toggleItem, effectItem,
            .separator(),
            passwordlessItem, launchAtLoginItem,
            .separator(),
            aboutItem, quitItem,
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
        // Show the brightness changing live while the menu is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        liveRefresh = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        liveRefresh?.invalidate()
        liveRefresh = nil
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
        headerItem.attributedTitle = NSAttributedString(
            string: headerText,
            attributes: [.font: NSFont.menuFont(ofSize: 0).bold, .foregroundColor: NSColor.labelColor]
        )
        detailItem.title = detailText
        detailItem.isHidden = detailText.isEmpty

        let target = (status.setting ?? .on).toggled
        toggleItem.title = isBusy ? "Working…" : (target == .off ? "Turn Logo Off" : "Turn Logo On")
        toggleItem.isEnabled = status.isSupported && !isBusy

        let canAnimate = controller.canControlDirectly && status.isSupported
        effectItem.isEnabled = canAnimate && !isBusy
        effectItem.toolTip = canAnimate ? nil : "Effects aren't available on this Mac."
        for item in effectMenu.items where item.representedObject != nil {
            item.state = (item.representedObject as? String) == controller.effect.rawValue ? .on : .off
            item.isEnabled = canAnimate && !isBusy
        }

        // Only needed when the logo can't be controlled directly; kept visible if a rule is
        // already installed, so it can be removed.
        passwordlessItem.isHidden = controller.canControlDirectly && !controller.isPasswordlessEnabled
        passwordlessItem.state = controller.isPasswordlessEnabled ? .on : .off
        passwordlessItem.isEnabled = status.isSupported && !isBusy
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    private var headerText: String {
        guard status.isSupported else { return "No Illuminated Logo" }
        switch status.setting {
        case .on: return "Logo Illumination: On"
        case .off: return "Logo Illumination: Off"
        case nil: return "Logo Illumination: Unknown"
        }
    }

    private var detailText: String {
        guard status.isSupported else { return "Requires a MacBook Pro with PROLED XDR Display" }
        switch status.setting {
        case .off:
            return "Off for all users, including in macOS Recovery"
        case .on where status.isLit == false:
            return "Dark while the display is off"
        case .on where controller.effect != .none:
            return "\(controller.effect.title) effect · adapts to ambient light"
        case .on:
            guard let level = status.outputLevel else { return "Adapts to screen brightness and ambient light" }
            return "Glowing at \(Int((level * 100).rounded()))% · adapts to ambient light"
        case nil:
            return ""
        }
    }

    // MARK: - Actions

    @objc private func toggleLogo() {
        perform { [controller] in try await controller.toggle() }
    }

    @objc private func chooseEffect(_ sender: NSMenuItem) {
        guard let effect = (sender.representedObject as? String).flatMap(LogoEffect.init(rawValue:)) else { return }
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

    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "Turns the illuminated Apple logo on the back of the MacBook Pro with PROLED XDR Display on and off, "
                + "and animates it with fades and effects. The on/off setting is the one described in Apple's "
                + "support article “About the illuminated Apple logo”.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
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

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
