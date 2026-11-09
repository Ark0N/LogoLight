import AppKit
import LogoLightCore

/// The iOS Settings-style panel at the top of the menu: a switch for the logo first, where it's
/// easiest to reach, then a live view of it, a brightness slider with the Battery switch under it,
/// then a switch for each effect. Everything below the live view is greyed out while the logo is off,
/// and the slider is while the battery sets the brightness.
@MainActor
final class ControlPanel: NSView {
    var onLogoSwitched: ((Bool) -> Void)?
    var onBrightnessChanged: ((Double) -> Void)?
    var onFollowsBatteryChanged: ((Bool) -> Void)?
    var onEffectChosen: ((LogoEffect) -> Void)?
    /// Play pressed (or Return in the field), with the message typed.
    var onMorsePlay: ((String) -> Void)?
    /// Play pressed while it shows stop: a message is being sent.
    var onMorseStop: (() -> Void)?
    /// The loop switch flipped: on, a message repeats until it's stopped.
    var onMorseLoopsChanged: ((Bool) -> Void)?
    /// The message edited (to remember it for next time).
    var onMorseTextChanged: ((String) -> Void)?

    /// As narrow as the user asked for. The longest label, "Heartbeat" (61 pt at 13 pt, 64 with Bold
    /// Text), still fits between its tile and its switch, which leave it 66. The menu's own items need
    /// only 143, or 153 with Disable Password.
    private static let width: CGFloat = 170
    /// Around the panel's contents (8 at the top), and between its sections.
    private static let inset: CGFloat = 6
    private static let topInset: CGFloat = 8
    private static let spacing: CGFloat = 6
    /// The width of the cards and of everything else in the panel.
    private static let cardWidth = width - 2 * inset
    /// How far text outside the cards is indented, on both sides.
    private static let textIndent: CGFloat = 12
    private static let rowHeight: CGFloat = 36
    /// Where row text starts inside a card.
    fileprivate static let textColumn: CGFloat = 40
    /// Where the icon tiles start inside a card, and their size.
    private static let tileInset: CGFloat = 8
    fileprivate static let tileSize: CGFloat = 24
    /// How far a switch sits from the card's edge (the same as the tiles), and the least room between
    /// it and its label.
    private static let switchInset: CGFloat = 8
    private static let labelSpacing: CGFloat = 4
    /// How the brightness and the effects look while the logo is off.
    private static let greyedOutAlpha: CGFloat = 0.4
    /// How long they take to grey out or come back when the logo is switched.
    private static let greyingDuration = 0.22

    private let stack = NSStackView()
    private let preview: LogoPreview
    private let logoTile = IconTile(symbol: "lightbulb.fill", color: .systemOrange)
    private let logoLabel = NSTextField(labelWithString: "Backlight")
    private let logoSwitch = LogoSwitch()
    private let brightnessCard = Card()
    private let brightnessRow = NSView()
    private let dimIcon = NSImageView()
    private let brightIcon = NSImageView()
    private let brightnessSlider = LogoSlider()
    /// Under the slider, in its card: the battery indicator, which has the brightness follow the charge.
    private let batteryTile = IconTile(symbol: "battery.75percent", color: .systemGreen)
    private let batteryLabel = NSTextField(labelWithString: "Battery")
    private let batterySwitch = LogoSwitch()
    private var batteryRow = NSView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let effectsHeader = NSTextField(labelWithString: "EFFECTS")
    /// Each line of text outside the cards is in one of these, which indents it (and is what's hidden).
    private let messageContainer = NSStackView()
    private let effectsHeaderContainer = NSStackView()
    private let effectsCard = Card()
    private var effectRows: [(effect: LogoEffect, tile: IconTile, label: NSTextField, toggle: LogoSwitch)] = []
    /// The Sound effect's row and the hairline above it, hidden where the sound can't be heard.
    private var soundRows: [NSView] = []
    private let morseHeader = NSTextField(labelWithString: "MORSE CODE")
    private let morseHeaderContainer = NSStackView()
    private let morseCard = Card()
    private let morseRow = NSView()
    private let morseField = NSTextField()
    private let playButton = SymbolButton(symbol: "play.fill", activeSymbol: "stop.fill")
    private let loopButton = SymbolButton(symbol: "repeat", activeSymbol: "repeat")

    /// What the panel shows now. `nil` until the first update, which always applies.
    private var state: PanelState?

