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
/// to 1000 (`MaxNitsRestriction`): with the display's own mapping in effect, its `AppliedNits` are then
/// 1000 × `display`. With `mapping`, the daemon has that brightness mapping in effect; without, it has
/// none it can say (another macOS).
@MainActor
private func fixture(display: Double, mapping: [[Double]]? = nil) -> Fixture {
    let f = Fixture(direct: true, timeDriven: true)
    f.daemon.maxNits = 1000
    f.daemon.appliedNits = 1000 * display
    f.daemon.setMapping(mapping)
    return f
}

/// Turns the display's brightness to `display` of full, which applies the mapping last written.
@MainActor
private func turnDisplay(_ f: Fixture, to display: Double) {
    f.daemon.appliedNits = 1000 * display
    f.daemon.displayNitsChanged()
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

    await t.test("at launch, unties the logo from the display at once: a flat mapping, taken straight away") {
        let f = fixture(display: 0.5, mapping: LightEmitter.defaultMapping)
        f.controller.start(brightness: 0.5, effect: .none)
        await finish(f)
        t.expectEqual(f.daemon.mappingWrites, [LightEmitter.flatMapping])
        t.expectEqual(f.mappings.mapping, LightEmitter.defaultMapping)
        t.expect(f.controller.isUntiedFromDisplay)
        // Written back as it is, the display's brightness makes corebrightnessd take the mapping.
        t.expectEqual(f.daemon.displayRewrites, 1)
        t.expect(f.daemon.isFlatInEffect, "the flat mapping should be in effect")
        expectLight(t, f, ofBrightness: 0.5)
    }

    await t.test("once the flat mapping is in effect, the display doesn't move the logo, even turned far down") {
        let f = fixture(display: 1, mapping: LightEmitter.defaultMapping)
        f.controller.start(brightness: 0.5, effect: .none)
        await finish(f)
        f.daemon.log.removeAll()
        for display in [0.1, 0.02, 0.6, 0.3] {
            turnDisplay(f, to: display)
            await finish(f)
            expectLight(t, f, ofBrightness: 0.5)
        }
        t.expectEqual(f.daemon.log, [])
    }

    await t.test("until the mapping is taken, the logo dims with the display; the level isn't raised for it") {
        // Raised, it flashed when corebrightnessd took the mapping: AppliedNits went up at once.
        let f = fixture(display: 0.4, mapping: LightEmitter.defaultMapping)
        f.daemon.rewriteAppliesMapping = false
        f.controller.start(brightness: 0.5, effect: .none)
        await finish(f)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(!f.daemon.isFlatInEffect, "the flat mapping shouldn't be in effect yet")
        t.expect(abs(f.daemon.level - level) <= 0.01, "held at \(f.daemon.level), not \(level)")
        f.daemon.peak = 0
        f.daemon.log.removeAll()
        turnDisplay(f, to: 0.38)
        await finish(f)
        expectLight(t, f, ofBrightness: 0.5)
        t.expect(f.daemon.peak <= level + 0.01, "went up to \(f.daemon.peak)")
        t.expectEqual(f.daemon.log, [])
    }

    await t.test("at 100%, the logo is as bright as the light around allows, whatever the display") {
        let f = fixture(display: 0.2, mapping: LightEmitter.defaultMapping)
        f.controller.start(brightness: 1, effect: .none)
        await finish(f)
        t.expect(f.daemon.lit, "should be fully lit, at \(f.daemon.level)")
        t.expect(abs(f.daemon.nits - 1000) <= 1, "gives \(f.daemon.nits) nits, not 1000")
        turnDisplay(f, to: 0.15)
        await finish(f)
        t.expect(abs(f.daemon.nits - 1000) <= 1, "gives \(f.daemon.nits) nits, not 1000")
    }

    await t.test("quitting ties the logo to the display again, with the display's own mapping, taken at once") {
        let f = fixture(display: 0.5, mapping: LightEmitter.defaultMapping)
        f.controller.start(brightness: 0.5, effect: .none)
        await finish(f)
        f.controller.restoreNormalLighting()
        t.expectEqual(f.daemon.mapping, LightEmitter.defaultMapping)
        t.expect(!f.controller.isUntiedFromDisplay)
        t.expectEqual(f.daemon.displayRewrites, 2)
        t.expect(!f.daemon.isFlatInEffect, "the display's own mapping should be in effect")
    }

    await t.test("after a run that didn't quit cleanly, the flat mapping isn't kept as the display's own") {
        let theirs: [[Double]] = [[0, 0], [100, 120], [3.402823e38, 900]]
        let f = fixture(display: 0.5, mapping: LightEmitter.flatMapping)
        f.mappings.mapping = theirs // saved by that run
        f.controller.start(brightness: 0.5, effect: .none)
        await finish(f)
        t.expectEqual(f.daemon.mappingWrites, [])
        t.expectEqual(f.daemon.displayRewrites, 0)
        t.expectEqual(f.mappings.mapping, theirs)
        f.controller.restoreNormalLighting()
        t.expectEqual(f.daemon.mapping, theirs)

        // With nothing saved, macOS's own goes back.
        let g = fixture(display: 0.5, mapping: LightEmitter.flatMapping)
        g.controller.start(brightness: 0.5, effect: .none)
        await finish(g)
        g.controller.restoreNormalLighting()
        t.expectEqual(g.daemon.mapping, LightEmitter.defaultMapping)
    }

    await t.test("a mapping that isn't the flat one is left alone when quitting") {
        let f = fixture(display: 0.5, mapping: LightEmitter.defaultMapping)
        f.controller.start(brightness: 0.5, effect: .none)
        await finish(f)
        let other: [[Double]] = [[0, 0], [3.402823e38, 500]]
        _ = f.daemon.setObject(other.map { $0.map { NSNumber(value: $0) } } as NSArray, forKey: "LEPWMBrightnessNitsMapping")
        f.controller.restoreNormalLighting()
        t.expectEqual(f.daemon.mapping, other)
        t.expectEqual(f.daemon.displayRewrites, 1)
    }

    await t.test("writes the flat mapping again when corebrightnessd loses it, when asked or at a wake") {
        let f = fixture(display: 0.5, mapping: LightEmitter.defaultMapping)
        f.controller.start(brightness: 0.5, effect: .none)
        await finish(f)
        f.controller.keepBrightnessUntied()
        t.expectEqual(f.daemon.mappingWrites.count, 1) // still flat: nothing to do

        f.daemon.setMapping(LightEmitter.defaultMapping) // corebrightnessd restarted
        f.controller.keepBrightnessUntied()
        t.expectEqual(f.daemon.mapping, LightEmitter.flatMapping)
        t.expect(f.daemon.isFlatInEffect, "the flat mapping should be in effect again")
        t.expectEqual(f.daemon.displayRewrites, 2)

        f.daemon.setMapping(LightEmitter.defaultMapping)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.mac.displayAwake = true
        f.controller.displayDidWake()
        await finish(f)
        t.expectEqual(f.daemon.mapping, LightEmitter.flatMapping)
        t.expect(f.daemon.isFlatInEffect, "the flat mapping should be in effect after the wake")
        expectLight(t, f, ofBrightness: 0.5)
    }

    await t.test("with the display asleep or the logo lent, the display's brightness isn't written") {
        let f = fixture(display: 0.5, mapping: LightEmitter.defaultMapping)
        f.controller.start(brightness: 0.5, effect: .none)
        await finish(f)
        f.daemon.setMapping(LightEmitter.defaultMapping)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.controller.keepBrightnessUntied()
        t.expectEqual(f.daemon.mapping, LightEmitter.flatMapping)
        t.expectEqual(f.daemon.displayRewrites, 1) // only the launch's
        f.mac.displayAwake = true
        f.controller.displayDidWake()
        await finish(f)

        f.controller.lend()
        f.controller.restoreNormalLighting()
        t.expectEqual(f.daemon.mapping, LightEmitter.defaultMapping)
        t.expectEqual(f.daemon.displayRewrites, 1)
    }

    await t.test("without the mapping (another macOS), nothing is written") {
        let f = fixture(display: 0.5)
        f.controller.start(brightness: 0.5, effect: .none)
        await finish(f)
        f.controller.keepBrightnessUntied()
        f.controller.restoreNormalLighting()
        t.expectEqual(f.daemon.mappingWrites, [])
        t.expectEqual(f.daemon.displayRewrites, 0)
    }

    await t.test("the live view shows the fade level, as the system's own brightness is shown") {
        let f = fixture(display: 0.5)
        f.controller.setBrightness(0.5)
        await finish(f)
        let glow = f.controller.liveGlow
        t.expect(abs(glow - f.daemon.level.squareRoot()) <= 0.001, "glow \(glow) at level \(f.daemon.level)")
    }
}
