import Foundation
import LogoLightCore

/// An in-memory stand-in for the hardware.
struct FakeHardware: HardwareReading, @unchecked Sendable {
    var nvram: [String: Data] = [:]
    var services: [String: [String: Any]] = [:]
    var displayAwake: Bool? = true
    var externalDisplayAwake: Bool? = false

    func nvramValue(forKey key: String) -> Data? { nvram[key] }
    func serviceProperties(named name: String) -> [String: Any]? { services[name] }
    func isBuiltInDisplayAwake() -> Bool? { displayAwake }
    func isExternalDisplayAwake() -> Bool? { externalDisplayAwake }
}

@MainActor private let litPWM: [String: Any] = ["enabled": true, "high-period": 201, "low-period": 759]
@MainActor private let darkPWM: [String: Any] = ["enabled": false, "high-period": 491, "low-period": 469]
private func nvram(_ value: String) -> [String: Data] { [LogoHardware.nvramKey: Data(value.utf8)] }

@MainActor
func statusReaderTests(_ t: TestHarness) {
    print("Status reader")

    t.test("reports unsupported when the logo hardware is absent") {
        t.expectEqual(LogoStatusReader(hardware: FakeHardware()).read(), .unsupported)
    }

    t.test("reads 'true' from NVRAM as on") {
        let registry = FakeHardware(nvram: [LogoHardware.nvramKey: Data("true".utf8)])
        t.expectEqual(LogoStatusReader(hardware: registry).read().setting, .on)
    }

    t.test("reads 'false' from NVRAM as off") {
        let registry = FakeHardware(nvram: [LogoHardware.nvramKey: Data("false".utf8)])
        t.expectEqual(LogoStatusReader(hardware: registry).read().setting, .off)
    }

    t.test("tolerates NUL terminators and whitespace in NVRAM values") {
        let registry = FakeHardware(nvram: [LogoHardware.nvramKey: Data("false\0".utf8)])
        t.expectEqual(LogoStatusReader(hardware: registry).read().setting, .off)
        let padded = FakeHardware(nvram: [LogoHardware.nvramKey: Data(" TRUE\n".utf8)])
        t.expectEqual(LogoStatusReader(hardware: padded).read().setting, .on)
    }

    t.test("reports an unrecognised NVRAM value as unknown") {
        let registry = FakeHardware(nvram: [LogoHardware.nvramKey: Data("maybe".utf8)])
        let status = LogoStatusReader(hardware: registry).read()
        t.expect(status.isSupported)
        t.expectEqual(status.setting, nil)
    }

    t.test("defaults to on when the device exists but NVRAM has never been written") {
        let registry = FakeHardware(services: [LogoHardware.pwmDeviceName: darkPWM], displayAwake: false)
        t.expectEqual(LogoStatusReader(hardware: registry).read().setting, .on)
    }

    t.test("trusts the LED over a stale NVRAM copy while the display is awake") {
        // Seen on a real PROLED MacBook Pro: right after turning the logo off, the LED driver
        // switches off immediately but NVRAM still says "true".
        let off = LogoStatusReader(hardware: FakeHardware(
            nvram: nvram("true"), services: [LogoHardware.pwmDeviceName: darkPWM])).read()
        t.expectEqual(off.setting, .off)
        t.expectEqual(off.source, .led)

        let on = LogoStatusReader(hardware: FakeHardware(
            nvram: nvram("false"), services: [LogoHardware.pwmDeviceName: litPWM])).read()
        t.expectEqual(on.setting, .on)
        t.expectEqual(on.source, .led)
    }

    t.test("falls back to NVRAM while the display is asleep or the lid is closed") {
        for awake in [false, nil] as [Bool?] {
            let status = LogoStatusReader(hardware: FakeHardware(
                nvram: nvram("true"), services: [LogoHardware.pwmDeviceName: darkPWM], displayAwake: awake)).read()
            t.expectEqual(status.setting, .on)
            t.expectEqual(status.source, .nvram)
        }
    }

    t.test("reports no output level while the LED is off") {
        let status = LogoStatusReader(hardware: FakeHardware(services: [LogoHardware.pwmDeviceName: darkPWM])).read()
        t.expectEqual(status.outputLevel, nil)
    }

    t.test("computes the PWM duty cycle as the output level") {
        let registry = FakeHardware(services: [LogoHardware.pwmDeviceName: litPWM])
        let level = LogoStatusReader(hardware: registry).read().outputLevel ?? -1
        t.expect(abs(level - 201.0 / 960.0) < 0.0001, "level was \(level)")
    }

    t.test("reads whether the LED driver is enabled") {
        let registry = FakeHardware(services: [LogoHardware.pwmDeviceName: ["enabled": false]])
        t.expectEqual(LogoStatusReader(hardware: registry).read().isLit, false)
    }

    t.test("leaves the output level unknown for a zero-length PWM period") {
        let registry = FakeHardware(services: [
            LogoHardware.pwmDeviceName: ["high-period": 0, "low-period": 0],
        ])
        t.expectEqual(LogoStatusReader(hardware: registry).read().outputLevel, nil)
    }

    t.test("reads this Mac's real logo state") {
        let status = LogoStatusReader().read()
        guard status.isSupported else { try t.skip("this Mac has no illuminated logo") }
        t.expect(status.setting != nil, "setting should be readable without root")
        t.expect(status.isLit != nil, "PWM device should report whether it's enabled")
        t.expect(SystemHardware().isBuiltInDisplayAwake() != nil, "display state should be readable")
        if let level = status.outputLevel { t.expect((0...1).contains(level), "level \(level)") }
        print("      this Mac: setting=\(status.setting?.rawValue ?? "?") (from \(status.source.map { "\($0)" } ?? "?")), "
              + "lit=\(status.isLit.map(String.init) ?? "?"), "
              + "level=\(status.outputLevel.map { String(format: "%.1f%%", $0 * 100) } ?? "?")")
    }
}