    /// `finish` is the colour of this Mac's case, which the live view copies.
    init(finish: MacFinish = .spaceBlack) {
        preview = LogoPreview(finish: finish)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Shows how brightly the logo is glowing right now, from 0 to 1.
    func showGlow(_ glow: Double) {
        preview.show(glow: glow)
    }

    func update(_ state: PanelState) {
        guard state != self.state else { return }
        let old = self.state
        self.state = state
        preview.isHidden = !state.isSupported
        let animated = window?.isVisible == true

        // The switch shows what was asked for, even while the logo is still fading. It only looks
        // disabled while a password is needed.
        logoSwitch.setOn(state.isOn, animated: animated)
        logoSwitch.isEnabled = state.canSwitch
        logoLabel.textColor = state.isSupported ? .labelColor : .tertiaryLabelColor
        logoTile.isDimmed = !state.isSupported

        brightnessCard.isHidden = !state.showsAdjustments
        effectsHeaderContainer.isHidden = !state.showsAdjustments
        effectsCard.isHidden = !state.showsAdjustments
        morseHeaderContainer.isHidden = !state.showsAdjustments
        morseCard.isHidden = !state.showsAdjustments

        if !brightnessSlider.isTracking { brightnessSlider.value = state.brightness }
        brightnessSlider.isEnabled = state.canChangeBrightness
        batterySwitch.setOn(state.followsBattery, animated: animated)
        batterySwitch.acceptsInput = state.canAdjust
        for row in effectRows {
            row.toggle.setOn(row.effect == state.effect, animated: animated)
            row.toggle.acceptsInput = state.canAdjust
        }
        for view in soundRows { view.isHidden = !state.showsSound }
        morseField.isEnabled = state.canAdjust
        playButton.isActive = state.isSendingMorse
        playButton.toolTip = state.isSendingMorse ? "Stop" : "Play"
        loopButton.isActive = state.morseLoops
        updateMorseButtons()
        greyOut([brightnessRow: !state.canChangeBrightness, batteryRow: !state.canAdjust,
                 effectsCard.rows: !state.canAdjust, morseCard.rows: !state.canAdjust], animated: animated)

        messageLabel.stringValue = state.message ?? ""
        messageContainer.isHidden = state.message == nil
        // Only these change the panel's height.
        if old?.isSupported != state.isSupported || old?.showsAdjustments != state.showsAdjustments
            || old?.showsSound != state.showsSound || old?.message != state.message {
            resizeToFit()
        }
    }

    /// Greys out the brightness, the Battery switch, the effects and Morse code, or brings them back, as one fade
    /// of their rows (the controls in them don't change their own look).
    private func greyOut(_ rows: [NSView: Bool], animated: Bool) {
        let changes = rows.map { (view: $0.key, alpha: $0.value ? Self.greyedOutAlpha : 1) }
            .filter { $0.view.alphaValue != $0.alpha }
        guard !changes.isEmpty else { return }
        guard animated else {
            for change in changes { change.view.alphaValue = change.alpha }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.greyingDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for change in changes { change.view.animator().alphaValue = change.alpha }
        }
    }

    // MARK: - Layout

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.spacing
        stack.edgeInsets = NSEdgeInsets(top: Self.topInset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        // The logo: on/off at the top, where the user wanted it (easier to reach than below the live
        // view), then the live view, then the brightness.
        logoSwitch.target = self
        logoSwitch.action = #selector(logoSwitchChanged)
        logoSwitch.setAccessibilityLabel("Apple logo backlight")
        let logoCard = Card()
        logoCard.add([row(tile: logoTile, label: logoLabel, toggle: logoSwitch)])
        addFullWidth(logoCard)

        addFullWidth(preview)

        dimIcon.image = Self.symbol("sun.min.fill", size: 11)
        brightIcon.image = Self.symbol("sun.max.fill", size: 15)
        for icon in [dimIcon, brightIcon] { icon.contentTintColor = .secondaryLabelColor }
        brightnessSlider.setAccessibilityLabel("Brightness")
        brightnessSlider.onChange = { [weak self] in self?.onBrightnessChanged?($0) }
        layOutBrightnessRow()
        batterySwitch.target = self
        batterySwitch.action = #selector(batterySwitchChanged)
        batterySwitch.setAccessibilityLabel("Brightness follows battery")
        batteryRow = row(tile: batteryTile, label: batteryLabel, toggle: batterySwitch)
        batteryRow.toolTip = "The logo shows the battery's charge: normal brightness when it's full, dimmer as it runs down."
        brightnessCard.add([brightnessRow, Separator(), batteryRow])
        addFullWidth(brightnessCard)

        // Only on a Mac without the logo, where nothing else is shown.
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0 // as many as it needs: the panel resizes to fit
        messageLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.textIndent
        addIndented(messageLabel, in: messageContainer)

        // Effects: one switch each; at most one is on. Sound (the logo follows the sound the Mac
        // plays) is last, and only where the sound can be heard.
        effectsHeader.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .medium)
        effectsHeader.textColor = .secondaryLabelColor
        addIndented(effectsHeader, in: effectsHeaderContainer)

        var rows: [NSView] = []
        for effect in LogoEffect.allCases where effect != .none {
            let tile = IconTile(symbol: Self.symbolName(for: effect), color: Self.color(for: effect))
            let label = NSTextField(labelWithString: effect.title)
            let toggle = LogoSwitch()
            toggle.target = self
            toggle.action = #selector(effectSwitchChanged(_:))
            toggle.setAccessibilityLabel(effect.title)
            effectRows.append((effect, tile, label, toggle))
            if !rows.isEmpty { rows.append(Separator()) }
            let row = row(tile: tile, label: label, toggle: toggle)
            rows.append(row)
            if effect == .sound {
                row.toolTip = "The logo glows with the sound your Mac is playing: brighter as it gets louder, "
                    + "peaking at your brightness. macOS asks once to let LogoLight hear it."
                soundRows = [rows[rows.count - 2], row]
            }
        }
        effectsCard.add(rows)
        addFullWidth(effectsCard)

        // Morse code: type a message and press play, which turns to stop while it's sent. The loop
        // switch, as in a music player, makes it repeat until it's stopped.
        morseHeader.font = effectsHeader.font
        morseHeader.textColor = .secondaryLabelColor
        addIndented(morseHeader, in: morseHeaderContainer)
        layOutMorseRow()
        morseCard.add([morseRow])
        addFullWidth(morseCard)
    }

