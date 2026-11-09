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

/// Lets an effect play for `seconds` on the fixture's clock, leaving it playing.
@MainActor
private func run(_ f: Fixture, for seconds: Double) async {
    let end = f.clock.now + seconds
    var turns = 0
    while f.clock.now < end, turns < 2_000_000 {
        await Task.yield()
        turns += 1
    }
}

/// Yields until `condition` holds, or gives up.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// Whether the logo is held at the level for `brightness`.
@MainActor
private func expectHeld(_ t: TestHarness, _ f: Fixture, atBrightness brightness: Double,
                        file: StaticString = #fileID, line: UInt = #line) {
    let level = LogoAnimator.level(forBrightness: brightness)
    t.expect(abs(f.daemon.level - level) <= 0.02, "held at \(f.daemon.level), not \(level)", file: file, line: line)
    t.expect(f.daemon.isHolding, "should hold the level", file: file, line: line)
}

/// The lowest and highest level in the fixture's trace.
@MainActor
private func levelRange(_ f: Fixture) -> (low: Double, high: Double) {
    let levels = (f.daemon.trace ?? []).map(\.level)
    return (levels.min() ?? -1, levels.max() ?? -1)
}

/// Everything sent to corebrightnessd over 8 s of the logo playing, with `change` made 2 s in.
/// `setUp` runs first, on a fixture with the logo lit at normal brightness.
@MainActor
private func log(setUp: @MainActor (Fixture) -> Void, change: (@MainActor (Fixture) -> Void)? = nil) async -> [String] {
    let f = Fixture(direct: true, timeDriven: true)
    setUp(f)
    await run(f, for: 2)
    change?(f)
    await run(f, for: 6)
    f.controller.restoreNormalLighting()
    return f.daemon.log
}

