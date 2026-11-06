import CoreGraphics
import Foundation
import IOKit

/// Read-only access to the hardware state that describes the logo.
/// Abstracted so the logic can be tested without the hardware.
public protocol HardwareReading: Sendable {
    /// Raw value of an NVRAM variable, or `nil` if it isn't set.
    func nvramValue(forKey key: String) -> Data?
    /// All properties of the named I/O Registry service, or `nil` if it doesn't exist.
    func serviceProperties(named name: String) -> [String: Any]?
    /// Whether the built-in display is on (not asleep, lid open), or `nil` if unknown.
    func isBuiltInDisplayAwake() -> Bool?
}

/// Reads the logo's state. Needs no special privileges.
public struct LogoStatusReader: Sendable {
    private let hardware: HardwareReading

    public init(hardware: HardwareReading = SystemHardware()) {
        self.hardware = hardware
    }

    public func read() -> LogoStatus {
        let nvram = hardware.nvramValue(forKey: LogoHardware.nvramKey)
        let pwm = hardware.serviceProperties(named: LogoHardware.pwmDeviceName)
        guard nvram != nil || pwm != nil else { return .unsupported }

        let isLit = pwm.flatMap { $0["enabled"] as? Bool }
        let level = isLit == false ? nil : pwm.flatMap(Self.dutyCycle)

        // While the screen is on, the logo is lit exactly when the setting is on, and the LED
        // driver reflects changes immediately. corebrightnessd only writes the NVRAM copy later.
        if let isLit, hardware.isBuiltInDisplayAwake() == true {
            return LogoStatus(isSupported: true, setting: isLit ? .on : .off, source: .led,
                              isLit: isLit, outputLevel: level)
        }

        // Screen off or lid closed: the LED is dark either way, so fall back to the NVRAM copy.
        // No NVRAM variable on supported hardware means the setting was never changed: on.
        let setting = nvram.map(Self.parseSetting) ?? .on
        return LogoStatus(isSupported: true, setting: setting, source: setting == nil ? nil : .nvram,
                          isLit: isLit, outputLevel: level)
    }

    /// Parses the NVRAM mirror. Values are ASCII `true` / `false`, possibly NUL-terminated.
    static func parseSetting(_ data: Data) -> LogoIllumination? {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            .lowercased()
        switch text {
        case "true", "1", "yes": return .on
        case "false", "0", "no": return .off
        default: return nil
        }
    }

    /// PWM duty cycle = time high / (time high + time low).
    static func dutyCycle(_ properties: [String: Any]) -> Double? {
        guard let high = (properties["high-period"] as? NSNumber)?.doubleValue,
              let low = (properties["low-period"] as? NSNumber)?.doubleValue,
              high >= 0, low >= 0, high + low > 0
        else { return nil }
        return high / (high + low)
    }
}

/// The real hardware.
public struct SystemHardware: HardwareReading {
    public init() {}

    public func nvramValue(forKey key: String) -> Data? {
        let options = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/options")
        guard options != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(options) }

        guard let value = IORegistryEntryCreateCFProperty(options, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        else { return nil }
        if let data = value as? Data { return data }
        if let string = value as? String { return Data(string.utf8) }
        return nil
    }

    public func serviceProperties(named name: String) -> [String: Any]? {
        // IOServiceGetMatchingService consumes the matching dictionary.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching(name))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    public func isBuiltInDisplayAwake() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        // With the lid closed, the built-in display isn't online at all.
        guard let builtIn = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
        else { return false }
        return CGDisplayIsAsleep(builtIn) == 0
    }
}
