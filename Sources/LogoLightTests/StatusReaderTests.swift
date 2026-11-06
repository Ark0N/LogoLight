import Foundation
import LogoLightCore

/// An in-memory stand-in for the I/O Registry.
struct FakeRegistry: RegistryReading, @unchecked Sendable {
    var nvram: [String: Data] = [:]
    var services: [String: [String: Any]] = [:]

    func nvramValue(forKey key: String) -> Data? { nvram[key] }
    func serviceProperties(named name: String) -> [String: Any]? { services[name] }
}

@MainActor private let litPWM: [String: Any] = ["enabled": true, "high-period": 201, "low-period": 759]

@MainActor
func statusReaderTests(_ t: TestHarness) {
    print("Status reader")

    t.test("reports unsupported when the logo hardware is absent") {
        t.expectEqual(LogoStatusReader(registry: FakeRegistry()).read(), .unsupported)
    }

    t.test("reads 'true' from NVRAM as on") {
        let registry = FakeRegistry(nvram: [LogoHardware.nvramKey: Data("true".utf8)])
        t.expectEqual(LogoStatusReader(registry: registry).read().setting, .on)
    }

    t.test("reads 'false' from NVRAM as off") {
        let registry = FakeRegistry(nvram: [LogoHardware.nvramKey: Data("false".utf8)])
        t.expectEqual(LogoStatusReader(registry: registry).read().setting, .off)
    }

    t.test("tolerates NUL terminators and whitespace in NVRAM values") {
        let registry = FakeRegistry(nvram: [LogoHardware.nvramKey: Data("false\0".utf8)])
        t.expectEqual(LogoStatusReader(registry: registry).read().setting, .off)
        let padded = FakeRegistry(nvram: [LogoHardware.nvramKey: Data(" TRUE\n".utf8)])
        t.expectEqual(LogoStatusReader(registry: padded).read().setting, .on)
    }

    t.test("reports an unrecognised NVRAM value as unknown") {
        let registry = FakeRegistry(nvram: [LogoHardware.nvramKey: Data("maybe".utf8)])
        let status = LogoStatusReader(registry: registry).read()
        t.expect(status.isSupported)
        t.expectEqual(status.setting, nil)
    }

    t.test("defaults to on when the device exists but NVRAM has never been written") {
        let registry = FakeRegistry(services: [LogoHardware.pwmDeviceName: litPWM])
        t.expectEqual(LogoStatusReader(registry: registry).read().setting, .on)
    }

    t.test("computes the PWM duty cycle as the output level") {
        let registry = FakeRegistry(services: [LogoHardware.pwmDeviceName: litPWM])
        let level = LogoStatusReader(registry: registry).read().outputLevel ?? -1
        t.expect(abs(level - 201.0 / 960.0) < 0.0001, "level was \(level)")
    }

    t.test("reads whether the LED driver is enabled") {
        let registry = FakeRegistry(services: [LogoHardware.pwmDeviceName: ["enabled": false]])
        t.expectEqual(LogoStatusReader(registry: registry).read().isLit, false)
    }

    t.test("leaves the output level unknown for a zero-length PWM period") {
        let registry = FakeRegistry(services: [
            LogoHardware.pwmDeviceName: ["high-period": 0, "low-period": 0],
        ])
        t.expectEqual(LogoStatusReader(registry: registry).read().outputLevel, nil)
    }

    t.test("reads this Mac's real logo state from the I/O Registry") {
        let status = LogoStatusReader().read()
        guard status.isSupported else { try t.skip("this Mac has no illuminated logo") }
        t.expect(status.setting != nil, "setting should be readable without root")
        t.expect(status.isLit != nil, "PWM device should report whether it's enabled")
        if let level = status.outputLevel { t.expect((0...1).contains(level), "level \(level)") }
        print("      this Mac: setting=\(status.setting?.rawValue ?? "?"), "
              + "lit=\(status.isLit.map(String.init) ?? "?"), "
              + "level=\(status.outputLevel.map { String(format: "%.1f%%", $0 * 100) } ?? "?")")
    }
}
