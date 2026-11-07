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
    private var isAdjusting = false
    /// Counts cancellations, so a cancelled task can tell it's been superseded.
    private var generation = 0

    /// The chosen effect. It keeps its value while paused (e.g. the logo is off or the display sleeps).
    public private(set) var effect: LogoEffect = .none
    /// Whether an effect is playing.
    public private(set) var isPlaying = false

    /// How bright the logo glows (with no effect) or peaks (with one), from 0 (dimmest) to 1.
    public var brightness: Double = 1 {
        didSet { brightness = min(max(brightness, 0), 1) }
    }

    /// How long a change of brightness takes to fade.
    public var brightnessFadeDuration = 0.25

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
    public func resume() {
        cancel()
        if effect == .none {
            adjustBrightness()
        } else {
            play(effect.cycle)
        }
    }

    /// Applies a new brightness. A playing effect picks it up at its next step.
    public func brightnessDidChange() {
        guard !isPlaying else { return }
        // A fade already under way follows up with the newest value when it's done, so
        // dragging a slider doesn't restart the fade at every step.
        if !isAdjusting { adjustBrightness() }
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
            while !Task.isCancelled {
                for step in cycle {
                    guard let self, !Task.isCancelled else { return }
                    do {
                        try await self.emitter.fade(to: step.lit ? self.level : 0, over: step.fade, sleep: self.sleep)
                        try await self.sleep(step.hold)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func adjustBrightness() {
        isAdjusting = true
        let generation = generation
        task = Task { [weak self] in
            var applied: Double?
            while let self, !Task.isCancelled, applied != self.level {
                let target = self.level
                do {
                    try await self.emitter.fade(to: target, over: self.brightnessFadeDuration, sleep: self.sleep)
                } catch {
                    break
                }
                applied = target
            }
            if let self, self.generation == generation { self.isAdjusting = false }
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        isPlaying = false
        isAdjusting = false
    }
}
