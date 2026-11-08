#if DEBUG
import CoreGraphics
import Foundation
import LogoLightCore

/// A pretend logo for Macs without one (debug builds only): `LOGOLIGHT_SIMULATE=1 .build/debug/LogoLight`.
///
/// It stands in for corebrightnessd's light emitter, on the wall clock, so the whole app runs as on the
/// MacBook Pro and the menu's live view shows what the logo would do: effects, brightness and Morse
/// code. Fades follow the same spring curve the tests' `FakeDaemon` was fitted to (docs/corebrightnessd.md),
/// a fade started with the hold duration doesn't visibly move, and a `DisplayLogicalState` the logo is
/// already in is ignored. It touches no hardware, so it's safe on the MacBook too. Frames, the
/// keyboard and reading back the last state sent are left out: this is for looking, not for testing
/// the emitter (`tools/livecheck` does that on the real thing).
@MainActor
final class SimulatedEmitterService: LightEmitterService {
    let hardware = SimulatedHardware()
    private var mode = 2 { didSet { hardware.isOn = mode != 0 } }
    private var fadeDuration = 0.0
    private var state = 2
    private var lastStateSent = 2
    private var fade: (from: Double, start: Double, length: Double)?
    private var restingLevel = 1.0

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private var level: Double {
        guard let fade else { return restingLevel }
        let end: Double = state == 2 ? 1 : 0
        let s = (now - fade.start) / fade.length
        return fade.from + (end - fade.from) * Self.progress(s)
    }

    /// The hardware's fade curve: a critically damped spring (as `FakeDaemon.progress`).
    private static func progress(_ s: Double) -> Double {
        let k = 6.51
        return s >= 1 ? 1 : 1 - (1 + k * s) * exp(-k * s)
    }

    func value(forKey key: String) -> Any? {
        switch key {
        case "LEBacklightMode": NSNumber(value: mode)
        case "DisplayLogicalState": NSNumber(value: lastStateSent)
        case "LEPWMState": ["Factor": NSNumber(value: level)]
        default: nil
        }
    }

    func setValue(_ value: NSNumber, forKey key: String) -> Bool {
        switch key {
        case "LEBacklightMode": mode = value.intValue
        case "LEPWMFactorFadeDuration": fadeDuration = value.doubleValue
        case "DisplayLogicalState":
            lastStateSent = value.intValue
            guard value.intValue != state else { break }
            let from = level
            restingLevel = from
            state = value.intValue
            // 0 is the daemon's automatic duration, about 0.3 s.
            fade = (from, now, fadeDuration > 0 ? fadeDuration : 0.3)
        default: break
        }
        return true
    }

    func setKeyboardValue(_ value: NSNumber, forKey key: String) {
        if key == "DisplayLogicalState" { lastStateSent = value.intValue }
    }
}

/// What the status reader sees with the simulated logo: a logo that's there, on or off as the simulated
/// daemon's setting says, and the real built-in display's sleep state.
final class SimulatedHardware: HardwareReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _isOn = true
    var isOn: Bool {
        get { lock.withLock { _isOn } }
        set { lock.withLock { _isOn = newValue } }
    }

    func nvramValue(forKey key: String) -> Data? {
        key == LogoHardware.nvramKey ? Data((isOn ? "true" : "false").utf8) : nil
    }

    func serviceProperties(named name: String) -> [String: Any]? {
        guard name == LogoHardware.pwmDeviceName else { return nil }
        return ["enabled": isOn && isBuiltInDisplayAwake() != false, "high-period": 201, "low-period": 759]
    }

    func isBuiltInDisplayAwake() -> Bool? {
        // A Mac without a built-in display (e.g. a Mac mini) counts as awake.
        Self.hasBuiltInDisplay ? SystemHardware().isBuiltInDisplayAwake() : true
    }

    func isExternalDisplayAwake() -> Bool? { SystemHardware().isExternalDisplayAwake() }

    private static let hasBuiltInDisplay: Bool = {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 }
    }()
}

extension LogoController {
    /// The controller with the simulated logo in place of the real one.
    static func simulated() -> LogoController {
        let service = SimulatedEmitterService()
        return LogoController(
            reader: LogoStatusReader(hardware: service.hardware),
            emitter: LightEmitter(service: service, clock: LightEmitter.uptime),
            admin: AppleScriptAdminShell(),
            sudo: SudoRunner(),
            isRuleInstalled: { false }
        )
    }
}
#endif