    /// The message field, then play and loop, in one row as narrow as the effects'.
    private func layOutMorseRow() {
        morseField.placeholderString = "Message"
        morseField.font = .systemFont(ofSize: 12)
        morseField.bezelStyle = .roundedBezel
        morseField.lineBreakMode = .byTruncatingTail
        morseField.usesSingleLineMode = true
        morseField.cell?.isScrollable = true
        morseField.cell?.wraps = false
        morseField.delegate = self
        morseField.target = self
        morseField.action = #selector(morseFieldReturned) // Return plays it
        morseField.setAccessibilityLabel("Morse code message")

        playButton.toolTip = "Play"
        playButton.setAccessibilityLabel("Play Morse code")
        playButton.target = self
        playButton.action = #selector(playPressed)
        loopButton.toolTip = "Repeat until stopped"
        loopButton.setAccessibilityLabel("Repeat Morse code")
        loopButton.activeDescription = "On"
        loopButton.inactiveDescription = "Off"
        loopButton.target = self
        loopButton.action = #selector(loopPressed)
        for view in [morseField, playButton, loopButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            morseRow.addSubview(view)
        }
        NSLayoutConstraint.activate([
            morseRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            morseField.leadingAnchor.constraint(equalTo: morseRow.leadingAnchor, constant: Self.tileInset),
            morseField.centerYAnchor.constraint(equalTo: morseRow.centerYAnchor),
            morseField.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -Self.labelSpacing),
            playButton.centerYAnchor.constraint(equalTo: morseRow.centerYAnchor),
            playButton.trailingAnchor.constraint(equalTo: loopButton.leadingAnchor, constant: -Self.labelSpacing),
            loopButton.centerYAnchor.constraint(equalTo: morseRow.centerYAnchor),
            loopButton.trailingAnchor.constraint(equalTo: morseRow.trailingAnchor, constant: -Self.switchInset),
        ])
        updateMorseButtons()
    }

    /// Puts back the message typed last time.
    func setMorseText(_ text: String) {
        morseField.stringValue = String(text.prefix(MorseCode.maxLength))
        updateMorseButtons()
    }

    /// Play can start a message when there's something to send, and always stop one; the loop
    /// switch can always be flipped.
    private func updateMorseButtons() {
        let canAdjust = state?.canAdjust ?? false
        playButton.isEnabled = canAdjust && (MorseCode.canSend(morseField.stringValue) || playButton.isActive)
        loopButton.isEnabled = canAdjust
        let notation = MorseCode.notation(morseField.stringValue)
        morseField.toolTip = notation.isEmpty ? "Letters, digits and punctuation" : notation
    }

    private func row(tile: IconTile, label: NSTextField, toggle: LogoSwitch) -> NSView {
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        let row = NSView()
        for view in [tile, label, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            tile.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.tileInset),
            tile.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.textColumn),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -Self.labelSpacing),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Self.switchInset),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func layOutBrightnessRow() {
        for view in [dimIcon, brightnessSlider, brightIcon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            brightnessRow.addSubview(view)
        }
        NSLayoutConstraint.activate([
            brightnessRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            // The small sun sits under the icon tiles, and the track starts at the text column.
            dimIcon.centerXAnchor.constraint(equalTo: brightnessRow.leadingAnchor, constant: Self.tileInset + Self.tileSize / 2),
            dimIcon.centerYAnchor.constraint(equalTo: brightnessRow.centerYAnchor),
            brightnessSlider.leadingAnchor.constraint(equalTo: brightnessRow.leadingAnchor,
                                                      constant: Self.textColumn - LogoSlider.knobDiameter / 2),
            brightnessSlider.centerYAnchor.constraint(equalTo: brightnessRow.centerYAnchor),
            brightnessSlider.trailingAnchor.constraint(equalTo: brightIcon.leadingAnchor, constant: -4),
            brightIcon.trailingAnchor.constraint(equalTo: brightnessRow.trailingAnchor, constant: -12),
            brightIcon.centerYAnchor.constraint(equalTo: brightnessRow.centerYAnchor),
        ])
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
    }

    /// Adds text outside the cards, indented in `container` as in iOS Settings.
    private func addIndented(_ text: NSView, in container: NSStackView) {
        container.addArrangedSubview(text)
        container.edgeInsets = NSEdgeInsets(top: 0, left: Self.textIndent, bottom: 0, right: Self.textIndent)
        addFullWidth(container)
    }

    private func resizeToFit() {
        layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: Self.width, height: height)) }
    }

    // MARK: - Actions

    @objc private func logoSwitchChanged() {
        onLogoSwitched?(logoSwitch.isOn)
    }

    @objc private func batterySwitchChanged() {
        onFollowsBatteryChanged?(batterySwitch.isOn)
    }

    @objc private func playPressed() {
        if playButton.isActive {
            onMorseStop?()
        } else {
            onMorsePlay?(morseField.stringValue)
        }
    }

    @objc private func loopPressed() {
        onMorseLoopsChanged?(!loopButton.isActive)
    }

    /// Return plays the message, unless one is being sent (stopping it takes the button).
    @objc private func morseFieldReturned() {
        guard playButton.isEnabled, !playButton.isActive else { return }
        onMorsePlay?(morseField.stringValue)
    }

    @objc private func effectSwitchChanged(_ sender: LogoSwitch) {
        guard let row = effectRows.first(where: { $0.toggle === sender }) else { return }
        let effect: LogoEffect = sender.isOn ? row.effect : .none
        for other in effectRows where other.toggle !== sender { other.toggle.setOn(false, animated: true) }
        onEffectChosen?(effect)
    }

    // MARK: - Styling

    private static func symbolName(for effect: LogoEffect) -> String {
        switch effect {
        case .none: "lightbulb"
        case .breathe: "wind"
        case .pulse: "waveform"
        case .heartbeat: "heart.fill"
        case .sound: "music.note"
        }
    }

    private static func color(for effect: LogoEffect) -> NSColor {
        switch effect {
        case .none: .systemGray
        case .breathe: .systemTeal
        case .pulse: .systemIndigo
        case .heartbeat: .systemPink
        case .sound: .systemPurple
        }
    }

    fileprivate static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }
}

