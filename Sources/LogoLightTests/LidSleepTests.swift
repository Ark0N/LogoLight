import Foundation
import LogoLightCore

/// The kernel's lid sleep bit and powerd, which shares it, as their sources have them
/// (docs/corebrightnessd.md, "Lid sleep"): xnu's `IOPMrootDomain::setClamShellSleepDisable` and
/// powerd's `setClamshellSleepState()` and `disableClamshellSleepState()`.
@MainActor
final class FakePowerManagement: LidSleepSystem {
    // MARK: The kernel

    /// The one bit `kPMSetClamshellSleepState` writes, whoever calls it.
    private(set) var isLidSleepDisabled = false
    private(set) var isLidClosed = false
    private(set) var isAsleep = false
    /// Makes the kernel refuse the app's writes.
    var refuses = false

    /// Turned back on with the lid closed, lid sleep puts the Mac to sleep at once.
    private func write(disabled: Bool) {
        let wasDisabled = isLidSleepDisabled
        isLidSleepDisabled = disabled
        if wasDisabled, !disabled, isLidClosed { sleep() }
    }

    func closeLid() {
        isLidClosed = true
        if !isLidSleepDisabled { sleep() }
    }

    func openLid() {
        isLidClosed = false
        if isAsleep { wake() }
    }

    // MARK: powerd

    /// What powerd thinks it last told the kernel (`gPrevClamshellSleepState` isn't 0).
    private var powerdThinksDisabled = false
    private var isFullWake = true
    /// What WindowServer told powerd: an external display the Mac can run behind its closed lid.
    private var isDesktopMode = false

    /// `setClamshellSleepState()`: powerd wants lid sleep off in desktop mode, and tells the kernel
    /// only when that's not what it thinks it said last. It runs when an assertion against system
    /// sleep is taken or released, when desktop mode changes, and 5 s after a wake. In a dark wake it
    /// writes nothing and notes that it has to after the next full wake.
    func powerdLooks() {
        let wantsDisabled = isDesktopMode
        let changes = wantsDisabled != powerdThinksDisabled
        powerdThinksDisabled = wantsDisabled
        guard isFullWake else {
            powerdThinksDisabled = true
            return
        }
        if changes { write(disabled: wantsDisabled) }
    }

    /// The Mac goes to sleep. powerd turns lid sleep off for as long (`disableClamshellSleepState()`,
    /// on `kIOMessageSystemWillSleep`), and thinks of it as off from then on.
    func sleep() {
        guard !isAsleep else { return }
        if !powerdThinksDisabled { write(disabled: true) }
        powerdThinksDisabled = true
        isAsleep = true
        isFullWake = false
    }

    /// A full wake. powerd looks 5 s later: call `powerdLooks()` for that.
    func wake() {
        isAsleep = false
        isFullWake = true
    }

    func connectDisplay(desktopMode: Bool = true) {
        isDisplayConnected = true
        isDesktopMode = desktopMode
        powerdLooks()
    }

    func disconnectDisplay() {
        isDisplayConnected = false
        isDesktopMode = false
        powerdLooks()
    }

    // MARK: What the app asks

    private var isDisplayConnected = false
    /// Every call the app made, in order.
    private(set) var calls: [String] = []

    func setLidSleepDisabled(_ disabled: Bool) -> Bool {
        guard !refuses else { return false }
        calls.append(disabled ? "lid sleep off" : "lid sleep on")
        write(disabled: disabled)
        return true
    }

    /// powerd looks at lid sleep as an assertion against system sleep is taken or released.
    func takeAssertions() {
        calls.append("assertions")
        powerdLooks()
    }

    func releaseAssertions() {
        calls.append("release")
        powerdLooks()
    }

    func hasExternalDisplay() -> Bool { isDisplayConnected }

    func startGuard() -> Bool {
        calls.append("guard")
        return true
    }
}