@MainActor
func chargingTests(_ t: TestHarness) async {
    print("\nCharging light")

    await t.test("breathes while the battery charges, and goes back to normal when it stops") {
        let f = Fixture(direct: true, timeDriven: true)
        f.battery.isCharging = true
        f.daemon.trace = []
        f.controller.setBreathesWhileCharging(true)
        t.expect(f.controller.animator!.isPlaying)
        t.expectEqual(f.controller.animator?.activeEffect, .breathe)
        t.expectEqual(f.controller.effect, LogoEffect.none) // the chosen effect is kept
        // Breathe's cycle is 6.3 s: from lit, a fall to dark and a rise back.
        await run(f, for: 8)
        let (low, high) = levelRange(f)
        t.expect(low <= 0.01, "should fade to dark, lowest \(low)")
        t.expect(high >= 0.99, "should rise to full, highest \(high)")
        f.battery.isCharging = false
        f.controller.batteryDidChange()
        t.expect(!f.controller.animator!.isPlaying)
        await finish(f)
        t.expect(f.daemon.lit, "at \(f.daemon.level)")
        t.expect(!f.daemon.isHolding)
        t.expectEqual(f.daemon.state, 2)
    }

    await t.test("peaks at the brightness") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        await finish(f)
        f.battery.isCharging = true
        f.controller.setBreathesWhileCharging(true)
        f.daemon.peak = 0
        await run(f, for: 8)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.peak - level) <= 0.02, "peaked at \(f.daemon.peak), not \(level)")
        f.controller.restoreNormalLighting()
    }

    await t.test("keeps the chosen effect, which comes back when charging stops") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setEffect(.pulse)
        f.controller.setBreathesWhileCharging(true)
        t.expectEqual(f.controller.animator?.activeEffect, .pulse) // not charging yet
        f.battery.isCharging = true
        f.controller.batteryDidChange()
        t.expectEqual(f.controller.animator?.activeEffect, .breathe)
        t.expectEqual(f.controller.effect, .pulse)
        await run(f, for: 3)
        f.battery.isCharging = false
        f.controller.batteryDidChange()
        t.expectEqual(f.controller.animator?.activeEffect, .pulse)
        t.expect(f.controller.animator!.isPlaying)
        f.controller.restoreNormalLighting()
    }

    await t.test("with Sound chosen, it stops listening while it breathes, and listens again after") {
        let f = Fixture(direct: true, timeDriven: true)
        f.sound.level = 1
        f.controller.setEffect(.sound)
        f.controller.setBreathesWhileCharging(true)
        t.expect(f.sound.isListening) // not charging yet
        f.battery.isCharging = true
        f.controller.batteryDidChange()
        t.expectEqual(f.controller.animator?.activeEffect, .breathe)
        t.expect(!f.sound.isListening)
        t.expectEqual(f.controller.effect, .sound)
        await run(f, for: 3)
        t.expectEqual(f.sound.starts, 1)
        f.battery.isCharging = false
        f.controller.batteryDidChange()
        t.expectEqual(f.controller.animator?.activeEffect, .sound)
        t.expect(f.sound.isListening)
        t.expectEqual(f.sound.starts, 2)
        // Choosing Sound while it breathes doesn't start listening until charging stops.
        f.controller.setEffect(.none)
        f.battery.isCharging = true
        f.controller.batteryDidChange()
        f.controller.setEffect(.sound)
        t.expect(!f.sound.isListening)
        t.expectEqual(f.sound.starts, 2)
        f.battery.isCharging = false
        f.controller.batteryDidChange()
        t.expect(f.sound.isListening)
        t.expectEqual(f.sound.starts, 3)
        f.controller.restoreNormalLighting()
    }

    await t.test("choosing an effect while it breathes doesn't interrupt the breathing") {
        @MainActor func setUp(_ f: Fixture) {
            f.battery.isCharging = true
            f.controller.setBreathesWhileCharging(true)
        }
        var chosen: LogoEffect?
        let steady = await log(setUp: setUp)
        let changed = await log(setUp: setUp) { f in
            f.controller.setEffect(.heartbeat)
            chosen = f.controller.effect
        }
        t.expectEqual(chosen, .heartbeat)
        t.expect(steady.count > 4, "should have breathed: \(steady)")
        t.expectEqual(changed, steady)
    }

    await t.test("with Breathe chosen, charging starting changes nothing") {
        @MainActor func setUp(_ f: Fixture) {
            f.controller.setEffect(.breathe)
            f.controller.setBreathesWhileCharging(true)
        }
        let steady = await log(setUp: setUp)
        let plugged = await log(setUp: setUp) { f in
            f.battery.isCharging = true
            f.controller.batteryDidChange()
        }
        t.expect(steady.count > 4, "should have breathed: \(steady)")
        t.expectEqual(plugged, steady)
    }

    await t.test("a Morse message carries on when charging starts, and the breathing follows it") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBreathesWhileCharging(true)
        var ended = 0, endedAt = 0.0
        f.controller.onMorseEnded = {
            ended += 1
            endedAt = f.daemon.time
        }
        f.daemon.trace = []
        f.controller.playMorse("SOS", loops: false)
        for _ in 0..<20 { await Task.yield() }
        let sentBefore = f.daemon.log.count
        t.expect(ended == 0 && sentBefore > 0, "should be sending")
        f.battery.isCharging = true
        f.controller.batteryDidChange()
        t.expectEqual(f.controller.morse?.text, "SOS") // still sending
        t.expectEqual(f.controller.animator?.activeEffect, .breathe) // next, once it's done
        t.expect(await waitUntil { ended == 1 }, "the message should end")
        // Sent once, not restarted: SOS's nine flashes (lit above half), before it ended.
        var flashes = 0, wasLit = true // lit at the start, before the lead-in
        for sample in f.daemon.trace ?? [] where sample.time <= endedAt {
            if sample.level > 0.5, !wasLit { flashes += 1 }
            wasLit = sample.level > 0.5
        }
        t.expectEqual(flashes, 9)
        t.expect(f.controller.animator!.isPlaying)
        t.expectEqual(f.controller.animator?.activeEffect, .breathe)
        f.controller.restoreNormalLighting()
    }

    await t.test("turned on while not charging, changes nothing") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        await finish(f)
        let sent = f.daemon.log.count
        f.controller.setBreathesWhileCharging(true)
        f.controller.batteryDidChange()
        await settle()
        t.expectEqual(f.daemon.log.count, sent)
        t.expect(!f.controller.animator!.isAnimating)
        t.expectEqual(f.battery.chargingReads, 2)
    }

    await t.test("turned off while charging, goes back to the chosen brightness") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        await finish(f)
        f.battery.isCharging = true
        f.controller.setBreathesWhileCharging(true)
        await run(f, for: 3)
        f.controller.setBreathesWhileCharging(false)
        t.expectEqual(f.controller.animator?.activeEffect, LogoEffect.none)
        await finish(f)
        expectHeld(t, f, atBrightness: 0.5)
    }

    await t.test("with the logo off, starts breathing when it's turned on, with a rise from dark") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        f.battery.isCharging = true
        f.controller.setBreathesWhileCharging(true)
        t.expect(f.daemon.log.isEmpty, "nothing to change while the logo is off: \(f.daemon.log)")
        t.expect(!f.controller.animator!.isPlaying)
        f.clock.budget = 3
        try await f.controller.set(.on)
        await settle()
        let rise = LogoEffect.breathe.cycle(startingLit: true)[0]
        let afterSwitchingOn = Array(f.daemon.log.drop(while: { $0 != "mode=2" }).dropFirst())
        t.expectEqual(Array(afterSwitchingOn.prefix(2)), ["fade=\(rise.fade)", "unblank"])
        t.expect(!f.daemon.log.contains("fade=1.0"), "no separate fade in before the breathing")
    }

    await t.test("charging that starts while the display sleeps shows after the wake") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBreathesWhileCharging(true)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        let sent = f.daemon.log.count
        f.battery.isCharging = true
        f.controller.batteryDidChange()
        await settle()
        t.expectEqual(f.daemon.log.count, sent) // nothing while the display sleeps
        t.expect(!f.controller.animator!.isPlaying)
        f.mac.displayAwake = true
        f.controller.displayDidWake()
        t.expect(f.controller.animator!.isPlaying)
        t.expectEqual(f.controller.animator?.activeEffect, .breathe)
        f.controller.restoreNormalLighting()
    }

    await t.test("a wake picks up the Mac plugged in or unplugged while it slept") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBreathesWhileCharging(true)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.battery.isCharging = true // with no notification
        f.mac.displayAwake = true
        f.controller.displayDidWake()
        t.expectEqual(f.controller.animator?.activeEffect, .breathe)
        t.expect(f.controller.animator!.isPlaying)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.battery.isCharging = false
        f.mac.displayAwake = true
        f.controller.displayDidWake()
        t.expectEqual(f.controller.animator?.activeEffect, LogoEffect.none)
        await finish(f)
        t.expect(f.daemon.lit, "at \(f.daemon.level)")
    }

    await t.test("at launch, breathes if the battery is charging, keeping the chosen effect") {
        let f = Fixture(direct: true, timeDriven: true)
        f.battery.isCharging = true
        f.controller.start(brightness: 0.5, effect: .pulse, breathesWhileCharging: true)
        t.expect(f.controller.breathesWhileCharging)
        t.expect(f.controller.animator!.isPlaying)
        t.expectEqual(f.controller.animator?.activeEffect, .breathe)
        t.expectEqual(f.controller.effect, .pulse)
        f.controller.restoreNormalLighting()

        let unplugged = Fixture(direct: true, timeDriven: true)
        unplugged.controller.start(brightness: 1, effect: .none, breathesWhileCharging: true)
        t.expect(!unplugged.controller.animator!.isAnimating)
        t.expect(unplugged.daemon.lit)
    }

    t.test("without it, whether the battery charges isn't read") {
        let f = Fixture(direct: true, timeDriven: true)
        f.battery.isCharging = true
        f.controller.start(brightness: 1, effect: .none)
        f.controller.batteryDidChange()
        t.expectEqual(f.battery.chargingReads, 0)
        t.expectEqual(f.controller.animator?.activeEffect, LogoEffect.none)
    }

    await t.test("a state that can't be read leaves the last one") {
        let f = Fixture(direct: true, timeDriven: true)
        f.battery.isCharging = true
        f.controller.setBreathesWhileCharging(true)
        f.battery.isCharging = nil
        f.controller.batteryDidChange()
        t.expect(f.controller.isCharging)
        t.expectEqual(f.controller.animator?.activeEffect, .breathe)
        f.controller.restoreNormalLighting()
    }

    t.test("without direct control, there's nothing to breathe") {
        let f = Fixture()
        f.battery.isCharging = true
        f.controller.setBreathesWhileCharging(true)
        f.controller.batteryDidChange()
        t.expect(f.controller.animator == nil)
        t.expect(f.admin.scripts.isEmpty)
    }
}
