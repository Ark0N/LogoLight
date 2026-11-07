import AppKit

/// An iOS-style switch, drawn with its own layers.
///
/// It replaces `NSSwitch`, which inside a menu draws its "on" colour only once AppKit has made the
/// menu's window key, a moment after the menu appears, and is grey until then. This one uses the accent
/// colour from the first frame, like `LogoSlider`, and animates only when it's flipped.
final class LogoSwitch: NSControl {
    /// The size of a regular `NSSwitch` on macOS 27, measured from one drawn offscreen: a 54 × 24 track
    /// with a 32 × 20 capsule for a knob, 2 points in from the edges.
    static let size = NSSize(width: 54, height: 24)
    private static let knobSize = NSSize(width: 32, height: 20)
    private static let knobInset: CGFloat = 2
    /// How far the pointer moves before a press becomes a drag of the knob.
    private static let dragThreshold: CGFloat = 3

    /// Whether the switch is on. A click or a drag flips it (animated) before the action is sent.
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
    /// Where a press started, while the mouse button is down.
    private var pressX: CGFloat?
    private var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Always its full size: a row that's too narrow truncates the label instead.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: orientation)
            setContentCompressionResistancePriority(.required, for: orientation)
        }
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
        isOn = on
        NSAccessibility.post(element: self, notification: .valueChanged)
        settle(animated: animated)
    }

    /// Moves the knob and the colour to match `isOn`, springing from wherever they are now.
    private func settle(animated: Bool) {
        let fromX = (knob.presentation() ?? knob).position.x
        let fromOpacity = (fill.presentation() ?? fill).opacity
        withoutAnimation {
            knob.position = knobCenter
            fill.opacity = isOn ? 1 : 0
        }
        guard animated, window != nil else {
            knob.removeAllAnimations()
            fill.removeAllAnimations()
            return
        }
        let slide = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.15)
        slide.keyPath = "position.x"
        slide.fromValue = fromX
        slide.toValue = knob.position.x
        slide.duration = slide.settlingDuration
        knob.add(slide, forKey: "slide")

        let tint = CABasicAnimation(keyPath: "opacity")
        tint.fromValue = fromOpacity
        tint.toValue = fill.opacity
        tint.duration = 0.3
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
            knob.bounds = CGRect(origin: .zero, size: Self.knobSize)
            for layer in [track, fill] { layer.cornerRadius = bounds.height / 2 }
            knob.cornerRadius = Self.knobSize.height / 2
            knob.position = knobCenter
            fill.opacity = isOn ? 1 : 0
        }
    }

    /// The knob's centre when it's off and when it's on.
    private var knobRange: ClosedRange<CGFloat> {
        let offX = Self.knobInset + Self.knobSize.width / 2
        return offX...max(offX, bounds.width - offX)
    }

    private var knobCenter: CGPoint {
        CGPoint(x: isOn ? knobRange.upperBound : knobRange.lowerBound, y: bounds.midY)
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    // MARK: - Events

    // Not calling super in these keeps the click from going up to the menu.

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, acceptsInput else { return }
        pressX = convert(event.locationInWindow, from: nil).x
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressX else { return }
        let offset = convert(event.locationInWindow, from: nil).x - pressX
        if !isDragging, abs(offset) < Self.dragThreshold { return }
        isDragging = true
        // The knob follows the pointer along the track.
        let range = knobRange
        let start = isOn ? range.upperBound : range.lowerBound
        withoutAnimation {
            knob.removeAllAnimations()
            knob.position.x = min(max(start + offset, range.lowerBound), range.upperBound)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressX != nil else { return }
        pressX = nil
        if isDragging {
            // A drag ends on the side the knob is nearer.
            isDragging = false
            let on = knob.position.x > (knobRange.lowerBound + knobRange.upperBound) / 2
            if on == isOn || !flipByUser() { settle(animated: true) }
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            flipByUser()
        }
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
