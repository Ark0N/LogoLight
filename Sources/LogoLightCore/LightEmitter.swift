import Foundation
import ObjectiveC

/// Key-value access to `corebrightnessd`, which drives the logo LED.
@MainActor
public protocol LightEmitterService: AnyObject {
    func value(forKey key: String) -> Any?
    func setValue(_ value: NSNumber, forKey key: String) -> Bool
    /// Sends a key to the keyboard backlights only.
    func setKeyboardValue(_ value: NSNumber, forKey key: String)
}

/// Talks to `corebrightnessd` through CoreBrightness's `BrightnessSystemClient`.
///
/// This is private API, so it's loaded dynamically and `init` returns `nil` if it isn't
/// available; callers then fall back to the documented `defaults` command.
@MainActor
public final class CoreBrightnessService: LightEmitterService {
    private typealias CopyFunction = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
    private typealias SetFunction = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
    private typealias SetForKeyboardFunction = @convention(c) (AnyObject, Selector, AnyObject, NSString, UInt64) -> Bool

    private let client: NSObject
    private let copySelector = NSSelectorFromString("copyPropertyForKey:")
    private let setSelector = NSSelectorFromString("setProperty:forKey:")
    private let keyboardSetSelector = NSSelectorFromString("setProperty:withKey:keyboardID:")
    private let copyFunction: CopyFunction
    private let setFunction: SetFunction
    private let setForKeyboardFunction: SetForKeyboardFunction?
    private let keyboardIDs: [UInt64]

    public init?() {
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard dlopen(path, RTLD_LAZY) != nil,
              let type = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
              type.instancesRespond(to: copySelector), type.instancesRespond(to: setSelector)
        else { return nil }
        client = type.init()
        copyFunction = unsafeBitCast(client.method(for: copySelector), to: CopyFunction.self)
        setFunction = unsafeBitCast(client.method(for: setSelector), to: SetFunction.self)
        setForKeyboardFunction = type.instancesRespond(to: keyboardSetSelector)
            ? unsafeBitCast(client.method(for: keyboardSetSelector), to: SetForKeyboardFunction.self)
            : nil
        keyboardIDs = Self.copyKeyboardIDs()
    }

    private static func copyKeyboardIDs() -> [UInt64] {
        let selector = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type,
              type.instancesRespond(to: selector)
        else { return [] }
        let ids = type.init().perform(selector)?.takeRetainedValue() as? [NSNumber]
        return ids?.map(\.uint64Value) ?? []
    }

    public func value(forKey key: String) -> Any? {
        // A "copy" method, so the result comes back retained.
        copyFunction(client, copySelector, key as NSString)?.takeRetainedValue()
    }

    public func setValue(_ value: NSNumber, forKey key: String) -> Bool {
        setFunction(client, setSelector, value, key as NSString)
    }

    public func setKeyboardValue(_ value: NSNumber, forKey key: String) {
        guard let setForKeyboardFunction else { return }
        for id in keyboardIDs {
            _ = setForKeyboardFunction(client, keyboardSetSelector, value, key as NSString, id)
        }
    }
}

/// The logo LED, as controlled by `corebrightnessd`'s light emitter (LE) module.
///
/// None of this needs root. Changing the setting here has the same effect as Apple's
/// documented `defaults` command: `corebrightnessd` (which runs as root) saves it to the
/// root `com.apple.CoreBrightness` `LEBacklightMode` default itself.
@MainActor
public final class LightEmitter {
    enum Key {
        /// 0 = off, 2 = on. (1 also lights the logo but is saved as off, so it isn't used.)
        static let mode = "LEBacklightMode"
        /// The fade duration in seconds when the logo is darkened or relit. 0 = automatic.
        static let fadeDuration = "LEPWMFactorFadeDuration"
        /// The display state the logo follows: it fades out on "Blank" and back in on "Unblank".
        /// The keyboard backlight follows it too, but the screen doesn't.
        static let logicalState = "DisplayLogicalState"
        /// Live state, including `Factor` (0–1, the fade position).
        static let pwmState = "LEPWMState"
    }

    enum Mode {
        static let off = 0
        static let on = 2
    }

    enum LogicalState {
        static let blank = 1
        static let unblank = 2
    }

    /// A fade duration so long that a fade started with it never visibly moves. Starting one
    /// is how the logo is held at a level (see docs/corebrightnessd.md, "Holding a level").
    static let holdDuration = 1e9