extension ControlPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        if morseField.stringValue.count > MorseCode.maxLength {
            morseField.stringValue = String(morseField.stringValue.prefix(MorseCode.maxLength))
        }
        updateMorseButtons()
        onMorseTextChanged?(morseField.stringValue)
    }
}

/// A round button with an SF Symbol, drawn by the app like `LogoSwitch` (so it has its colours from the
/// menu's first frame). While active it's filled with the accent colour and shows `activeSymbol`.
final class SymbolButton: NSControl {
    static let diameter: CGFloat = 24
    private let symbol: String
    private let activeSymbol: String
    private var isPressed = false { didSet { needsDisplay = true } }

    /// What VoiceOver says while it's active, and while it isn't.
    var activeDescription = "Playing"
    var inactiveDescription: String?

    /// Whether this button's action is under way (pressing it again stops it), or, for a switch,
    /// whether it's on.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    init(symbol: String, activeSymbol: String) {
        self.symbol = symbol
        self.activeSymbol = activeSymbol
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: orientation)
            setContentCompressionResistancePriority(.required, for: orientation)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.diameter, height: Self.diameter) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        let tint: NSColor
        if isActive {
            NSColor.controlAccentColor.withAlphaComponent(isPressed ? 0.75 : 1).setFill()
            tint = .white
        } else {
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.2 : 0.1).setFill()
            tint = .labelColor
        }
        circle.fill()
        guard let image = NSImage(systemSymbolName: isActive ? activeSymbol : symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint])))
        else { return }
        let size = image.size
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, isPressed else { return }
        isPressed = false
        sendAction(action, to: target)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityValue() -> Any? { isActive ? activeDescription : inactiveDescription }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        sendAction(action, to: target)
        return true
    }
}

