import Foundation
import IOKit
import IOKit.pwr_mgt

/// What `LidSleepBlocker` asks of the system, so its logic can be tested against a stand-in for the
/// kernel and powerd (`FakePowerManagement` in the tests).
@MainActor
public protocol LidSleepSystem: AnyObject {
    /// Turns lid sleep off or back on in the kernel. Returns whether the kernel took it.
    func setLidSleepDisabled(_ disabled: Bool) -> Bool
    /// Takes the assertions that keep the Mac awake, then releases any it took before.
    func takeAssertions()
    func releaseAssertions()
    /// Whether an external display is connected, awake or asleep.
    func hasExternalDisplay() -> Bool
    /// Starts the process that turns lid sleep back on when this one exits. Returns whether it started.
    func startGuard() -> Bool
}

/// Keeps the Mac awake when the lid closes, so the logo can stay lit without an external display.
///
/// What does it is the power management root domain's `kPMSetClamshellSleepState`: with lid sleep
/// off, a closed lid changes nothing for the Mac. A `PreventSystemSleep` assertion alone isn't
/// enough: the Mac then goes into a dark wake ("Entering DarkWake state due to 'Clamshell Sleep'"),
/// and the logo stays dark. Two assertions are held with it, against idle sleep, as in the probe
/// that showed this working (tools/probes/lidawake).
///
/// **The kernel has one bit for this, and it's powerd's** (docs/corebrightnessd.md, "Lid sleep").
/// powerd turns lid sleep off while the Mac sleeps and while an external display is connected
/// (clamshell mode), and back on when that's over: 5 s after every wake, and when the display goes.
/// It doesn't know of anyone else's write, and the bit can't be read back. So a single write doesn't
/// last (issue #11: once the Mac had slept, a closed lid put it to sleep again, until the option was
/// switched off and on), and this:
/// - writes it again every time it's asked to hold (`set(true)`, which the app calls on every menu
///   update), every `keepInterval` (`keep()`), and after a wake (`renew()`);
/// - takes its assertions before it writes, and again after a wake. powerd looks at lid sleep as an
///   assertion is taken, so it turns lid sleep back on before the write, not 5 s after it;
/// - turns lid sleep back on only once no external display is connected. With one, powerd has it
///   off with the same bit, for clamshell mode, and doesn't write it again: the Mac would go to
///   sleep behind its display. powerd turns it on itself when the display goes.
///
/// The kernel keeps the setting after the process that made it has gone, so a LogoLight that
/// crashed or was killed would leave a Mac that stays awake in a bag. A second process, the guard
/// (`LogoLight --lid-guard <pid>`), waits for this one to exit and then turns lid sleep back on.
@MainActor
public final class LidSleepBlocker {
    /// How often lid sleep is turned off again while the Mac is kept awake, whatever turned it on.
    public static let keepInterval = 2.0

    private let system: LidSleepSystem
    /// Whether the Mac is kept awake behind a closed lid.
    public private(set) var isHolding = false
    /// Whether lid sleep is off because of this, and still has to be turned back on.
    private var owesLidSleep = false
    private var hasGuard = false
    private var keepsTime = false
    private var timer: Timer?

    public init(system: LidSleepSystem = SystemLidSleep()) {
        self.system = system
    }

    /// Keeps the Mac awake behind a closed lid, or stops. Asked again for what it's doing already,
    /// it writes lid sleep again.
    public func set(_ holds: Bool) {
        if holds { hold() } else { letGo() }
        updateTimer()
    }

    /// Call after a wake. powerd turns lid sleep back on 5 s after one, at its next look; taking the
    /// assertions anew has it look now, before lid sleep is turned off again.
    public func renew() {
        if isHolding { system.takeAssertions() }
        keep()
    }

    /// Writes lid sleep again as it should be: off while the Mac is kept awake, and back on once the
    /// external display that held that up has gone.
    public func keep() {
        set(isHolding)
    }

    /// Has `keep()` run every `keepInterval` from now on, while there's anything to keep.
    public func startKeeping() {
        keepsTime = true
        updateTimer()
    }

    private func hold() {
        if !isHolding {
            if !hasGuard { hasGuard = system.startGuard() }
            system.takeAssertions()
        }
        if system.setLidSleepDisabled(true) {
            isHolding = true
            owesLidSleep = true
        } else if !isHolding {
            // The kernel didn't take it: tried again the next time.
            system.releaseAssertions()
        }
    }

    private func letGo() {
        if isHolding {
            isHolding = false
            system.releaseAssertions()
        }
        guard owesLidSleep, !system.hasExternalDisplay() else { return }
        if system.setLidSleepDisabled(false) { owesLidSleep = false }
    }

    private func updateTimer() {
        let isNeeded = keepsTime && (isHolding || owesLidSleep)
        guard isNeeded != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard isNeeded else { return }
        let timer = Timer(timeInterval: Self.keepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keep() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// The real system: the kernel's power management root domain, powerd's assertions, and the guard.
@MainActor
public final class SystemLidSleep: LidSleepSystem {
    private var assertions: [IOPMAssertionID] = []

    public init() {}

    public func setLidSleepDisabled(_ disabled: Bool) -> Bool {
        LidSleep.setDisabled(disabled)
    }

    public func takeAssertions() {
        let held = assertions
        assertions = [kIOPMAssertionTypePreventSystemSleep, kIOPMAssertionTypePreventUserIdleSystemSleep].compactMap { type in
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "LogoLight keeps the logo lit with the lid closed" as CFString, &id)
            return result == kIOReturnSuccess ? id : nil
        }
        held.forEach { IOPMAssertionRelease($0) }
    }

    public func releaseAssertions() {
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions = []
    }

    public func hasExternalDisplay() -> Bool {
        LidSleep.hasExternalDisplay()
    }

    /// The guard outlives this process by a moment, whatever ends it. It's this executable, which has
    /// to hand `LidSleep.guardArgument` to `LidSleep.runGuard(for:)` before anything else, as the
    /// app's main.swift does: one that doesn't runs as itself again, and starts a guard of its own.
    public func startGuard() -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = [LidSleep.guardArgument, String(ProcessInfo.processInfo.processIdentifier)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}

/// Lid sleep: whether closing the lid puts the Mac to sleep.
public enum LidSleep {
    public static let guardArgument = "--lid-guard"

    /// Turns lid sleep off or back on. Needs no privileges. Returns whether the kernel took it.
    public static func setDisabled(_ disabled: Bool) -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(root) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(root, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return false }
        defer { IOServiceClose(connection) }
        var input: UInt64 = disabled ? 1 : 0
        return IOConnectCallScalarMethod(connection, UInt32(kPMSetClamshellSleepState), &input, 1, nil, nil) == KERN_SUCCESS
    }

    /// Whether an external display is connected: powerd then has lid sleep off itself, with the bit
    /// `setDisabled(_:)` writes.
    public static func hasExternalDisplay() -> Bool {
        SystemHardware().hasExternalDisplay() == true
    }

    /// The guard process: waits for the app (`pid`) to exit, turns lid sleep back on, and exits.
    /// The app has done that itself if it quit normally; doing it twice does no harm. Like the app,
    /// it leaves lid sleep to powerd while an external display is connected.
    public static func runGuard(for pid: pid_t) -> Never {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { finishGuard() }
        source.resume()
        // It may have gone before the source was set up.
        if kill(pid, 0) != 0, errno == ESRCH { finishGuard() }
        dispatchMain()
    }

    private static func finishGuard() -> Never {
        if !hasExternalDisplay() { _ = setDisabled(false) }
        exit(0)
    }
}
