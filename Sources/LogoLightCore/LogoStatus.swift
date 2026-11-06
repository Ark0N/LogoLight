import Foundation

/// Whether the illuminated Apple logo is set to light up.
public enum LogoIllumination: String, Sendable, Equatable, CaseIterable {
    case on
    case off

    public var toggled: LogoIllumination { self == .on ? .off : .on }
}

/// A snapshot of the logo's setting and the LED's live output.
public struct LogoStatus: Sendable, Equatable {
    /// `false` when this Mac has no illuminated logo.
    public var isSupported: Bool
    /// The user's setting, as mirrored into NVRAM by `corebrightnessd`.
    /// `nil` when it can't be read.
    public var setting: LogoIllumination?
    /// Whether the logo's LED driver is currently switched on.
    public var isLit: Bool?
    /// The LED driver's current PWM duty cycle, from 0 to 1.
    /// macOS adjusts this automatically to follow display brightness and ambient light.
    public var outputLevel: Double?

    public init(isSupported: Bool, setting: LogoIllumination?, isLit: Bool?, outputLevel: Double?) {
        self.isSupported = isSupported
        self.setting = setting
        self.isLit = isLit
        self.outputLevel = outputLevel
    }

    public static let unsupported = LogoStatus(isSupported: false, setting: nil, isLit: nil, outputLevel: nil)
}

/// Where the logo's state lives in the I/O Registry on PROLED MacBook Pro models.
///
/// `corebrightnessd` watches the `LEBacklightMode` default and mirrors it into the
/// `<device>-enabled` NVRAM variable, which is how the setting also applies in macOS Recovery.
public enum LogoHardware {
    /// Name of the back-lid logo PWM device in the I/O Registry.
    public static let pwmDeviceName = "bklb-backlight"
    /// NVRAM variable that mirrors the `LEBacklightMode` setting (`"true"` or `"false"`).
    public static let nvramKey = "\(pwmDeviceName)-enabled"
}
