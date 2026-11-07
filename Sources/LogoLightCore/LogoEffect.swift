import Foundation

/// An animation for the logo, built from the LED's own hardware fades.
public enum LogoEffect: String, CaseIterable, Sendable {
    case none
    case breathe
    case pulse
    case heartbeat

    public var title: String {
        switch self {
        case .none: "None"
        case .breathe: "Breathe"
        case .pulse: "Pulse"
        case .heartbeat: "Heartbeat"
        }
    }

    /// One cycle of the effect, repeated while it plays.
    public var cycle: [FadeStep] {
        switch self {
        case .none:
            []
        case .breathe:
            // Slow and soft, like the old MacBook sleep light.
            [FadeStep(lit: false, fade: 2.2, hold: 0.3), FadeStep(lit: true, fade: 2.2, hold: 1.2)]
        case .pulse:
            [FadeStep(lit: false, fade: 0.7, hold: 0.05), FadeStep(lit: true, fade: 0.7, hold: 0.35)]
        case .heartbeat:
            // Two quick beats from dark, then a rest.
            [FadeStep(lit: true, fade: 0.12, hold: 0.05), FadeStep(lit: false, fade: 0.18, hold: 0.08),
             FadeStep(lit: true, fade: 0.12, hold: 0.05), FadeStep(lit: false, fade: 0.6, hold: 0.9)]
        }
    }

    /// The cycle, turned to start with its first step toward lit (`true`) or toward dark.
    public func cycle(startingLit lit: Bool) -> [FadeStep] {
        let steps = cycle
        let start = steps.firstIndex { $0.lit == lit } ?? 0
        return Array(steps[start...] + steps[..<start])
    }
}

/// Fade to dark or lit over `fade` seconds, then wait `hold` seconds.
public struct FadeStep: Equatable, Sendable {
    public var lit: Bool
    public var fade: Double
    public var hold: Double

    public init(lit: Bool, fade: Double, hold: Double) {
        self.lit = lit
        self.fade = fade
        self.hold = hold
    }
}

/// Animates the logo: plays the chosen effect, or holds it at the chosen brightness.
@MainActor
public final class LogoAnimator {
    public typealias Sleep = @Sendable (Double) async throws -> Void

    private let emitter: LightEmitter
    private let isDisplayAwake: @MainActor () -> Bool
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var isAdjusting = false {
        didSet { updateActivity() }
    }
    /// Held while animating (see `updateActivity()`).
    private var activity: NSObjectProtocol?

    /// The chosen effect. It keeps its value while paused (e.g. the logo is off or the display sleeps).
    public private(set) var effect: LogoEffect = .none
    /// Whether an effect is playing.
    public private(set) var isPlaying = false {
        didSet { updateActivity() }
    }
    /// Whether an effect is playing or the logo is fading to the chosen brightness.
    public var isAnimating: Bool { isPlaying || isAdjusting }

    /// How bright the logo glows (with no effect) or peaks (with one), from 0 (dimmest) to 1.
    public var brightness: Double = 1 {
        didSet { brightness = min(max(brightness, 0), 1) }
    }

    /// How long a change of brightness takes to fade, e.g. while the slider moves.
    public var brightnessFadeDuration = 0.25
    /// How long the logo takes to settle at the chosen brightness after an effect stops, a wake or
    /// a launch. Slower than the slider, so coming back from dark doesn't snap on.
    public var transitionDuration = 0.8

    public init(emitter: LightEmitter, isDisplayAwake: @escaping @MainActor () -> Bool, sleep: @escaping Sleep) {
        self.emitter = emitter
        self.isDisplayAwake = isDisplayAwake
        self.sleep = sleep
    }

    /// The logo's fade level for a brightness: never quite dark, and perceptually even
    /// (the eye is more sensitive to changes when the logo is dim).
    public static func level(forBrightness brightness: Double) -> Double {
        let b = min(max(brightness, 0), 1)
        return b >= 1 ? 1 : 0.02 + 0.98 * b * b
    }

    /// The fade level for the current brightness.
    public var level: Double { Self.level(forBrightness: brightness) }

    /// Chooses an effect without starting it.
    public func select(_ effect: LogoEffect) {
        self.effect = effect
    }

    /// Starts (or restarts) the chosen effect, or with no effect, fades to the chosen brightness.
    /// An effect starts with the step that leads away from where the logo is: a rise when it's
    /// dark (e.g. just turned on), a fall when it's lit (e.g. relit by a wake).
    public func resume() {
        cancel()
        if effect == .none {
            adjustBrightness(over: transitionDuration)
        } else {
            let isDark = (emitter.fadeLevel ?? 1) < level / 2
            play(effect.cycle(startingLit: isDark))
        }
    }

    /// Applies a new brightness. A playing effect picks it up at its next step.
    public func brightnessDidChange() {
        guard !isPlaying else { return }
        // A fade already under way follows up with the newest value when it's done, so
        // dragging a slider doesn't restart the fade at every step.
        if !isAdjusting { adjustBrightness(over: brightnessFadeDuration) }
    }

    /// Stops animating, leaving the logo as it is, e.g. because it's being turned off or the
    /// display went to sleep.
    public func pause() {
        cancel()
    }

    /// Stops animating and hands the logo back to the system, fully lit, e.g. before quitting.
    /// The chosen effect and brightness are kept.
    public func reset() {
        cancel()
        emitter.restore(displayAwake: isDisplayAwake())
    }

    private func play(_ cycle: [FadeStep]) {
        isPlaying = true
        task = Task { [weak self] in
            playing: while true {
                for step in cycle {
                    guard let self, !Task.isCancelled else { return }
                    // The display can go away without a sleep notification, e.g. when the lid is
                    // closed with an external display attached. Stop until the next wake.
                    guard self.isDisplayAwake() else { break playing }
                    do {
                        try await self.emitter.fade(to: step.lit ? self.level : 0, over: step.fade, sleep: self.sleep)
                        try await self.sleep(step.hold)
                    } catch {
                        break playing
                    }
                }
            }
            self?.taskDidEnd()
        }
    }

    /// Fades to the chosen brightness over `duration`, then follows any changes made meanwhile
    /// at the slider's speed.
    private func adjustBrightness(over duration: Double) {
        isAdjusting = true
        task = Task { [weak self] in
            var applied: Double?
            var duration = duration
            while let self, !Task.isCancelled, applied != self.level {
                let target = self.level
                do {
                    try await self.emitter.fade(to: target, over: duration, sleep: self.sleep)
                } catch {
                    break
                }
                applied = target
                duration = self.brightnessFadeDuration
            }
            self?.taskDidEnd()
        }
    }

    /// Holds off App Nap while animating: its timer coalescing would make fades stop late and
    /// effects lose their rhythm. The Mac can still sleep.
    private func updateActivity() {
        if isAnimating, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Animating the Apple logo")
        } else if !isAnimating, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// Clears up after a task that stopped by itself. A running task is only ever replaced or
    /// stopped through `cancel()`, which has already done this, so a cancelled one leaves it.
    private func taskDidEnd() {
        guard !Task.isCancelled else { return }
        task = nil
        isPlaying = false
        isAdjusting = false
    }

    private func cancel() {
        task?.cancel()
        task = nil
        isPlaying = false
        isAdjusting = false
    }
}
