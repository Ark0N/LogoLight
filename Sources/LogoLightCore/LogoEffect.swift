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
    ///
    /// To the eye, a rise from dark looks about twice as fast as a fall from lit over the same
    /// time, so rises are longer than falls, with short holds at the top. These are starting
    /// values, still to be tuned by eye on the MacBook.
    public var cycle: [FadeStep] {
        switch self {
        case .none:
            []
        case .breathe:
            // Slow and soft, like the old MacBook sleep light.
            [FadeStep(lit: false, fade: 2.0, hold: 0.5), FadeStep(lit: true, fade: 3.5, hold: 0.3)]
        case .pulse:
            [FadeStep(lit: false, fade: 0.7, hold: 0.1), FadeStep(lit: true, fade: 1.2, hold: 0.15)]
        case .heartbeat:
            // Two quick beats from dark, then a rest (about 1.55 s a cycle).
            [FadeStep(lit: true, fade: 0.12, hold: 0.05), FadeStep(lit: false, fade: 0.18, hold: 0.08),
             FadeStep(lit: true, fade: 0.12, hold: 0.05), FadeStep(lit: false, fade: 0.5, hold: 0.45)]
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
    /// The Morse message being sent, if any. While it's set it takes the place of the effect, which
    /// keeps its value and comes back when the message is done or stopped.
    public private(set) var morse: MorseMessage?
    /// Called when `morse` ends by itself: a message sent once has finished, or was interrupted (the
    /// logo turned off, the display slept). Not called for `stopMorse()`.
    public var onMorseEnded: (@MainActor () -> Void)?
    /// Whether an effect (or a Morse message) is playing.
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
        if let morse {
            playMorse(morse)
        } else if effect == .none {
            adjustBrightness(over: transitionDuration)
        } else {
            let isDark = (emitter.fadeLevel ?? 1) < level / 2
            play(effect.cycle(startingLit: isDark))
        }
    }

    /// Sends `message` in Morse, replacing the effect until it's done (once) or stopped (a loop). Call
    /// only while the logo is lit and the display is awake, as for `resume()`. Returns false, changing
    /// nothing, if the message has no character Morse can send.
    @discardableResult
    public func startMorse(_ message: MorseMessage) -> Bool {
        guard MorseCode.canSend(message.text) else { return false }
        morse = message
        resume()
        return true
    }

    /// Forgets the Morse message, without starting anything else: the caller resumes, or not.
    public func stopMorse() {
        morse = nil
    }

    /// Switches the loop of the Morse message being sent, without restarting it: on, it carries on
    /// after this pass; off, it ends after it.
    public func setMorseLoops(_ loops: Bool) {
        morse?.loops = loops
    }

    private func playMorse(_ message: MorseMessage) {
        // From dark, with a word gap first, so the first dot can't be mistaken for the logo going out.
        let isDark = (emitter.fadeLevel ?? 1) < 0.05
        let leadIn = isDark ? [] : [FadeStep(lit: false, fade: 0.3, hold: 7 * MorseCode.unit)]
        // At full brightness: both ends are plain hardware fades, with no easing to stretch the timing.
        play(MorseCode.steps(for: message.text), leadIn: leadIn, peak: 1)
    }

    /// Applies a new brightness. A playing effect picks it up at its next step.
    public func brightnessDidChange() {
        guard !isPlaying else { return }
        // A fade already under way follows the newest value, so dragging a slider doesn't
        // restart the fade at every step.
        if !isAdjusting { adjustBrightness(over: brightnessFadeDuration) }
    }

    /// Stops animating, leaving the logo as it is, e.g. because it's being turned off or the
    /// display went to sleep.
    public func pause() {
        cancel()
        endMorseUnlessLooping()
    }

    /// Stops animating and hands the logo back to the system, fully lit, e.g. before quitting.
    /// The chosen effect and brightness are kept.
    public func reset() {
        cancel()
        endMorseUnlessLooping()
        emitter.restore(displayAwake: isDisplayAwake())
    }

    /// A message sent once has ended without being stopped: let the owner know.
    private func endMorseUnlessLooping() {
        guard let morse, !morse.loops else { return }
        self.morse = nil
        onMorseEnded?()
    }

    /// Plays `leadIn` once, then `cycle` over and over: an effect until it's stopped, a Morse message
    /// (which has a `peak`) while its loop is on, which can be switched while it plays. Lit steps go to
    /// `peak`, or the chosen brightness without one. A message that ends (its loop off at the end of
    /// a pass) is cleared, and what was there before resumes (the effect or the brightness).
    private func play(_ cycle: [FadeStep], leadIn: [FadeStep] = [], peak: Double? = nil) {
        isPlaying = true
        let cycleHold = cycle.reduce(0) { $0 + $1.hold }
        task = Task { [weak self] in
            // Easing onto a peak below full takes longer than the step's fade. The time it ran over
            // is taken from the holds that follow, as far as they go, so the cycle keeps its length:
            // Heartbeat's short holds can't absorb its beats' easing, but its rest can.
            var owed = 0.0
            var steps = leadIn + cycle
            playing: while true {
                for step in steps {
                    guard let self, !Task.isCancelled else { return }
                    // The display can go away without a sleep notification, e.g. when the lid is
                    // closed with an external display attached. Stop until the next wake.
                    guard self.isDisplayAwake() else { break playing }
                    do {
                        // Morse code (which has a `peak`) keeps every flash and gap its length, timed
                        // from when the logo moves: a rise corebrightnessd holds back delays the rest
                        // of the message, rather than cutting a dot short or squeezing the next gap.
                        let exact = peak != nil
                        let took = try await self.emitter.timedFade(to: step.lit ? peak ?? self.level : 0,
                                                                    over: step.fade, sleep: self.sleep,
                                                                    waitingForRise: exact)
                        if exact {
                            try await self.sleep(step.hold)
                            continue
                        }
                        owed = min(owed + max(0, took - step.fade), cycleHold)
                        let hold = max(0, step.hold - owed)
                        owed -= step.hold - hold
                        try await self.sleep(hold)
                    } catch {
                        break playing
                    }
                }
                guard peak == nil || self?.morse?.loops == true else {
                    // Done. (Cancelled at the last moment: whoever cancelled has taken over.)
                    guard let self, !Task.isCancelled else { return }
                    if self.morse?.loops == false {
                        self.morse = nil
                        self.onMorseEnded?()
                    }
                    self.resume() // replaces this task, which then ends as a cancelled one
                    return
                }
                steps = cycle
            }
            if let self, !Task.isCancelled { self.endMorseUnlessLooping() }
            self?.taskDidEnd()
        }
    }

    /// Fades to the chosen brightness over `duration`. A fade follows changes made meanwhile
    /// (a slider being dragged), and anything it couldn't follow gets a new fade, at the
    /// slider's speed.
    private func adjustBrightness(over duration: Double) {
        isAdjusting = true
        task = Task { [weak self] in
            var applied: Double?
            var duration = duration
            while let self, !Task.isCancelled, applied != self.level {
                do {
                    applied = try await self.emitter.fade(following: { self.level }, over: duration, sleep: self.sleep)
                } catch {
                    break
                }
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