@MainActor
func lidSleepTests(_ t: TestHarness) {
    print("\nLid sleep")

    t.test("turns lid sleep off, and back on when it lets go") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        blocker.set(true)
        t.expect(blocker.isHolding)
        mac.closeLid()
        t.expect(!mac.isAsleep, "the Mac should stay awake behind the closed lid")
        mac.openLid()
        blocker.set(false)
        t.expect(!blocker.isHolding)
        mac.closeLid()
        t.expect(mac.isAsleep, "the Mac should sleep when the lid closes again")
    }

    t.test("takes its assertions before it turns lid sleep off, with the guard started first") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        blocker.set(true)
        t.expectEqual(mac.calls, ["guard", "assertions", "lid sleep off"])
    }

    // Issue #11: powerd turns lid sleep back on 5 s after every wake.
    t.test("keeps the Mac awake behind the lid after it has slept and woken") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        blocker.set(true)
        mac.sleep()
        mac.wake()
        blocker.renew()
        mac.powerdLooks()
        t.expect(mac.isLidSleepDisabled, "lid sleep should still be off after powerd's look")
        mac.closeLid()
        t.expect(!mac.isAsleep, "the Mac should stay awake behind the closed lid")
    }

    t.test("turns lid sleep off again when powerd has turned it on before the wake is handled") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        blocker.set(true)
        mac.sleep()
        mac.wake()
        mac.powerdLooks()
        t.expect(!mac.isLidSleepDisabled, "the fake's powerd should turn lid sleep back on after a wake")
        blocker.renew()
        t.expect(mac.isLidSleepDisabled)
    }

    t.test("turns lid sleep off again within its interval, whatever turned it on") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        blocker.set(true)
        mac.sleep()
        mac.wake()
        mac.powerdLooks()
        blocker.keep()
        t.expect(mac.isLidSleepDisabled)
        // A display comes and goes: powerd turns lid sleep off for it, and back on after it.
        mac.connectDisplay()
        mac.disconnectDisplay()
        t.expect(!mac.isLidSleepDisabled, "the fake's powerd should turn lid sleep on when a display goes")
        blocker.keep()
        t.expect(mac.isLidSleepDisabled)
    }

    t.test("asked to hold while it does, turns lid sleep off again") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        blocker.set(true)
        mac.sleep()
        mac.wake()
        mac.powerdLooks()
        blocker.set(true)
        t.expect(mac.isLidSleepDisabled)
        t.expectEqual(mac.calls.filter { $0 == "assertions" }.count, 1)
    }

    t.test("holds from a dark wake on, through the full wake after it") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        // Asleep with the lid closed, and plugged in: the app starts holding in a dark wake.
        mac.closeLid()
        t.expect(mac.isAsleep)
        blocker.set(true)
        mac.openLid()
        blocker.renew()
        mac.powerdLooks()
        t.expect(mac.isLidSleepDisabled)
        mac.closeLid()
        t.expect(!mac.isAsleep, "the Mac should stay awake behind the closed lid")
    }

    t.test("starts holding just after a wake, before powerd has looked") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        mac.sleep()
        mac.wake()
        // Plugged in a moment after the lid opened.
        blocker.set(true)
        mac.powerdLooks()
        t.expect(mac.isLidSleepDisabled, "powerd's look after the wake shouldn't undo the hold")
    }

    t.test("lets the Mac sleep when it lets go behind a closed lid") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        blocker.set(true)
        mac.closeLid()
        // Unplugged.
        blocker.set(false)
        t.expect(mac.isAsleep)
        t.expectEqual(Array(mac.calls.suffix(2)), ["release", "lid sleep on"])
    }

    t.test("leaves lid sleep off for an external display's clamshell mode") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        mac.connectDisplay()
        blocker.set(true)
        mac.closeLid()
        t.expect(!mac.isAsleep)
        // The logo is switched off, or the app quits: powerd still has lid sleep off, with the same bit.
        blocker.set(false)
        t.expect(!mac.isAsleep, "the Mac should stay awake behind its display")
        t.expect(mac.isLidSleepDisabled)
        // The display goes: powerd turns lid sleep on itself, and the Mac sleeps as it does anyway.
        mac.disconnectDisplay()
        t.expect(mac.isAsleep)
    }

    t.test("turns lid sleep back on once the display has gone, if powerd doesn't") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        // A display powerd doesn't keep the Mac awake for.
        mac.connectDisplay(desktopMode: false)
        blocker.set(true)
        blocker.set(false)
        t.expect(mac.isLidSleepDisabled)
        blocker.keep()
        t.expect(mac.isLidSleepDisabled, "lid sleep should stay off while the display is connected")
        mac.disconnectDisplay()
        t.expect(mac.isLidSleepDisabled, "the fake's powerd shouldn't write here: it never had lid sleep off")
        blocker.keep()
        t.expect(!mac.isLidSleepDisabled)
        t.expectEqual(mac.calls.filter { $0 == "lid sleep on" }.count, 1)
        blocker.keep()
        t.expectEqual(mac.calls.filter { $0 == "lid sleep on" }.count, 1)
    }

    t.test("writes nothing while it hasn't held") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        mac.connectDisplay()
        mac.disconnectDisplay()
        mac.connectDisplay()
        blocker.set(false)
        blocker.keep()
        blocker.renew()
        t.expectEqual(mac.calls, [])
        t.expect(mac.isLidSleepDisabled, "powerd's own setting should be left alone")
    }

    t.test("starts the guard once, and takes its assertions once for each hold and each wake") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        blocker.set(true)
        blocker.set(true)
        blocker.keep()
        blocker.renew()
        blocker.set(false)
        blocker.set(true)
        t.expectEqual(mac.calls.filter { $0 == "guard" }.count, 1)
        t.expectEqual(mac.calls.filter { $0 == "assertions" }.count, 3)
        t.expectEqual(mac.calls.filter { $0 == "release" }.count, 1)
    }

    t.test("holds nothing while the kernel refuses, and tries again") {
        let mac = FakePowerManagement()
        let blocker = LidSleepBlocker(system: mac)
        mac.refuses = true
        blocker.set(true)
        t.expect(!blocker.isHolding)
        t.expectEqual(Array(mac.calls.suffix(2)), ["assertions", "release"])
        mac.refuses = false
        blocker.set(true)
        t.expect(blocker.isHolding)
        t.expect(mac.isLidSleepDisabled)
    }
}
