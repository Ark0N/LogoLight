import Foundation
import ObjectiveC

/// Key-value access to `corebrightnessd`, which drives the logo LED.
@MainActor
public protocol LightEmitterService: AnyObject {
    func value(forKey key: String) -> Any?
    func setValue(_ value: NSNumber, forKey key: String) -> Bool
}

/// Talks to `corebrightnessd` through CoreBrightness's `BrightnessSystemClient`.
///
/// This is private API, so it's loaded dynamically and `init` returns `nil` if it isn't
/// available; callers then fall back to the documented `defaults` command.
@MainActor
public final class CoreBrightnessService: LightEmitterService {
    private typealias CopyFunction = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
    private typealias SetFunction = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool

    private let client: NSObject
    private let copySelector = NSSelectorFromString("copyPropertyForKey:")
    private let setSelector = NSSelectorFromString("setProperty:forKey:")
    private let copyFunction: CopyFunction
    private let setFunction: SetFunction

    public init?() {
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard dlopen(path, RTLD_LAZY) != nil,
              let type = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
              type.instancesRespond(to: copySelector), type.instancesRespond(to: setSelector)
        else { return nil }
        client = type.init()
        copyFunction = unsafeBitCast(client.method(for: copySelector), to: CopyFunction.self)
        setFunction = unsafeBitCast(client.method(for: setSelector), to: SetFunction.self)
    }

    public func value(forKey key: String) -> Any? {
        // A "copy" method, so the result comes back retained.
        copyFunction(client, copySelector, key as NSString)?.takeRetainedValue()
    }

    public func setValue(_ value: NSNumber, forKey key: String) -> Bool {
        setFunction(client, setSelector, value, key as NSString)
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
        service.setValue(NSNumber(value: max(0, seconds)), forKey: Key.fadeDuration)
    }

    /// Fades the logo out (`false`) or back in (`true`) over the fade duration.
    /// Doesn't change the setting: while it's off, the logo stays dark either way.
    /// Ignored if the logo is already heading that way (or held after doing so).
    @discardableResult
    public func setLit(_ lit: Bool) -> Bool {
        service.setValue(NSNumber(value: lit ? LogicalState.unblank : LogicalState.blank), forKey: Key.logicalState)
    }

    /// Whether the logo was last told to fade in (`true`) or out (`false`).
    var isHeadingLit: Bool? {
        (service.value(forKey: Key.logicalState) as? NSNumber).map { $0.intValue == LogicalState.unblank }
    }

    /// Where the logo is in a fade, from 0 (dark) to 1 (fully lit).
    public var fadeLevel: Double? {
        ((service.value(forKey: Key.pwmState) as? [String: Any])?["Factor"] as? NSNumber)?.doubleValue
    }

    /// Fades the logo to `level` (0 dark … 1 fully lit) over about `duration` seconds, and holds
    /// it there until the next change. The logo still adapts to ambient light, scaled by the level.
    public func fade(to level: Double, over duration: Double, sleep: LogoAnimator.Sleep) async throws {
        let target = min(max(level, 0), 1)
        let current = fadeLevel ?? (target < 0.5 ? 1 : 0)
        guard abs(target - current) >= 0.005 else { return }

        let lit = target > current
        let end: Double = lit ? 1 : 0
        let isAllTheWay = abs(target - end) < 0.001

        // The fade must start now with the new duration, and a fade only starts when it changes
        // direction. So if it's already heading this way (or held after doing so), stop it first.
        let heading = isHeadingLit
        if heading == nil || heading == lit {
            setFadeDuration(Self.holdDuration)
            setLit(!lit)
        }
        // A fade's duration covers the whole way to 0 or 1, so stretch it to reach the
        // target in about `duration`.
        let fadeTime = isAllTheWay ? duration
            : duration / FadeCurve.timeFraction(toReach: abs(target - current) / abs(end - current))
        setFadeDuration(fadeTime)
        setLit(lit)

        if isAllTheWay {
            try await sleep(duration)
            return
        }
        var waited = 0.0
        while let now = fadeLevel, lit ? now < target : now > target, waited < fadeTime {
            try await sleep(Self.pollInterval)
            waited += Self.pollInterval
        }
        hold(headingLit: lit)
    }

    /// Stops a fade where it is by starting one the other way that's too slow to see.
    private func hold(headingLit lit: Bool) {
        setFadeDuration(Self.holdDuration)
        setLit(!lit)
    }

    /// Back to normal: fully lit (when the display is on), with the automatic fade duration.
    /// This also releases a level held by `fade(to:over:sleep:)`.
    public func restore(displayAwake: Bool) {
        if isHeadingLit != false, (fadeLevel ?? 1) < 0.999 {
            // Held after fading toward lit: turn it round (without moving) so relighting is a change.
            setFadeDuration(Self.holdDuration)
            setLit(false)
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