    /// How often the fade level is checked while fading to a level in between.
    static let pollInterval = 0.01

    private let service: LightEmitterService

    /// Which way the logo was last told to fade (`true` is toward lit), or `nil` when that isn't
    /// known: at launch, and once the display sleeps or wakes (`corebrightnessd` changes the state
    /// itself then). It can't be read back, because `DisplayLogicalState` gives the last value
    /// sent to anything, including the keyboard. Everything here is safe with `nil`.
    private(set) var isHeadingLit: Bool?

    /// Whether the last fade duration written was `holdDuration`, so a fade heading for 0 or 1
    /// may be a hold that never gets there.
    private var lastDurationWasHold = false

    public init(service: LightEmitterService) {
        self.service = service
    }

    /// The setting, read from `corebrightnessd`. `nil` if it isn't available.
    public var setting: LogoIllumination? {
        guard let mode = (service.value(forKey: Key.mode) as? NSNumber)?.intValue else { return nil }
        return mode == Mode.off ? .off : .on
    }

    @discardableResult
    public func setSetting(_ setting: LogoIllumination) -> Bool {
        service.setValue(NSNumber(value: setting == .on ? Mode.on : Mode.off), forKey: Key.mode)
    }

    /// How long the logo takes to fade when it's darkened or relit. 0 restores the automatic duration.
    /// It applies to the next fade; a fade in progress keeps its duration.
    @discardableResult
    public func setFadeDuration(_ seconds: Double) -> Bool {
        lastDurationWasHold = seconds >= Self.holdDuration
        return service.setValue(NSNumber(value: max(0, seconds)), forKey: Key.fadeDuration)
    }

    /// Fades the logo out (`false`) or back in (`true`) over the fade duration.
    /// Doesn't change the setting: while it's off, the logo stays dark either way.
    /// Ignored if the logo is already heading that way (or held after doing so).
    ///
    /// The keyboard backlight would darken too, so it's told straight away that the display is
    /// still on, which it can do without its light visibly changing.
    private func setLit(_ lit: Bool, keepingKeyboardLit keepKeyboard: Bool = true) {
        _ = service.setValue(NSNumber(value: lit ? LogicalState.unblank : LogicalState.blank),
                             forKey: Key.logicalState)
        isHeadingLit = lit
        if !lit, keepKeyboard { setKeyboardLit(true) }
    }

    /// Starts a fade the other way that's too slow to see. That stops the logo where it is, and
    /// makes heading `lit` a change again (see docs/corebrightnessd.md, "Holding a level").
    private func turnRound(from lit: Bool, keepingKeyboardLit keepKeyboard: Bool = true) {
        setFadeDuration(Self.holdDuration)
        setLit(!lit, keepingKeyboardLit: keepKeyboard)
    }

    /// Call when the display sleeps or wakes: `corebrightnessd` changes the state it sends
    /// the logo itself, and the keyboard should follow the display again.
    public func displayDidChange(isAwake: Bool) {
        isHeadingLit = nil
        setKeyboardLit(isAwake)
    }

    /// Tells the keyboard backlight whether the display is on, without affecting the logo.
    private func setKeyboardLit(_ lit: Bool) {
        service.setKeyboardValue(NSNumber(value: lit ? LogicalState.unblank : LogicalState.blank),
                                 forKey: Key.logicalState)
    }

    /// Where the logo is in a fade, from 0 (dark) to 1 (fully lit).
    public var fadeLevel: Double? {
        ((service.value(forKey: Key.pwmState) as? [String: Any])?["Factor"] as? NSNumber)?.doubleValue
    }

    /// How much longer than its `duration` a fade may take to reach a target that moved on
    /// (see `fade(following:over:sleep:)`) before it's started again instead.
    static let followSlack = 2.0

    /// Fades the logo to `level` (0 dark … 1 fully lit) over about `duration` seconds, and holds
    /// it there until the next change. The logo still adapts to ambient light, scaled by the level.
    public func fade(to level: Double, over duration: Double, sleep: LogoAnimator.Sleep) async throws {
        try await fade(following: { level }, over: duration, sleep: sleep)
    }

