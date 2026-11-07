import Foundation
import LogoLightCore

@MainActor
func directControlTests(_ t: TestHarness) async {
    print("\nController: direct control through corebrightnessd")

    t.test("reads the setting from corebrightnessd") {
        let f = Fixture(direct: true)
        f.daemon.mode = 0
        let status = f.controller.status()
        t.expectEqual(status.setting, .off)
        t.expectEqual(status.source, .daemon)
        t.expect(f.controller.canControlDirectly)
    }

    await t.test("fades the logo out, then turns it off, without a password") {
        let f = Fixture(direct: true)
        let status = try await f.controller.set(.off)
        t.expectEqual(status.setting, .off)
        t.expectEqual(f.daemon.log, ["fade=1.0", "blank", "mode=0", "fade=0.0", "unblank"])
        t.expectEqual(f.clock.slept, [1.0])
        t.expect(f.admin.scripts.isEmpty, "no password dialog expected")
    }

    await t.test("turns the logo on from dark, then fades it in") {
        let f = Fixture(backlightMode: 0, direct: true)
        let status = try await f.controller.set(.on)
        t.expectEqual(status.setting, .on)
        t.expectEqual(f.daemon.log, ["fade=0.05", "blank", "mode=2", "fade=1.0", "unblank", "fade=0.0", "unblank"])
        t.expect(f.admin.scripts.isEmpty, "no password dialog expected")
    }

    await t.test("switches instantly when the fade duration is 0") {
        let f = Fixture(direct: true)
        f.controller.switchFadeDuration = 0
        try await f.controller.set(.off)
        t.expectEqual(f.daemon.log, ["mode=0", "fade=0.0", "unblank"])
    }

    await t.test("doesn't fade or relight while the display is asleep") {
        let f = Fixture(direct: true)
        f.mac.displayAwake = false
        try await f.controller.set(.off)
        t.expectEqual(f.daemon.log, ["mode=0", "fade=0.0"])
        t.expectEqual(f.daemon.mode, 0)
    }

    await t.test("falls back to the documented command if corebrightnessd rejects the change") {
        let f = Fixture(direct: true)
        f.daemon.acceptsChanges = false
        try await f.controller.set(.off)
        t.expectEqual(f.admin.scripts, [CoreBrightnessSetting.command(for: .off).shellString])
        t.expectEqual(f.mac.backlightMode, 0)
    }

    await t.test("falls back to the documented command if corebrightnessd ignores the change") {
        let f = Fixture(direct: true)
        f.daemon.appliesChanges = false
        try await f.controller.set(.off)
        t.expectEqual(f.admin.scripts.count, 1)
        t.expectEqual(f.daemon.log.last, "unblank")
    }

    t.test("has no effects without direct control") {
        let f = Fixture()
        t.expect(!f.controller.canControlDirectly)
        t.expect(f.controller.animator == nil)
        f.controller.setEffect(.breathe)
        t.expectEqual(f.controller.effect, .none)
        f.controller.setBrightness(0.5)
        t.expectEqual(f.controller.brightness, 1)
    }
}

@MainActor
func effectTests(_ t: TestHarness) async {
    print("\nEffects")

    t.test("every effect alternates between dark and lit, with positive durations") {
        for effect in LogoEffect.allCases where effect != .none {
            let cycle = effect.cycle
            t.expect(cycle.count >= 2, "\(effect) needs at least two steps")
            t.expect(cycle.allSatisfy { $0.fade > 0 && $0.hold >= 0 }, "\(effect) durations")
            t.expect(zip(cycle, cycle.dropFirst() + cycle.prefix(1)).allSatisfy { $0.lit != $1.lit },
                     "\(effect) should alternate")
        }
        t.expectEqual(LogoEffect.none.cycle, [])
    }

    await t.test("plays the effect's steps in a loop") {
        let f = Fixture(direct: true)
        f.clock.budget = 8
        f.controller.setEffect(.breathe)
        t.expect(f.controller.animator!.isPlaying)
        await settle()
        t.expectEqual(Array(f.daemon.log.prefix(8)),
                      ["fade=2.2", "blank", "fade=2.2", "unblank", "fade=2.2", "blank", "fade=2.2", "unblank"])
        t.expectEqual(Array(f.clock.slept.prefix(4)), [2.2, 0.3, 2.2, 1.2])
    }

    await t.test("waits for the logo to be on before playing") {
        let f = Fixture(backlightMode: 0, direct: true)
        f.controller.setEffect(.pulse)
        t.expectEqual(f.controller.effect, .pulse)
        t.expect(!f.controller.animator!.isPlaying, "shouldn't play while the logo is off")
        f.clock.budget = 20
        try await f.controller.set(.on)
        t.expect(f.controller.animator!.isPlaying, "should start once the logo is on")
        f.controller.restoreNormalLighting()
    }

    await t.test("stops when the logo is turned off, and keeps the choice") {
        let f = Fixture(direct: true)
        f.controller.setEffect(.breathe)
        try await f.controller.set(.off)
        t.expect(!f.controller.animator!.isPlaying)
        t.expectEqual(f.controller.effect, .breathe)
        t.expectEqual(f.daemon.mode, 0)
    }

    t.test("pauses without relighting when the display sleeps, and resumes on wake") {
        let f = Fixture(direct: true)
        f.controller.setEffect(.heartbeat)
        f.mac.displayAwake = false
        f.daemon.log.removeAll()
        f.controller.displayDidSleep()
        t.expect(!f.controller.animator!.isPlaying)
        t.expectEqual(f.daemon.log, ["fade=0.0"])

        f.mac.displayAwake = true
        f.controller.displayDidWake()
        t.expect(f.controller.animator!.isPlaying)
        f.controller.restoreNormalLighting()
    }

    await t.test("choosing None stops the effect and fades back to the chosen brightness") {
        let f = Fixture(direct: true)
        f.controller.setEffect(.pulse)
        f.daemon.setHeld(at: 0, state: 1) // caught mid-effect, dark
        f.daemon.log.removeAll()
        f.controller.setEffect(.none)
        await settle()
        t.expect(!f.controller.animator!.isPlaying)
        t.expectEqual(f.daemon.log, ["fade=0.25", "unblank"])
        t.expect(f.daemon.lit)
    }

    t.test("restoreNormalLighting resets the fade and relights the logo") {
        let f = Fixture(direct: true)
        f.controller.setEffect(.breathe)
        f.daemon.log.removeAll()
        f.controller.restoreNormalLighting()
        t.expect(!f.controller.animator!.isPlaying)
        t.expectEqual(f.daemon.fadeDuration, 0)
        t.expect(f.daemon.lit)
        t.expectEqual(f.controller.effect, .breathe)
    }
}

