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
        // A new emitter doesn't know which way the logo is heading, so it turns it round at the
        // hold duration first. Here that's ignored, as the logo is already in Unblank.
        t.expectEqual(f.daemon.log, ["fade=1000000000.0", "unblank", "fade=1.0", "blank", "mode=0", "fade=0.0", "unblank"])
        t.expectEqual(f.clock.slept, [1.0])
        t.expect(f.admin.scripts.isEmpty, "no password dialog expected")
    }

    await t.test("turns the logo on from dark, then fades it in") {
        let f = Fixture(backlightMode: 0, direct: true)
        let status = try await f.controller.set(.on)
        t.expectEqual(status.setting, .on)
        t.expectEqual(f.daemon.log, ["fade=1000000000.0", "unblank", "fade=0.05", "blank", "mode=2",
                                     "fade=1.0", "unblank", "fade=0.0", "unblank"])
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
        t.expectEqual(Array(f.daemon.log.prefix(10)),
                      ["fade=1000000000.0", "unblank", // the heading isn't known yet
                       "fade=2.2", "blank", "fade=2.2", "unblank", "fade=2.2", "blank", "fade=2.2", "unblank"])
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
        t.expectEqual(f.daemon.log, ["fade=1000000000.0", "blank", "fade=0.25", "unblank"])
        t.expect(f.daemon.lit)
    }

    await t.test("choosing None just after an effect's fall began stays at the brightness") {
        for brightness in [0.5, 1] {
            let f = Fixture(direct: true, timeDriven: true)
            let level = LogoAnimator.level(forBrightness: brightness)
            f.daemon.setHeld(at: level, state: level < 1 ? 1 : 2)
            f.controller.setBrightness(brightness)
            await settle()
            f.clock.budget = 0 // the effect stops at its first sleep, and its fall carries on
            f.controller.setEffect(.breathe)
            await settle()
            t.expectEqual(f.daemon.state, 1)
            f.daemon.elapse(0.005)
            f.clock.budget = .max
            f.controller.setEffect(.none)
            await settle()
            f.daemon.elapse(10)
            t.expect(abs(f.daemon.level - level) < 0.005, "brightness \(brightness): \(level) became \(f.daemon.level)")
        }
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
        t.expectEqual(f.daemon.log.prefix(4).last, "blank") // after turning round, as the heading isn't known
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

    await t.test("turns the logo on at the chosen brightness by fading straight up from dark") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        try await f.controller.set(.on)
        let afterSwitchingOn = Array(f.daemon.log.drop(while: { $0 != "mode=2" }).dropFirst())
        t.expectEqual(afterSwitchingOn.prefix(2).last, "unblank")
        t.expect(abs(f.daemon.level - 0.265) <= 0.01, "held at \(f.daemon.level)")
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

    await t.test("keeps the keyboard lit while fading the logo out") {
        let f = Fixture(direct: true)
        try await f.controller.set(.off)
        t.expectEqual(f.daemon.keyboardState, 2)
    }

    await t.test("keeps the keyboard lit while a level is held after fading up") {
        let f = Fixture(direct: true)
        f.daemon.stepPerRead = 0.05
        f.daemon.setHeld(at: 0.05, state: 2)
        f.controller.setBrightness(0.5)
        await settle()
        t.expectEqual(f.daemon.state, 1) // a level reached going up is held in Blank
        t.expectEqual(f.daemon.keyboardState, 2)
    }

    await t.test("moves down from a level it reached going up") {
        // Held in Blank, with the keyboard told Unblank, which is what reads back.
        let f = Fixture(direct: true)
        f.daemon.stepPerRead = 0.05
        f.daemon.setHeld(at: 0.05, state: 2)
        f.controller.setBrightness(0.5)
        await settle()
        let held = f.daemon.level
        f.controller.setBrightness(0.3)
        await settle()
        t.expect(f.daemon.level < held - 0.1, "moved from \(held) to \(f.daemon.level)")
        t.expectEqual(f.daemon.keyboardState, 2)
    }

    await t.test("moves from a level held in Blank after the display wakes") {
        // Reading DisplayLogicalState back would say Unblank (the keyboard's), and a Blank
        // would then be ignored as a repeat, leaving the logo stuck.
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.setHeld(at: 0.05, state: 2)
        f.controller.setBrightness(0.5)
        await settle()
        t.expectEqual(f.daemon.state, 1)
        f.controller.displayDidWake()
        await settle()
        f.controller.setBrightness(0.45)
        await settle()
        let target = LogoAnimator.level(forBrightness: 0.45)
        t.expect(abs(f.daemon.level - target) <= 0.01, "held at \(f.daemon.level), not \(target)")
    }

    await t.test("effects keep moving when the peak is a held level") {
        let f = Fixture(direct: true)
        f.daemon.setHeld(at: 0, state: 1)
        f.clock.budget = 3 // stops during the second dark step
        f.controller.setBrightness(0.5)
        f.controller.setEffect(.pulse)
        await settle()
        t.expectEqual(f.daemon.level, 0)
    }

    await t.test("keeps the keyboard lit through an effect") {
        let f = Fixture(direct: true)
        f.clock.budget = 5 // stops during the second dark step
        f.controller.setEffect(.breathe)
        await settle()
        t.expectEqual(f.daemon.state, 1)
        t.expectEqual(f.daemon.keyboardState, 2)
    }

    t.test("lets the keyboard go dark with the display, and relights it on wake") {
        let f = Fixture(direct: true)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        t.expectEqual(f.daemon.keyboardState, 1)
        f.mac.displayAwake = true
        f.controller.displayDidWake()
        t.expectEqual(f.daemon.keyboardState, 2)
        f.controller.restoreNormalLighting()
    }

    t.test("doesn't relight the keyboard on a wake that leaves the display off") {
        let f = Fixture(direct: true)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.controller.displayDidWake()
        t.expectEqual(f.daemon.keyboardState, 1)
    }

    t.test("releasing a level with the display off doesn't relight the keyboard") {
        let f = Fixture(direct: true)
        f.daemon.setHeld(at: 0.25, state: 2)
        f.mac.displayAwake = false
        f.controller.restoreNormalLighting()
        t.expectEqual(f.daemon.keyboardState, 1)
    }

    await t.test("doesn't start animating when turned on with the display off") {
        let f = Fixture(backlightMode: 0, direct: true)
        f.mac.displayAwake = false
        f.controller.setEffect(.pulse)
        try await f.controller.set(.on)
        t.expect(!f.controller.animator!.isPlaying)
        t.expectEqual(f.daemon.keyboardState, 2)
    }

    t.test("the live glow reads the real fade level, scaled like the slider") {
        let f = Fixture(direct: true)
        t.expectEqual(f.controller.liveGlow, 1)
        f.daemon.setHeld(at: 0.25, state: 2)
        t.expectEqual(f.controller.liveGlow, 0.5)
        f.daemon.setHeld(at: 0, state: 1)
        t.expectEqual(f.controller.liveGlow, 0)
    }

    t.test("the live glow is dark while the setting is off, whatever the fade level") {
        let f = Fixture(backlightMode: 0, direct: true)
        t.expectEqual(f.daemon.level, 1)
        t.expectEqual(f.controller.liveGlow, 0)
    }

    t.test("the live glow still works without direct control") {
        t.expectEqual(Fixture().controller.liveGlow, 1)
        t.expectEqual(Fixture(backlightMode: 0).controller.liveGlow, 0)
    }

    t.test("the fade curve's timing grows with the distance to cover") {
        t.expectEqual(FadeCurve.timeFraction(toReach: 0), 0.05)
        t.expect(abs(FadeCurve.timeFraction(toReach: 1) - 0.95) < 1e-9, "all the way at 95%")
        t.expect(abs(FadeCurve.timeFraction(toReach: 0.48) - 0.25) < 0.001, "48% at a quarter")
        let times = stride(from: 0.1, through: 1, by: 0.1).map { FadeCurve.timeFraction(toReach: $0) }
        t.expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "should rise steadily")
    }

    t.test("the time-driven fake fades along the hardware's curve, from rest, and holds") {
        let daemon = FakeDaemon()
        daemon.timeDriven = true
        daemon.stepPerRead = 0
        daemon.setHeld(at: 0, state: 1)
        _ = daemon.setValue(2, forKey: "LEPWMFactorFadeDuration")
        _ = daemon.setValue(2, forKey: "DisplayLogicalState")
        daemon.elapse(0.5)
        t.expect(abs(daemon.level - 0.48) < 0.03, "a quarter of the way in: \(daemon.level)")
        daemon.elapse(1.5)
        t.expectEqual(daemon.level, 1)

        daemon.setHeld(at: 0.6, state: 2)
        _ = daemon.setValue(2, forKey: "DisplayLogicalState") // already Unblank: ignored
        daemon.elapse(1)
        t.expectEqual(daemon.level, 0.6)
        _ = daemon.setValue(1, forKey: "DisplayLogicalState")
        daemon.elapse(0.01)
        t.expect(daemon.level > 0.599, "a new fade starts from rest: \(daemon.level)")
        _ = daemon.setValue(1e9, forKey: "LEPWMFactorFadeDuration")
        _ = daemon.setValue(2, forKey: "DisplayLogicalState")
        let held = daemon.level
        daemon.elapse(100)
        t.expect(abs(daemon.level - held) < 1e-6, "held, but moved from \(held) to \(daemon.level)")
    }
}

/// Lets pending main-actor tasks (such as an effect loop) run.
@MainActor
private func settle() async {
    for _ in 0..<500 { await Task.yield() }
}