    /// Like `fade(to:over:sleep:)`, but reads the target again on every poll, e.g. while a slider
    /// is dragged. While it keeps moving the same way, the fade carries on and stops where it
    /// passes the latest target, instead of stopping and starting again from rest each time.
    /// It stops short when the target turns round, reaches 0 or 1, or runs too far ahead for
    /// this fade to catch up in time, so that a new fade can take over.
    ///
    /// Returns the target the logo was stopped at, or `nil` if it stopped short.
    @discardableResult
    public func fade(following level: () -> Double, over duration: Double,
                     sleep: LogoAnimator.Sleep) async throws -> Double? {
        var target = min(max(level(), 0), 1)
        // Unknown: assume the far end, so the fade goes all the way.
        let current = fadeLevel ?? (target < 0.5 ? 1 : 0)
        guard abs(target - current) >= 0.005 else {
            stay(at: target, over: duration)
            return target
        }

        let lit = target > current
        let end: Double = lit ? 1 : 0
        let isAllTheWay = abs(target - end) < 0.001

        // The fade must start now with the new duration, and a fade only starts when it changes
        // direction. So if it's already heading this way (or held after doing so), stop it first.
        // When that isn't known, the turn-round is either ignored or too slow to see.
        if isHeadingLit == nil || isHeadingLit == lit { turnRound(from: lit) }
        // A fade's duration covers the whole way to 0 or 1, so stretch it to reach the
        // target in about `duration`.
        let fadeTime = isAllTheWay ? duration
            : duration / FadeCurve.timeFraction(toReach: abs(target - current) / abs(end - current))
        setFadeDuration(fadeTime)
        setLit(lit)

        if isAllTheWay {
            try await sleep(duration)
            return target
        }
        var waited = 0.0
        while let now = fadeLevel, waited < fadeTime {
            let latest = min(max(level(), 0), 1)
            if latest != target {
                let isAhead = lit ? latest > now : latest < now
                let reachedIn = fadeTime * FadeCurve.timeFraction(toReach: abs(latest - current) / abs(end - current))
                guard isAhead, abs(latest - end) >= 0.001, reachedIn - waited <= Self.followSlack * duration
                else {
                    turnRound(from: lit)
                    return nil
                }
                target = latest
            }
            if lit ? now >= target : now <= target { break }
            try await sleep(Self.pollInterval)
            waited += Self.pollInterval
        }
        turnRound(from: lit) // and hold it there
        return target
    }

    /// Keeps the logo at a target it has (about) reached. A fade may still be under way, e.g. from
    /// an effect step that was cancelled, and it would carry the logo on past the target.
    private func stay(at target: Double, over duration: Double) {
        if target <= 0.001 || target >= 0.999 {
            // A fade toward an end stops there by itself, unless it's a hold. A hold heading that
            // way is replaced by a real fade, so the end isn't left with the endless duration.
            let lit = target >= 0.999
            if isHeadingLit != lit || lastDurationWasHold {
                if isHeadingLit == lit { turnRound(from: lit) }
                setFadeDuration(duration)
                setLit(lit)
            }
        } else if let heading = isHeadingLit {
            turnRound(from: heading)
        } else {
            // Heading unknown: each write is either ignored or starts a fade too slow to see.
            setFadeDuration(Self.holdDuration)
            setLit(false)
            setLit(true)
        }
    }

    /// Back to normal: fully lit (when the display is on), with the automatic fade duration.
    /// This also releases a level held by `fade(to:over:sleep:)`.
    public func restore(displayAwake: Bool) {
        if isHeadingLit != false, (fadeLevel ?? 1) < 0.999 {
            // Held after fading toward lit: turn it round (without moving) so relighting is a change.
            turnRound(from: true, keepingKeyboardLit: displayAwake)
        }
        setFadeDuration(0)
        if displayAwake { setLit(true) }
    }
}

/// The shape of the logo's fades, measured on the real hardware (see docs/corebrightnessd.md,
/// "The fade curve"): progress toward 0 or 1 at each 5% of the fade's duration.
public enum FadeCurve {
    static let progress: [Double] = [0, 0.04, 0.13, 0.24, 0.37, 0.48, 0.57, 0.66, 0.74, 0.79, 0.84,
                                     0.88, 0.91, 0.93, 0.95, 0.97, 0.98, 0.99, 0.995, 1, 1]

    /// The fraction of a fade's duration it takes to cover `fraction` of the way.
    public static func timeFraction(toReach fraction: Double) -> Double {
        let goal = min(max(fraction, 0), 1)
        let step = 1 / Double(progress.count - 1)
        for i in 1..<progress.count where progress[i] >= goal {
            let span = progress[i] - progress[i - 1]
            let within = span > 0 ? (goal - progress[i - 1]) / span : 1
            return max(0.05, (Double(i - 1) + within) * step)
        }
        return 1
    }
}
