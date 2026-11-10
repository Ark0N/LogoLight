import Foundation
import LogoLightCore

extension Fixture {
    /// The lid closing with an external display attached, as on the real Mac: the built-in display
    /// goes away, and corebrightnessd tells every module, which darkens the logo and the keyboard.
    func closeLid() {
        mac.displayAwake = false
        mac.externalDisplayAwake = true
        daemon.moveLid(closed: true)
    }

    func openLid() {
        daemon.moveLid(closed: false)
        mac.displayAwake = true
    }

    /// What the app does when the lid closes: handles it as a sleep, then as a wake a moment later.
    func handleLidClosing() async {
        controller.displayDidSleep()
        controller.scheduleWake(after: 1) {}
        await settle()
    }
}

/// Lets pending main-actor tasks (such as an effect loop) run.
@MainActor
private func settle() async {
    for _ in 0..<500 { await Task.yield() }
}

/// Lets the fake's time run until nothing is animating, or `seconds` of it have passed (an effect
/// never stops by itself).
@MainActor
private func run(_ f: Fixture, for seconds: Double = 10) async {
    let start = f.clock.now
    while f.controller.animator?.isAnimating == true, f.clock.now - start < seconds { await Task.yield() }
}

@MainActor
func lidTests(_ t: TestHarness) async {
    print("\nLit with Lid Closed")

    await t.test("relights the logo once the lid has closed, and keeps the keyboard dark") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .none, lightsWithLidClosed: true)
        f.closeLid()
        f.daemon.elapse(1)
        t.expectEqual(f.daemon.level, 0)
        f.daemon.log.removeAll()
        await f.handleLidClosing()
        await run(f)
        // The logo is told the lid is open, then the keyboard and the displays alone that it's closed.
        t.expectEqual(Array(f.daemon.log.prefix(4)),
                      ["fade=0.0", "ClamshellUpdate=0", "keyboard ClamshellUpdate=1", "displays ClamshellUpdate=1"])
        t.expect(f.daemon.lit, "the logo should be lit, but it's at \(f.daemon.level)")
        t.expect(!f.daemon.isKeyboardLit, "the keyboard should stay dark")
        t.expect(f.daemon.displaysToldLidClosed, "the displays (True Tone) should still be told the lid is closed")
    }

    await t.test("holds the chosen brightness with the lid closed") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: 0.5, effect: .none, lightsWithLidClosed: true)
        await run(f)
        f.closeLid()
        await f.handleLidClosing()
        await run(f)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.level - level) <= 0.02, "at \(f.daemon.level), not \(level)")
        t.expect(f.daemon.isHolding)
    }

    await t.test("plays an effect on with the lid closed, peaking at the brightness") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: 0.5, effect: .pulse, lightsWithLidClosed: true)
        f.closeLid()
        await f.handleLidClosing()
        f.daemon.peak = 0
        var lowest = 1.0
        let start = f.clock.now
        while f.clock.now - start < 6 {
            lowest = min(lowest, f.daemon.level)
            await Task.yield()
        }
        t.expect(f.controller.animator!.isPlaying, "the effect should still be playing")
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.peak - level) <= 0.03, "peaked at \(f.daemon.peak), not \(level)")
        t.expect(lowest <= 0.01, "should go dark between pulses, but only got down to \(lowest)")
        t.expect(!f.daemon.isKeyboardLit, "the keyboard should stay dark")
        f.controller.restoreNormalLighting()
    }

    await t.test("switching the logo on with the lid closed fades it in to the brightness") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        f.controller.start(brightness: 0.5, effect: .none, lightsWithLidClosed: true)
        f.closeLid()
        await f.handleLidClosing()
        try await f.controller.set(.on)
        await run(f)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.level - level) <= 0.02, "at \(f.daemon.level), not \(level)")
    }

    await t.test("without it, closing the lid pauses an effect and leaves the logo dark") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: 0.5, effect: .pulse, lightsWithLidClosed: false)
        f.closeLid()
        await f.handleLidClosing()
        f.daemon.elapse(1)
        t.expect(!f.controller.animator!.isAnimating, "the effect should be paused")
        t.expectEqual(f.daemon.level, 0)
        t.expect(f.daemon.logoToldLidClosed && !f.daemon.isKeyboardLit, "both should be told the lid is closed")
        t.expectEqual(f.controller.effect, .pulse)
    }

    for (label, from) in [("reached going down", 1.0), ("reached going up", 0.2)] {
        await t.test("without it, closing the lid darkens a logo held at a level \(label)") {
            let f = Fixture(direct: true, timeDriven: true)
            f.controller.start(brightness: from, effect: .none, lightsWithLidClosed: false)
            await run(f)
            f.controller.setBrightness(0.5)
            await run(f)
            f.closeLid()
            f.daemon.elapse(1)
            // As on the real Mac, the daemon alone leaves a held level lit.
            t.expect(f.daemon.level > 0.2, "the fake should keep the hold, but it's at \(f.daemon.level)")
            await f.handleLidClosing()
            f.daemon.elapse(1)
            t.expectEqual(f.daemon.level, 0)
            t.expectEqual(f.daemon.log.last, "ClamshellUpdate=1")
            t.expect(!f.daemon.isHolding, "the fade duration should be automatic again")
        }
    }

    await t.test("turned on with the lid closed, lights the logo; turned off, darkens it again") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: 0.5, effect: .none)
        f.closeLid()
        await f.handleLidClosing()
        f.daemon.elapse(1)
        t.expectEqual(f.daemon.level, 0)

        f.controller.setLightsWithLidClosed(true)
        await run(f)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.level - level) <= 0.02, "at \(f.daemon.level), not \(level)")

        // Held at the level, which the lid state alone wouldn't darken.
        f.controller.setLightsWithLidClosed(false)
        t.expectEqual(f.daemon.log.last, "ClamshellUpdate=1")
        f.daemon.elapse(1)
        t.expectEqual(f.daemon.level, 0)
        t.expect(!f.daemon.isHolding, "the fade duration should be automatic again")
        t.expect(!f.controller.animator!.isAnimating)
        t.expect(!f.daemon.isKeyboardLit)
    }

    await t.test("turned on or off with the lid open, writes nothing") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .none)
        f.daemon.log.removeAll()
        f.controller.setLightsWithLidClosed(true)
        f.controller.setLightsWithLidClosed(false)
        t.expectEqual(f.daemon.log, [])
    }

    await t.test("quitting with the lid closed darkens the logo, as the closed lid would") {
        let f = Fixture(direct: true, timeDriven: true)
        f.closeLid()
        f.daemon.elapse(1)
        // Launched with the lid already closed.
        f.controller.start(brightness: 0.5, effect: .none, lightsWithLidClosed: true)
        await run(f)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.level - level) <= 0.02, "at launch at \(f.daemon.level), not \(level)")
        f.daemon.log.removeAll()
        f.controller.restoreNormalLighting()
        t.expectEqual(f.daemon.log.last, "ClamshellUpdate=1")
        t.expect(f.daemon.log.firstIndex(of: "fade=0.0").map { $0 < f.daemon.log.count - 1 } == true,
                 "the fade duration should be automatic first: \(f.daemon.log)")
        f.daemon.elapse(1)
        t.expectEqual(f.daemon.level, 0)
    }

    await t.test("once the lid has opened, quitting writes no lid state") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .pulse, lightsWithLidClosed: true)
        f.closeLid()
        await f.handleLidClosing()
        // An effect playing through the lid opening needs no wake, so none is handled.
        f.openLid()
        f.daemon.log.removeAll()
        f.controller.restoreNormalLighting()
        t.expect(!f.daemon.log.contains { $0.contains("ClamshellUpdate") }, "wrote \(f.daemon.log)")
        t.expect(f.daemon.isKeyboardLit, "the keyboard should be lit again")
    }

    await t.test("a wake with the lid closed tells the logo again") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .none, lightsWithLidClosed: true)
        f.closeLid()
        await f.handleLidClosing()
        await run(f)
        // The display sleeps, and corebrightnessd sends the lid state again meanwhile.
        f.controller.displayDidSleep()
        f.mac.externalDisplayAwake = false
        f.daemon.moveLid(closed: true)
        f.daemon.elapse(1)
        t.expectEqual(f.daemon.level, 0)
        f.mac.externalDisplayAwake = true
        f.controller.scheduleWake(after: 1) {}
        await settle()
        await run(f)
        t.expect(f.daemon.lit, "the logo should be lit again, but it's at \(f.daemon.level)")
    }

    await t.test("doesn't relight the logo while the external display sleeps") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: 0.5, effect: .pulse, lightsWithLidClosed: true)
        f.closeLid()
        f.mac.externalDisplayAwake = false
        await f.handleLidClosing()
        t.expect(!f.controller.animator!.isAnimating, "nothing should play while no display is on")
    }

    await t.test("at launch with the lid closed and the option off, ends an override a previous run left") {
        let f = Fixture(direct: true, timeDriven: true)
        f.closeLid()
        _ = f.daemon.setValue(false, forKey: "ClamshellUpdate") // left by a run that crashed
        f.daemon.log.removeAll()
        f.controller.start(brightness: nil, effect: .none, lightsWithLidClosed: false)
        t.expect(f.daemon.log.contains("ClamshellUpdate=1"), "wrote \(f.daemon.log)")
        f.daemon.elapse(1)
        t.expectEqual(f.daemon.level, 0)
        // Once is enough.
        f.daemon.log.removeAll()
        f.controller.displayDidWake()
        t.expect(!f.daemon.log.contains { $0.contains("ClamshellUpdate") }, "wrote \(f.daemon.log)")
    }

    await t.test("isn't offered without corebrightnessd's lid state, and writes nothing then") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.lidClosed = nil
        t.expect(!f.controller.canLightWithLidClosed)
        f.controller.start(brightness: nil, effect: .none, lightsWithLidClosed: true)
        f.mac.displayAwake = false
        f.mac.externalDisplayAwake = true
        await f.handleLidClosing()
        t.expect(!f.daemon.log.contains { $0.contains("ClamshellUpdate") }, "wrote \(f.daemon.log)")
        t.expect(!Fixture().controller.canLightWithLidClosed, "not without direct control either")
    }
}
