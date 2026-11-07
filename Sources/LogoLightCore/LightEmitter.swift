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
    @discardableResult
    public func setFadeDuration(_ seconds: Double) -> Bool {
        service.setValue(NSNumber(value: max(0, seconds)), forKey: Key.fadeDuration)
    }

    /// Fades the logo out (`false`) or back in (`true`) over the fade duration.
    /// Doesn't change the setting: while it's off, the logo stays dark either way.
    @discardableResult
    public func setLit(_ lit: Bool) -> Bool {
        service.setValue(NSNumber(value: lit ? LogicalState.unblank : LogicalState.blank), forKey: Key.logicalState)
    }

    /// Where the logo is in a fade, from 0 (dark) to 1 (fully lit).
    public var fadeLevel: Double? {
        ((service.value(forKey: Key.pwmState) as? [String: Any])?["Factor"] as? NSNumber)?.doubleValue
    }

    /// Back to normal: automatic fade duration, and lit (when the display is on).
    public func restore(displayAwake: Bool) {
        setFadeDuration(0)
        if displayAwake { setLit(true) }
    }
}