/// A live view of the logo: the back of the MacBook Pro in its own finish (space black or silver) and
/// in the lid's real proportions, with the logo glowing on it.
private final class LogoPreview: NSView {
    /// The 14-inch MacBook Pro's lid is 31.3 × 22.1 cm.
    private static let lidSize = NSSize(width: 116, height: 82)
    /// A little larger than on the real lid, so the glow reads at this size.
    private static let logoSize = NSSize(width: 26, height: 26)

    private let lid = CAGradientLayer()
    /// The logo as it looks unlit: a faint polished shape in the aluminium.
    private let mark = CALayer()
    /// Its light, faded in by the glow.
    private let logo = CALayer()

    init(finish: MacFinish) {
        super.init(frame: .zero)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: Self.lidSize.height).isActive = true

        // Anodised aluminium: a faint sheen toward the top, and a fine machined edge.
        let (top, bottom, edge, markColor, markOpacity): (NSColor, NSColor, NSColor, NSColor, Float) = switch finish {
        case .spaceBlack:
            (NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1), NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
             NSColor(white: 1, alpha: 0.14), .white, 0.08)
        case .silver:
            (NSColor(srgbRed: 0.86, green: 0.865, blue: 0.87, alpha: 1), NSColor(srgbRed: 0.72, green: 0.725, blue: 0.735, alpha: 1),
             NSColor(white: 0, alpha: 0.16), .black, 0.12)
        }
        lid.colors = [top.cgColor, bottom.cgColor]
        lid.cornerRadius = 7
        lid.cornerCurve = .continuous
        lid.borderWidth = 0.5
        lid.borderColor = edge.cgColor
        layer?.addSublayer(lid)

        let symbol = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)
        func logoImage(_ color: NSColor) -> NSImage? {
            symbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Self.logoSize.height, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
        }
        for layer in [mark, logo] {
            layer.contentsGravity = .resizeAspect
            lid.addSublayer(layer)
        }
        mark.contents = logoImage(markColor)
        mark.opacity = markOpacity
        logo.contents = logoImage(.white)
        logo.shadowColor = NSColor.white.cgColor
        logo.shadowOffset = .zero
        logo.shadowRadius = 7
        show(glow: 0)

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Live view of the Apple logo")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let lidSize = Self.lidSize, logoSize = Self.logoSize
        withoutAnimation {
            lid.frame = NSRect(x: (bounds.width - lidSize.width) / 2, y: 0, width: lidSize.width, height: lidSize.height)
            let logoFrame = NSRect(x: (lidSize.width - logoSize.width) / 2, y: (lidSize.height - logoSize.height) / 2,
                                   width: logoSize.width, height: logoSize.height)
            mark.frame = logoFrame
            logo.frame = logoFrame
        }
    }

    /// The glow last drawn.
    private var shownGlow: Double?

    /// Called on every frame while the menu is open. A change too small to see isn't drawn, so a
    /// steady logo costs nothing.
    func show(glow: Double) {
        if let shownGlow, abs(glow - shownGlow) < 0.002 { return }
        shownGlow = glow
        withoutAnimation {
            logo.opacity = Float(glow)
            logo.shadowOpacity = Float(glow)
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}

/// A rounded, slightly raised group of rows, like a section in iOS Settings.
private final class Card: NSView {
    /// The rows, without the card's background (e.g. to fade them).
    let rows = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func add(_ views: [NSView]) {
        views.forEach(rows.addArrangedSubview)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor(white: 1, alpha: isDark ? 0.08 : 0.75).cgColor
    }
}

/// A hairline between rows that starts under the row's text, as in iOS Settings.
private final class Separator: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let thickness = 1 / (window?.backingScaleFactor ?? 2)
        let start = ControlPanel.textColumn
        NSRect(x: start, y: 0, width: max(0, bounds.width - start), height: thickness).fill()
    }
}

/// A white symbol on a coloured rounded square, like the icons in iOS Settings.
private final class IconTile: NSView {
    private let color: NSColor
    var isDimmed = false { didSet { alphaValue = isDimmed ? 0.35 : 1 } }

