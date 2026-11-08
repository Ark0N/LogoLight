import Foundation
import LogoLightCore

private func settle() async {
    for _ in 0..<500 { await Task.yield() }
}

/// Lets the logo's fades run until the animator has stopped (for up to 10 s on the fixture's clock).
@MainActor
private func finish(_ f: Fixture) async {
    let deadline = f.clock.now + 10
    while f.controller.animator?.isAnimating == true, f.clock.now < deadline { await Task.yield() }
    await settle()
}

/// Lets an effect play for `seconds` on the fixture's clock, then pauses it.
@MainActor
private func play(_ f: Fixture, for seconds: Double) async {
    let end = f.clock.now + seconds
    while f.controller.animator?.isPlaying == true, f.clock.now < end { await Task.yield() }
    f.controller.animator?.pause()
}

/// Whether the logo is held at the level for `brightness`.
@MainActor
private func expectHeld(_ t: TestHarness, _ f: Fixture, atBrightness brightness: Double,
                        file: StaticString = #fileID, line: UInt = #line) {
    let level = LogoAnimator.level(forBrightness: brightness)
    t.expect(abs(f.daemon.level - level) <= 0.02, "held at \(f.daemon.level), not \(level)", file: file, line: line)
    t.expect(f.daemon.isHolding, "should hold the level", file: file, line: line)
}

@MainActor
func batteryTests(_ t: TestHarness) async {
    print("\nBattery indicator")

    await t.test("fades to the battery's charge and holds it there") {
        let f = Fixture(direct: true, timeDriven: true)
        f.battery.charge = 0.5
        f.controller.setFollowsBattery(true)
        t.expectEqual(f.controller.brightness, 0.5)
        await finish(f)
        expectHeld(t, f, atBrightness: 0.5)
    }

    await t.test("dims as the battery runs down") {
        let f = Fixture(direct: true, timeDriven: true)
        f.battery.charge = 0.8
        f.controller.setFollowsBattery(true)
        await finish(f)
        expectHeld(t, f, atBrightness: 0.8)
        f.battery.charge = 0.6
        f.controller.batteryDidChange()
        await finish(f)
        expectHeld(t, f, atBrightness: 0.6)
    }

    await t.test("a full battery is normal brightness, handed back to the system") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.4)
        await finish(f)
        f.battery.charge = 1
        f.controller.setFollowsBattery(true)
        await finish(f)
        t.expect(f.daemon.lit, "at \(f.daemon.level)")
        t.expect(!f.daemon.isHolding)
        t.expectEqual(f.daemon.state, 2)
    }

    await t.test("a notification with the same charge changes nothing") {
        let f = Fixture(direct: true, timeDriven: true)
        f.battery.charge = 0.5
        f.controller.setFollowsBattery(true)
        await finish(f)
        let sent = f.daemon.log.count
        f.controller.batteryDidChange()
        await finish(f)
        t.expectEqual(f.daemon.log.count, sent)
        t.expect(!f.controller.animator!.isAnimating)
    }

    await t.test("keeps the slider's brightness for when it's turned off") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.3)
        f.battery.charge = 0.9
        f.controller.setFollowsBattery(true)
        t.expectEqual(f.controller.brightness, 0.9)
        f.controller.setBrightness(0.7) // chosen meanwhile, e.g. at launch
        t.expectEqual(f.controller.brightness, 0.9)
        await finish(f)
        expectHeld(t, f, atBrightness: 0.9)
        f.controller.setFollowsBattery(false)
        t.expectEqual(f.controller.brightness, 0.7)
        await finish(f)
        expectHeld(t, f, atBrightness: 0.7)
    }

    await t.test("isn't moved by the charge while it's off") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        await finish(f)
        let sent = f.daemon.log.count
        f.battery.charge = 0.2
        f.controller.batteryDidChange()
        await finish(f)
        t.expectEqual(f.daemon.log.count, sent)
        t.expectEqual(f.controller.brightness, 0.5)
    }

    await t.test("a charge that can't be read leaves the brightness as it was") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.4)
        f.battery.charge = nil
        f.controller.setFollowsBattery(true)
        t.expectEqual(f.controller.brightness, 0.4)
        f.battery.charge = 0.6
        f.controller.batteryDidChange()
        t.expectEqual(f.controller.brightness, 0.6)
        f.battery.charge = nil
        f.controller.batteryDidChange()
        t.expectEqual(f.controller.brightness, 0.6)
    }

    await t.test("a change while the logo is off is shown when it's turned on") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        f.battery.charge = 0.9
        f.controller.setFollowsBattery(true)
        f.battery.charge = 0.5
        f.controller.batteryDidChange()
        t.expect(f.daemon.log.isEmpty, "nothing to change while the logo is off: \(f.daemon.log)")
        try await f.controller.set(.on)
        await finish(f)
        expectHeld(t, f, atBrightness: 0.5)
    }

    await t.test("effects peak at the charge") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.setHeld(at: 0, state: 1)
        f.battery.charge = 0.5
        f.controller.setFollowsBattery(true)
        f.controller.setEffect(.pulse)
        await play(f, for: 6)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(f.daemon.peak <= level + 0.02, "peaked at \(f.daemon.peak), above \(level)")
        t.expect(f.daemon.peak >= level - 0.02, "peaked at \(f.daemon.peak), below \(level)")
    }

    await t.test("a wake picks up a charge that changed while the Mac slept") {
        let f = Fixture(direct: true, timeDriven: true)
        f.battery.charge = 0.8
        f.controller.setFollowsBattery(true)
        await finish(f)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.daemon.setHeld(at: 0, state: 1)
        f.battery.charge = 0.5 // with no notification
        f.mac.displayAwake = true
        f.daemon.setHeld(at: 1, state: 2)
        f.controller.displayDidWake()
        await finish(f)
        expectHeld(t, f, atBrightness: 0.5)
    }

    await t.test("at launch, goes straight to the charge") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.setHeld(at: 0.5, state: 2) // left by the last run
        f.daemon.fadeDuration = 1e9
        f.battery.charge = 0.6
        f.controller.start(brightness: 0.3, effect: .none, followsBattery: true)
        t.expect(f.controller.followsBattery)
        t.expectEqual(f.controller.brightness, 0.6)
        await finish(f)
        expectHeld(t, f, atBrightness: 0.6)
        f.controller.setFollowsBattery(false)
        t.expectEqual(f.controller.brightness, 0.3)
    }

    t.test("without it, the battery isn't read, at launch or on a notification") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: 0.3, effect: .none)
        f.controller.batteryDidChange()
        t.expectEqual(f.battery.reads, 0)
        t.expect(!f.controller.followsBattery)
        t.expectEqual(f.controller.brightness, 0.3)
    }

    t.test("without direct control, there's nothing to follow") {
        let f = Fixture()
        f.battery.charge = 0.5
        f.controller.setFollowsBattery(true)
        t.expectEqual(f.controller.brightness, 1)
    }
}
