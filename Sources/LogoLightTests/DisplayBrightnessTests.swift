import Foundation
import LogoLightCore

/// Lets pending main-actor tasks (such as an effect loop) run.
@MainActor
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

/// A fixture whose display is at `display` of full brightness, in a light where the logo's nits can go up
/// to 1000 (`MaxNitsRestriction`): its `AppliedNits` are then 1000 × `display`.
@MainActor
private func fixture(display: Double, backlightMode: Int? = nil) -> Fixture {
    let f = Fixture(backlightMode: backlightMode, direct: true, timeDriven: true)
    f.daemon.maxNits = 1000
    f.daemon.appliedNits = 1000 * display
    return f
}

/// Turns the display's brightness to `display` of full, as the app sees it on its next look.
@MainActor
private func turnDisplay(_ f: Fixture, to display: Double) {
    f.daemon.appliedNits = 1000 * display
    f.controller.displayBrightnessMayHaveChanged()
}

/// Whether the logo is held giving the light `brightness` gives with the display at full: that light
/// is the level for `brightness` times 1000 nits.
@MainActor
private func expectLight(_ t: TestHarness, _ f: Fixture, ofBrightness brightness: Double,
                         file: StaticString = #fileID, line: UInt = #line) {
    let nits = 1000 * LogoAnimator.level(forBrightness: brightness)
    t.expect(abs(f.daemon.nits - nits) <= 0.04 * nits, "gives \(f.daemon.nits) nits, not \(nits)",
             file: file, line: line)
    t.expect(f.daemon.isHolding, "should hold the level", file: file, line: line)
}

