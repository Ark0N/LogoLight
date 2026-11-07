import AppKit
import LogoLightCore

/// What the control panel shows.
struct PanelState {
    var isSupported = false
    /// The logo setting is on (or unknown, which is treated as on).
    var isOn = true
    /// A change is under way (e.g. waiting for the password dialog).
    var isBusy = false
    /// Brightness and effects are available (they need direct control).
    var canAnimate = false
    var effect = LogoEffect.none
    var brightness = 1.0
    var footer = ""
}

/// The iOS Settings-style panel at the top of the menu: a live view of the logo, a switch for it
/// and a brightness slider, then a switch for each effect. Everything below the logo switch is
/// greyed out while the logo is off.
@MainActor
final class ControlPanel: NSView {
    var onLogoSwitched: ((Bool) -> Void)?
    var onBrightnessChanged: ((Double) -> Void)?
    var onEffectChosen: ((LogoEffect) -> Void)?

    /// Narrow: the least that fits the longest label ("Heartbeat", 61 pt at 13 pt) between its tile and a
    /// full-size switch is 179. The menu's own items need only 143.
    private static let width: CGFloat = 180
    private static let inset: CGFloat = 6
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

    private let stack = NSStackView()
    private let preview: LogoPreview
    private let logoTile = IconTile(symbol: "lightbulb.fill", color: .systemOrange)
    private let logoLabel = NSTextField(labelWithString: "Backlight")
    private let logoSwitch = LogoSwitch()
    private let brightnessSeparator = Separator()
    private let brightnessRow = NSView()
    private let dimIcon = NSImageView()
    private let brightIcon = NSImageView()
    private let brightnessSlider = LogoSlider()
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private let effectsHeader = NSTextField(labelWithString: "EFFECTS")
    private var footerContainer = NSView()
    private var effectsHeaderContainer = NSView()
    private let effectsCard = Card()
    private var effectRows: [(effect: LogoEffect, tile: IconTile, label: NSTextField, toggle: LogoSwitch)] = []

    private var state = PanelState()

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
        self.state = state
        preview.isHidden = !state.isSupported
        let isOn = state.isSupported && state.isOn
        let canAdjust = isOn && state.canAnimate && !state.isBusy

        let animated = window?.isVisible == true

        // While busy, the switch keeps showing what was just asked for. It only looks disabled while
        // a password is needed; a direct change just ignores clicks until it's done.
        if !state.isBusy { logoSwitch.setOn(isOn, animated: animated) }
        logoSwitch.isEnabled = state.isSupported && !(state.isBusy && !state.canAnimate)
        logoSwitch.acceptsInput = !state.isBusy
        logoLabel.textColor = state.isSupported ? .labelColor : .tertiaryLabelColor
        logoTile.isDimmed = !state.isSupported

        let showsAnimation = state.isSupported && state.canAnimate
        brightnessRow.isHidden = !showsAnimation
        brightnessSeparator.isHidden = !showsAnimation
        effectsHeaderContainer.isHidden = !showsAnimation
        effectsCard.isHidden = !showsAnimation

        if !brightnessSlider.isTracking { brightnessSlider.value = state.brightness }
        brightnessSlider.isEnabled = canAdjust
        for icon in [dimIcon, brightIcon] {
            icon.contentTintColor = canAdjust ? .secondaryLabelColor : .quaternaryLabelColor
        }

        for row in effectRows {
            row.toggle.setOn(row.effect == state.effect, animated: animated)
            row.toggle.isEnabled = canAdjust
            row.label.textColor = canAdjust ? .labelColor : .tertiaryLabelColor
            row.tile.isDimmed = !canAdjust
        }

