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

/// Plays a `LogoEffect` in a loop.
@MainActor
public final class EffectPlayer {
    public typealias Sleep = @Sendable (Double) async throws -> Void

    private let emitter: LightEmitter
    private let isDisplayAwake: @MainActor () -> Bool
    private let sleep: Sleep
    private var loop: Task<Void, Never>?

    /// The chosen effect. It keeps its value while paused (e.g. the logo is off or the display sleeps).
    public private(set) var effect: LogoEffect = .none
    public var isRunning: Bool { loop != nil }

    public init(emitter: LightEmitter, isDisplayAwake: @escaping @MainActor () -> Bool, sleep: @escaping Sleep) {
        self.emitter = emitter
        self.isDisplayAwake = isDisplayAwake
        self.sleep = sleep
    }

    /// Chooses an effect without starting it.
    public func select(_ effect: LogoEffect) {
        self.effect = effect
    }

    /// Starts (or restarts) the chosen effect. Does nothing if no effect is chosen.
    public func resume() {
        guard effect != .none else { return }
        cancelLoop()
        let cycle = effect.cycle
        loop = Task { [weak self] in
            while !Task.isCancelled {
                for step in cycle {
                    guard let self, !Task.isCancelled else { return }
                    self.emitter.setFadeDuration(step.fade)
                    self.emitter.setLit(step.lit)
                    do { try await self.sleep(step.fade + step.hold) } catch { return }
                }
            }
        }
    }

    /// Stops the animation without relighting the logo, e.g. because it's being turned off
    /// or the display went to sleep (it's relit by the display waking anyway).
    public func pause() {
        guard isRunning else { return }
        cancelLoop()
        emitter.setFadeDuration(0)
    }

    /// Stops the animation and returns the logo to normal. The chosen effect is kept.
    public func stop() {
        cancelLoop()
        emitter.restore(displayAwake: isDisplayAwake())
    }

    private func cancelLoop() {
        loop?.cancel()
        loop = nil
    }
}
