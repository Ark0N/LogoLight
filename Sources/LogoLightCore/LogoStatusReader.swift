import Foundation
import IOKit

/// Read-only access to the I/O Registry values that describe the logo.
/// Abstracted so the parsing logic can be tested without the hardware.
public protocol RegistryReading: Sendable {
    /// Raw value of an NVRAM variable, or `nil` if it isn't set.
    func nvramValue(forKey key: String) -> Data?
    /// All properties of the named I/O Registry service, or `nil` if it doesn't exist.
    func serviceProperties(named name: String) -> [String: Any]?
}

/// Reads the logo's state. Needs no special privileges.
public struct LogoStatusReader: Sendable {
    private let registry: RegistryReading

    public init(registry: RegistryReading = IORegistry()) {
        self.registry = registry
    }

    public func read() -> LogoStatus {
        let nvram = registry.nvramValue(forKey: LogoHardware.nvramKey)
        let pwm = registry.serviceProperties(named: LogoHardware.pwmDeviceName)
        guard nvram != nil || pwm != nil else { return .unsupported }

        // No NVRAM variable on supported hardware means the setting was never changed: on.
        let setting = nvram.map(Self.parseSetting) ?? .on
        return LogoStatus(
            isSupported: true,
            setting: setting,
            isLit: pwm.flatMap { $0["enabled"] as? Bool },
            outputLevel: pwm.flatMap(Self.dutyCycle)
        )
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

/// The real I/O Registry.
public struct IORegistry: RegistryReading {
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
}