@MainActor
func displayBrightnessTests(_ t: TestHarness) async {
    print("\nThe display's brightness")

    t.test("raises the level by the headroom, up to fully lit") {
        t.expectEqual((LogoAnimator.level(forBrightness: 0.5, headroom: 2) * 1000).rounded() / 1000, 0.53)
        t.expectEqual(LogoAnimator.level(forBrightness: 0.5, headroom: 5), 1)
        t.expectEqual(LogoAnimator.level(forBrightness: 1, headroom: 3), 1)
        // Below 1 there's nothing to make up: the display can't make the logo brighter than at full.
        t.expectEqual(LogoAnimator.level(forBrightness: 0.5, headroom: 0.5), LogoAnimator.level(forBrightness: 0.5))
    }

    await t.test("keeps the logo's light when the display is turned down, then up again") {
        let f = fixture(display: 1)
        f.controller.setBrightness(0.5)
        await finish(f)
        expectLight(t, f, ofBrightness: 0.5)
        turnDisplay(f, to: 0.4)
        await finish(f)
        expectLight(t, f, ofBrightness: 0.5)
        t.expect(f.daemon.level > 0.6, "should make up for the display: at \(f.daemon.level)")
        turnDisplay(f, to: 0.8)
        await finish(f)
        expectLight(t, f, ofBrightness: 0.5)
    }

    await t.test("with the display turned far down, it's as bright as it can be, and comes back down after") {
        let f = fixture(display: 1)
        f.controller.setBrightness(0.5)
        await finish(f)
        turnDisplay(f, to: 0.1)
        await finish(f)
        t.expect(f.daemon.lit, "should be fully lit, at \(f.daemon.level)")
        turnDisplay(f, to: 1)
        await finish(f)
        expectLight(t, f, ofBrightness: 0.5)
    }

    await t.test("a brightness chosen with the display turned down gives the light it gives at full") {
        let f = fixture(display: 0.5)
        f.controller.start(brightness: 1, effect: .none)
        await finish(f)
        f.controller.setBrightness(0.3)
        await finish(f)
        expectLight(t, f, ofBrightness: 0.3)
        // Straight there, without the display's dimmer level on the way.
        t.expect(f.daemon.level >= LogoAnimator.level(forBrightness: 0.3, headroom: 2) - 0.02,
                 "went down to \(f.daemon.level)")
    }

    await t.test("launching, waking and turning the logo on go to the level that makes up for the display") {
        let f = fixture(display: 0.5)
        f.controller.start(brightness: 0.4, effect: .none)
        await finish(f)
        expectLight(t, f, ofBrightness: 0.4)

        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.daemon.appliedNits = 250 // turned down further while asleep
        f.mac.displayAwake = true
        f.controller.displayDidWake()
        await finish(f)
        expectLight(t, f, ofBrightness: 0.4)

        try await f.controller.set(.off)
        f.daemon.appliedNits = 600
        try await f.controller.set(.on)
        await finish(f)
        expectLight(t, f, ofBrightness: 0.4)
    }

    await t.test("the battery indicator's level makes up for the display too") {
        let f = fixture(display: 0.5)
        f.battery.charge = 0.6
        f.controller.setFollowsBattery(true)
        await finish(f)
        expectLight(t, f, ofBrightness: 0.6)
    }

    await t.test("effects peak at the light the brightness gives with the display at full") {
        let f = fixture(display: 0.5)
        f.controller.setBrightness(0.5)
        await finish(f)
        f.controller.setEffect(.pulse)
        f.daemon.peak = 0
        let end = f.clock.now + 5
        while f.clock.now < end { await Task.yield() }
        let level = LogoAnimator.level(forBrightness: 0.5, headroom: 2)
        t.expect(abs(f.daemon.peak - level) <= 0.03, "peaked at \(f.daemon.peak), not \(level)")

        // Turned up during the effect: later peaks follow, with no fade of its own breaking the rhythm.
        turnDisplay(f, to: 1)
        t.expect(f.controller.animator?.isPlaying == true, "Pulse should carry on")
        let later = f.clock.now + 3 // the next peak, picking up the new level
        while f.clock.now < later { await Task.yield() }
        f.daemon.peak = 0
        let last = f.clock.now + 5
        while f.clock.now < last { await Task.yield() }
        f.controller.animator?.pause()
        let full = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.peak - full) <= 0.03, "peaked at \(f.daemon.peak), not \(full)")
    }

    await t.test("small changes, such as the light sensor's noise, write nothing") {
        let f = fixture(display: 0.5)
        f.controller.setBrightness(0.5)
        await finish(f)
        f.daemon.log.removeAll()
        for nits in [510.0, 495, 505, 490] {
            f.daemon.appliedNits = nits
            f.controller.displayBrightnessMayHaveChanged()
            await finish(f)
        }
        t.expectEqual(f.daemon.log, [])
    }

    await t.test("reads nothing at full brightness, with the logo off, or while lent") {
        let f = fixture(display: 0.5)
        f.controller.start(brightness: 1, effect: .none)
        await finish(f)
        f.daemon.keysRead.removeAll()
        f.daemon.log.removeAll()
        turnDisplay(f, to: 0.2)
        await finish(f)
        t.expectEqual(f.daemon.keysRead, [])

        f.controller.setBrightness(0.5)
        await finish(f)
        try await f.controller.set(.off)
        f.daemon.keysRead.removeAll()
        f.daemon.log.removeAll()
        turnDisplay(f, to: 0.8)
        await finish(f)
        t.expectEqual(f.daemon.keysRead, [])
        t.expectEqual(f.daemon.log, [])

        try await f.controller.set(.on)
        await finish(f)
        f.controller.lend()
        f.daemon.keysRead.removeAll()
        f.daemon.log.removeAll()
        turnDisplay(f, to: 0.3)
        await finish(f)
        t.expectEqual(f.daemon.keysRead, [])
        t.expectEqual(f.daemon.log, [])
    }

    await t.test("without the nits (another macOS), the level is the brightness's own") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        await finish(f)
        t.expect(abs(f.daemon.level - LogoAnimator.level(forBrightness: 0.5)) <= 0.02, "held at \(f.daemon.level)")
        f.controller.displayBrightnessMayHaveChanged()
        await finish(f)
        t.expect(abs(f.daemon.level - LogoAnimator.level(forBrightness: 0.5)) <= 0.02, "held at \(f.daemon.level)")
    }

    await t.test("the live view shows the fade level, as the system's own brightness is shown") {
        let f = fixture(display: 0.5)
        f.controller.setBrightness(0.5)
        await finish(f)
        let glow = f.controller.liveGlow
        t.expect(abs(glow - f.daemon.level.squareRoot()) <= 0.001, "glow \(glow) at level \(f.daemon.level)")
    }
}