    init(symbol: String, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        let image = NSImageView(image: ControlPanel.symbol(symbol, size: 12) ?? NSImage())
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ControlPanel.tileSize),
            heightAnchor.constraint(equalToConstant: ControlPanel.tileSize),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }
}

/// An iOS-style slider: a thin rounded track, filled up to a round white knob.
final class LogoSlider: NSView {
    /// 0…1.
    var value = 1.0 { didSet { needsDisplay = true } }
    /// Whether it takes input. It looks the same either way: the panel greys out its whole row.
    var isEnabled = true
    var onChange: ((Double) -> Void)?
    private(set) var isTracking = false

    static let knobDiameter: CGFloat = 22
    private let trackHeight: CGFloat = 4

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Self.knobDiameter / 2
        let track = NSRect(x: radius, y: bounds.midY - trackHeight / 2,
                           width: max(0, bounds.width - Self.knobDiameter), height: trackHeight)
        let knobX = track.minX + CGFloat(value) * track.width

        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        var filled = track
        filled.size.width = knobX - track.minX
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        let knob = NSRect(x: knobX - radius, y: bounds.midY - radius, width: Self.knobDiameter, height: Self.knobDiameter)
            .insetBy(dx: 1, dy: 1)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.06).setStroke()
        NSBezierPath(ovalIn: knob.insetBy(dx: 0.25, dy: 0.25)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isTracking = true
        track(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isTracking else { return }
        track(event)
    }

    override func mouseUp(with event: NSEvent) {
        isTracking = false
    }

    private func track(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let usable = max(1, bounds.width - Self.knobDiameter)
        setValueFromUser(Double((x - Self.knobDiameter / 2) / usable))
    }

    private func setValueFromUser(_ newValue: Double) {
        let clamped = min(max(newValue, 0), 1)
        guard clamped != value else { return }
        value = clamped
        onChange?(clamped)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformIncrement() -> Bool { step(by: 0.1) }
    override func accessibilityPerformDecrement() -> Bool { step(by: -0.1) }

    private func step(by delta: Double) -> Bool {
        guard isEnabled else { return false }
        setValueFromUser(value + delta)
        return true
    }
}

#if DEBUG
/// Draws the panel in each state to a PNG, for checking how it looks.
///
/// Optional settings, for pictures of the app (e.g. the website's). Without them the output is as before:
/// - `LOGOLIGHT_RENDER_SCALE`: pixels per point, 2 by default, up to 16 (e.g. 4 for a larger, crisp picture,
///   or 14 for a live view about 800 points wide on a Retina screen). With a scale given, layer images and
///   shadows are drawn as a screen at that scale draws them: the logo sharp, and its glow as wide as in the
///   menu. (Without one, the logo is drawn at the screen's scale and its glow in pixels, as before.)
/// - `LOGOLIGHT_RENDER_TRANSPARENT`: leaves the background clear instead of a menu-like grey, so the
///   picture can be placed on any backdrop (the cards are translucent, as in the real menu).
/// - `LOGOLIGHT_RENDER_GLOW`, `LOGOLIGHT_RENDER_BRIGHTNESS`, `LOGOLIGHT_RENDER_EFFECT`: the live view's
///   glow (0.75), the slider (0.6, also the charge in `battery-*.png`) and the effect that's on
///   (`heartbeat`) in the panels.
/// - `LOGOLIGHT_RENDER_GLOWS`: glow levels, e.g. `0,0.5,1`, to also draw the live view alone at each
///   level, in both finishes (`live-black-50.png`, `live-silver-50.png`). It also prints where the lid is
///   in each panel, to place those pictures over it.
/// - `LOGOLIGHT_RENDER_LIGHT`: also draws the logo's light alone, fully lit, lid-sized on clear: with its glow
///   (`live-light.png`) and without it (`live-light-shape.png`). Over `live-black-0.png`, the first at opacity g
///   with the second on top, both in a group at opacity g, give the live view at glow g, as `show(glow:)` draws
///   it (the glow's own opacity is g as well, so it shows at g²). The light is the same in both finishes.
/// - `LOGOLIGHT_RENDER_ICON`: also draws the menu bar icon while the logo is on (`icon-on.png`, black
///   on clear, as the template the menu bar tints).
@MainActor
enum PanelRenderer {
    private struct Options {
        var scale = 2
        /// Without a scale given, the window draws at the screen's, as it always has.
        var scaleIsSet = false
        var transparent = false
        var glow = 0.75
        var brightness = 0.6
        var effect = LogoEffect.heartbeat
        var glows: [Double] = []
        var light = false
        var icon = false

        init(_ environment: [String: String]) {
            if let scale = environment["LOGOLIGHT_RENDER_SCALE"].flatMap(Int.init), (1...16).contains(scale) {
                self.scale = scale
                scaleIsSet = true
            }
            transparent = environment["LOGOLIGHT_RENDER_TRANSPARENT"] != nil
            if let glow = environment["LOGOLIGHT_RENDER_GLOW"].flatMap(Double.init) { self.glow = min(max(glow, 0), 1) }
            if let brightness = environment["LOGOLIGHT_RENDER_BRIGHTNESS"].flatMap(Double.init) {
                self.brightness = min(max(brightness, 0), 1)
            }
            if let effect = environment["LOGOLIGHT_RENDER_EFFECT"].flatMap(LogoEffect.init(rawValue:)) { self.effect = effect }
            glows = (environment["LOGOLIGHT_RENDER_GLOWS"] ?? "").split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { min(max($0, 0), 1) }
            light = environment["LOGOLIGHT_RENDER_LIGHT"] != nil
            icon = environment["LOGOLIGHT_RENDER_ICON"] != nil
        }
    }

    /// Drawing assumes top-down layers, as in the panel.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A window that draws its views at any scale, not just the screen's, so text and symbols stay sharp.
    private final class RenderWindow: NSWindow {
        var scale: CGFloat?
        override var backingScaleFactor: CGFloat { scale ?? super.backingScaleFactor }
    }

    static func render(to folder: String) {
        let options = Options(ProcessInfo.processInfo.environment)
        func state(_ setting: LogoIllumination, isSupported: Bool = true, canControlDirectly: Bool = true,
                   canFollowSound: Bool = true, followsBattery: Bool = false) -> PanelState {
            let status = LogoStatus(isSupported: isSupported, setting: isSupported ? setting : nil, source: .daemon,
                                    isLit: setting == .on, outputLevel: 0.2)
            return PanelState(status: status, canControlDirectly: canControlDirectly, canFollowSound: canFollowSound,
                              effect: options.effect, brightness: options.brightness, followsBattery: followsBattery)
        }
        let on = state(.on)
        var looping = on
        looping.morse = MorseMessage(text: "SOS", loops: true)
        looping.morseLoops = true
        let states = [("on", on), ("morse", looping), ("off", state(.off)), ("battery", state(.on, followsBattery: true)),
                      ("nosound", state(.on, canFollowSound: false)),
                      ("fallback", state(.on, canControlDirectly: false)), ("unsupported", state(.off, isSupported: false))]
        for (name, state) in states {
            for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                write(state, appearance: appearance, options: options, to: "\(folder)/\(name)-\(suffix).png")
            }
        }
        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            write(on, finish: .silver, appearance: appearance, options: options, to: "\(folder)/on-silver-\(suffix).png")
        }
        for glow in options.glows {
            for (name, finish) in [("black", MacFinish.spaceBlack), ("silver", .silver)] {
                let preview = LogoPreview(finish: finish)
                preview.frame = NSRect(origin: .zero, size: LogoPreview.renderedLidSize)
                preview.show(glow: glow)
                draw(preview, options: options, background: nil,
                     to: "\(folder)/live-\(name)-\(Int((glow * 100).rounded())).png")
            }
        }
        if options.light {
            for (name, withGlow) in [("live-light", true), ("live-light-shape", false)] {
                let preview = LogoPreview(finish: .spaceBlack)
                preview.frame = NSRect(origin: .zero, size: LogoPreview.renderedLidSize)
                preview.showLightAlone(withGlow: withGlow)
                draw(preview, options: options, background: nil, to: "\(folder)/\(name).png")
            }
        }
        if options.icon, let symbol = NSImage(systemSymbolName: on.symbolName, accessibilityDescription: nil) {
            // The status item's button draws its template image at its own size, in the menu bar's text colour.
            let icon = NSImageView(image: symbol)
            icon.contentTintColor = .black
            icon.frame = NSRect(origin: .zero, size: symbol.size)
            let container = FlippedView(frame: icon.frame)
            container.addSubview(icon)
            draw(container, options: options, background: nil, to: "\(folder)/icon-on.png")
        }
    }

    private static func write(_ state: PanelState, finish: MacFinish = .spaceBlack, appearance: NSAppearance.Name,
                              options: Options, to path: String) {
        let panel = ControlPanel(finish: finish)
        panel.setMorseText("SOS")
        panel.update(state)
        panel.showGlow(state.isOn ? options.glow : 0)
        let background = appearance == .darkAqua ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.9, alpha: 1)
        draw(panel, appearance: appearance, options: options, background: options.transparent ? nil : background,
             to: path)
    }

    /// Draws `view` into a PNG at the options' scale, on `background`, or on clear without one.
    private static func draw(_ view: NSView, appearance: NSAppearance.Name = .darkAqua, options: Options,
                             background: NSColor?, to path: String) {
        let window = RenderWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        if options.scaleIsSet { window.scale = CGFloat(options.scale) }
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = background ?? .clear
        window.isOpaque = background != nil
        window.contentView = view
        window.setContentSize(view.frame.size)
        window.displayIfNeeded()
        if let panel = view as? ControlPanel {
            reportTruncatedLabels(in: panel, path: path)
            if !options.glows.isEmpty { reportLid(in: panel, path: path) }
        }

        guard let layer = view.layer ?? window.contentView?.layer else { return }
        let scale = options.scale
        if options.scaleIsSet { drawAsScreen(layer, scale: CGFloat(scale)) }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                         pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return }
        let cg = context.cgContext
        if let background {
            cg.setFillColor(background.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        } else {
            cg.clear(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        }
        // The view's layers are top-down, the bitmap's context bottom-up.
        cg.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
        cg.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        layer.render(in: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// `render(in:)` draws an image set as a layer's contents (the live view's logo) as it would for the screen, and
    /// shadows in the bitmap's pixels whatever its scale. A screen at `scale` draws images at that scale and shadows
    /// in points, so this sets each layer up to match.
    private static func drawAsScreen(_ layer: CALayer, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        func prepare(_ layer: CALayer) {
            layer.contentsScale = scale
            if let image = layer.contents as? NSImage {
                // Made into a bitmap at this scale; left as it is, it would be one made for the screen.
                layer.contents = image.layerContents(forContentsScale: scale)
            }
            layer.shadowRadius *= scale
            layer.shadowOffset = CGSize(width: layer.shadowOffset.width * scale, height: layer.shadowOffset.height * scale)
            layer.sublayers?.forEach(prepare)
        }
        prepare(layer)
        CATransaction.commit()
    }

    /// Prints the live view's lid frame in the panel, in points, and the panel's size.
    private static func reportLid(in panel: ControlPanel, path: String) {
        func previews(in view: NSView) -> [LogoPreview] {
            view.subviews.flatMap { ($0 as? LogoPreview).map { [$0] } ?? previews(in: $0) }
        }
        guard let preview = previews(in: panel).first, !preview.isHiddenOrHasHiddenAncestor else { return }
        let lid = panel.convert(preview.renderedLidFrame, from: preview)
        print("\(path): lid at x \(lid.minX), y \(lid.minY), \(lid.width) × \(lid.height) in a panel "
              + "\(panel.bounds.width) × \(panel.bounds.height) pt")
    }

    /// Says which visible one-line labels are narrower than their text, so a narrower panel can be checked.
    private static func reportTruncatedLabels(in view: NSView, path: String) {
        for subview in view.subviews where !subview.isHiddenOrHasHiddenAncestor {
            // Both widths are without the label's own padding (its alignment rect).
            if let label = subview as? NSTextField, label.cell?.wraps == false {
                let width = label.alignmentRect(forFrame: label.frame).width
                if width < label.intrinsicContentSize.width - 0.5 {
                    print("\(path): \"\(label.stringValue)\" is truncated (\(width) of \(label.intrinsicContentSize.width) pt)")
                }
            } else if let label = subview as? NSTextField {
                // A wrapping label cut to fewer lines than it needs drops its last words silently.
                let rect = label.alignmentRect(forFrame: label.frame)
                let needed = label.attributedStringValue.boundingRect(
                    with: NSSize(width: rect.width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height.rounded(.up)
                if rect.height < needed - 0.5 {
                    print("\(path): \"\(label.stringValue)\" is cut (\(rect.height) of \(needed) pt high)")
                }
            }
            reportTruncatedLabels(in: subview, path: path)
        }
    }
}

private extension LogoPreview {
    /// The live view's size without the panel around it: just the lid.
    static var renderedLidSize: NSSize { lidSize }

    /// Where the lid is drawn in the view (centred at the top, as `layout()` places it).
    var renderedLidFrame: NSRect {
        NSRect(x: (bounds.width - Self.lidSize.width) / 2, y: 0, width: Self.lidSize.width, height: Self.lidSize.height)
    }

    /// Leaves only the logo's light, fully lit, with or without its glow: no lid and no unlit mark.
    func showLightAlone(withGlow: Bool) {
        lid.colors = nil
        lid.borderWidth = 0
        mark.isHidden = true
        logo.opacity = 1
        logo.shadowOpacity = withGlow ? 1 : 0
    }
}
#endif