        footerLabel.stringValue = state.footer
        footerContainer.isHidden = state.footer.isEmpty
        resizeToFit()
    }

    // MARK: - Layout

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: Self.inset, bottom: 6, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        addFullWidth(preview)

        // The logo: on/off and brightness.
        logoSwitch.target = self
        logoSwitch.action = #selector(logoSwitchChanged)
        logoSwitch.setAccessibilityLabel("Apple logo backlight")

        dimIcon.image = Self.symbol("sun.min.fill", size: 11)
        brightIcon.image = Self.symbol("sun.max.fill", size: 15)
        brightnessSlider.setAccessibilityLabel("Brightness")
        brightnessSlider.onChange = { [weak self] in self?.onBrightnessChanged?($0) }
        layOutBrightnessRow()

        let logoCard = Card()
        logoCard.add([row(tile: logoTile, label: logoLabel, toggle: logoSwitch), brightnessSeparator, brightnessRow])
        addFullWidth(logoCard)

        footerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.maximumNumberOfLines = 2
        footerLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.inset - 24
        footerContainer = addIndented(footerLabel)

        // Effects: one switch each; at most one is on.
        effectsHeader.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .medium)
        effectsHeader.textColor = .secondaryLabelColor
        effectsHeaderContainer = addIndented(effectsHeader)
        stack.setCustomSpacing(10, after: footerContainer)

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
            rows.append(row(tile: tile, label: label, toggle: toggle))
        }
        effectsCard.add(rows)
        addFullWidth(effectsCard)
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
        view.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.inset).isActive = true
    }

    /// Adds text outside the cards, lined up with the text inside them as in iOS Settings.
    /// Returns its container, which is what to hide.
    private func addIndented(_ view: NSView) -> NSView {
        let container = NSStackView(views: [view])
        container.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.inset).isActive = true
        return container
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
        }
    }

    private static func color(for effect: LogoEffect) -> NSColor {
        switch effect {
        case .none: .systemGray
        case .breathe: .systemTeal
        case .pulse: .systemIndigo
        case .heartbeat: .systemPink
        }
    }

    fileprivate static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
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

    func show(glow: Double) {
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
    private let rows = NSStackView()

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
    var isEnabled = true { didSet { needsDisplay = true } }
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
        (isEnabled ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(roundedRect: filled, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        let knob = NSRect(x: knobX - radius, y: bounds.midY - radius, width: Self.knobDiameter, height: Self.knobDiameter)
            .insetBy(dx: 1, dy: 1)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isEnabled ? 0.3 : 0.12)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        (isEnabled ? NSColor.white : NSColor(white: 0.92, alpha: 1)).setFill()
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
@MainActor
enum PanelRenderer {
    static func render(to folder: String) {
        let on = PanelState(isSupported: true, isOn: true, canAnimate: true, effect: .heartbeat, brightness: 0.6)
        var off = on
        off.isOn = false
        var fallback = on
        fallback.canAnimate = false
        var unsupported = PanelState()
        unsupported.footer = "Needs a MacBook Pro with PROLED XDR Display"

        let states = [("on", on), ("off", off), ("fallback", fallback), ("unsupported", unsupported)]
        for (name, state) in states {
            for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                write(state, appearance: appearance, to: "\(folder)/\(name)-\(suffix).png")
            }
        }
        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            write(on, finish: .silver, appearance: appearance, to: "\(folder)/on-silver-\(suffix).png")
        }
    }

    private static func write(_ state: PanelState, finish: MacFinish = .spaceBlack, appearance: NSAppearance.Name,
                              to path: String) {
        let panel = ControlPanel(finish: finish)
        panel.update(state)
        panel.showGlow(state.isOn ? 0.75 : 0)
        let window = NSWindow(contentRect: panel.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.9, alpha: 1)
        window.isOpaque = true
        window.contentView = panel
        panel.update(state)
        window.setContentSize(panel.frame.size)
        window.displayIfNeeded()
        reportTruncatedLabels(in: panel, path: path)

        guard let layer = panel.layer ?? window.contentView?.layer else { return }
        let scale = 2
        let size = panel.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                         pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return }
        let cg = context.cgContext
        cg.setFillColor(window.backgroundColor.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        // The panel's layers are top-down, the bitmap's context bottom-up.
        cg.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
        cg.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        layer.render(in: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
            }
            reportTruncatedLabels(in: subview, path: path)
        }
    }
}
#endif
