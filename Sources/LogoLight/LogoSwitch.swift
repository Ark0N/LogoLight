import AppKit

/// An iOS-style switch, drawn with its own layers.
///
/// It replaces `NSSwitch`, which inside a menu draws its "on" colour only once AppKit has made the
/// menu's window key, a moment after the menu appears, and is grey until then. This one uses the accent
/// colour from the first frame, like `LogoSlider`, and animates only when it's flipped.
final class LogoSwitch: NSControl {
    static let size = NSSize(width: 40, height: 24)
    private static let knobInset: CGFloat = 2

    /// Whether the switch is on. A click flips it (animated) before the action is sent.
    private(set) var isOn = false

    /// When false, clicks are ignored without the switch looking disabled, e.g. while the change it
    /// asked for is still being applied.
    var acceptsInput = true

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.5 }
    }

    private let track = CALayer()
    private let fill = CALayer()
    private let knob = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.addSublayer(fill)
        track.addSublayer(knob)
        layer?.addSublayer(track)
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: -1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { Self.size }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Turns the switch on or off without sending its action.
    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        let fromX = (knob.presentation() ?? knob).position.x
        let fromOpacity = (fill.presentation() ?? fill).opacity
        isOn = on
        withoutAnimation {
            knob.position = knobCenter
            fill.opacity = on ? 1 : 0
        }
        NSAccessibility.post(element: self, notification: .valueChanged)
        guard animated, window != nil else {
            knob.removeAllAnimations()
            fill.removeAllAnimations()
            return
        }
        let slide = CASpringAnimation(perceptualDuration: 0.35, bounce: 0.15)
        slide.keyPath = "position.x"
        slide.fromValue = fromX
        slide.toValue = knob.position.x
        slide.duration = slide.settlingDuration
        knob.add(slide, forKey: "slide")

        let tint = CABasicAnimation(keyPath: "opacity")
        tint.fromValue = fromOpacity
        tint.toValue = fill.opacity
        tint.duration = 0.2
        tint.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.add(tint, forKey: "tint")
    }

    // MARK: - Drawing

    override func updateLayer() {
        // Colours follow the appearance and the accent colour, and never animate.
        withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
                fill.backgroundColor = NSColor.controlAccentColor.cgColor
                knob.backgroundColor = NSColor.white.cgColor
                knob.shadowColor = NSColor.black.cgColor
            }
        }
    }

    override func layout() {
        super.layout()
        withoutAnimation {
            track.frame = bounds
            fill.frame = track.bounds
            let diameter = bounds.height - 2 * Self.knobInset
            knob.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            for layer in [track, fill] { layer.cornerRadius = bounds.height / 2 }
            knob.cornerRadius = diameter / 2
            knob.position = knobCenter
            fill.opacity = isOn ? 1 : 0
        }
    }

    private var knobCenter: CGPoint {
        let radius = bounds.height / 2
        return CGPoint(x: isOn ? bounds.width - radius : radius, y: bounds.midY)
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        // Handled on mouse-up. Not calling super keeps the click from going up to the menu.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flipByUser()
    }

    @discardableResult
    private func flipByUser() -> Bool {
        guard isEnabled, acceptsInput else { return false }
        setOn(!isOn, animated: true)
        sendAction(action, to: target)
        return true
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    override func accessibilityValue() -> Any? { NSNumber(value: isOn ? 1 : 0) }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool { flipByUser() }
}