@MainActor
func brightnessTests(_ t: TestHarness) async {
    print("\nBrightness")

    t.test("maps brightness to a fade level that's never dark, and even to the eye") {
        t.expectEqual(LogoAnimator.level(forBrightness: 1), 1)
        t.expectEqual(LogoAnimator.level(forBrightness: 0), 0.02)
        t.expectEqual(LogoAnimator.level(forBrightness: 2), 1)
        t.expectEqual((LogoAnimator.level(forBrightness: 0.5) * 1000).rounded() / 1000, 0.265)
        let levels = stride(from: 0.0, through: 1, by: 0.1).map(LogoAnimator.level(forBrightness:))
        t.expect(zip(levels, levels.dropFirst()).allSatisfy { $0 < $1 }, "should rise steadily")
    }

    await t.test("fades down to a level and holds it there") {
        let f = Fixture(direct: true)
        f.daemon.stepPerRead = 0.05
        f.controller.setBrightness(0.5)
        await settle()
        t.expectEqual(f.daemon.log.prefix(2).last, "blank")
        t.expectEqual(Array(f.daemon.log.suffix(2)), ["fade=1000000000.0", "unblank"])
        t.expect(abs(f.daemon.level - 0.265) <= 0.05, "held at \(f.daemon.level)")
        t.expect(f.daemon.isHolding)
    }

    await t.test("turns a held fade round before fading up from it") {
        let f = Fixture(direct: true)
        f.daemon.setHeld(at: 0.25, state: 2)
        f.controller.setBrightness(1)
        await settle()
        t.expectEqual(f.daemon.log, ["fade=1000000000.0", "blank", "fade=0.25", "unblank"])
        t.expect(f.daemon.lit)
    }

    await t.test("turns the logo on at the chosen brightness") {
        let f = Fixture(backlightMode: 0, direct: true)
        f.daemon.stepPerRead = 0.05
        f.controller.setBrightness(0.5)
        t.expect(f.daemon.log.isEmpty, "nothing to change while the logo is off")
        try await f.controller.set(.on)
        t.expectEqual(f.daemon.mode, 2)
        t.expect(abs(f.daemon.level - 0.265) <= 0.05, "held at \(f.daemon.level)")
        t.expect(f.daemon.isHolding)
    }

    await t.test("effects peak at the chosen brightness") {
        let f = Fixture(direct: true)
        f.daemon.stepPerRead = 0.05
        f.daemon.setHeld(at: 0, state: 1)
        f.clock.budget = 40
        f.controller.setBrightness(0.5)
        f.controller.setEffect(.breathe)
        await settle()
        t.expect(f.daemon.log.contains("fade=1000000000.0"), "should hold at the peak")
        t.expect(f.daemon.peak <= 0.32, "peaked at \(f.daemon.peak)")
        t.expect(f.daemon.peak >= 0.2, "peaked at \(f.daemon.peak)")
    }

    t.test("restoring normal lighting releases a held level") {
        let f = Fixture(direct: true)
        f.daemon.setHeld(at: 0.25, state: 2)
        f.daemon.fadeDuration = 1e9
        f.controller.restoreNormalLighting()
        t.expectEqual(f.daemon.log, ["fade=1000000000.0", "blank", "fade=0.0", "unblank"])
        t.expect(f.daemon.lit)
        t.expect(!f.daemon.isHolding)
    }

    t.test("the display sleeping ends the hold's endless fade duration") {
        let f = Fixture(direct: true)
        f.daemon.setHeld(at: 0.25, state: 2)
        f.daemon.fadeDuration = 1e9
        f.controller.displayDidSleep()
        t.expectEqual(f.daemon.fadeDuration, 0)
    }

    t.test("the fade curve's timing grows with the distance to cover") {
        t.expectEqual(FadeCurve.timeFraction(toReach: 0), 0.05)
        t.expect(abs(FadeCurve.timeFraction(toReach: 1) - 0.95) < 1e-9, "all the way at 95%")
        t.expect(abs(FadeCurve.timeFraction(toReach: 0.48) - 0.25) < 0.001, "48% at a quarter")
        let times = stride(from: 0.1, through: 1, by: 0.1).map { FadeCurve.timeFraction(toReach: $0) }
        t.expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "should rise steadily")
    }
}

/// Lets pending main-actor tasks (such as an effect loop) run.
@MainActor
private func settle() async {
    for _ in 0..<500 { await Task.yield() }
}
