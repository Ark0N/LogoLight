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

    t.test("Breathe and Pulse rise more slowly than they fall, and Heartbeat keeps a quick rhythm") {
        for effect in [LogoEffect.breathe, .pulse] {
            let rise = effect.cycle.first { $0.lit }!, fall = effect.cycle.first { !$0.lit }!
            t.expect(rise.fade > fall.fade, "\(effect)")
        }
        let period = LogoEffect.heartbeat.cycle.reduce(0) { $0 + $1.fade + $1.hold }
        t.expect(abs(period - 1.55) < 0.01, "a beat every \(period) s")
    }

    t.test("an effect's cycle can start with a rise or a fall") {
        for effect in LogoEffect.allCases where effect != .none {
            for lit in [true, false] {
                let turned = effect.cycle(startingLit: lit)
                t.expectEqual(turned.first?.lit, lit)
                let twice = effect.cycle + effect.cycle
                t.expect(effect.cycle.indices.contains { Array(twice[$0..<$0 + turned.count]) == turned },
                         "\(effect) should keep its steps in order")
            }
        }
    }

    await t.test("turning on with an effect starts it from dark, with a rise") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        f.controller.setEffect(.breathe)
        f.clock.budget = 3
        try await f.controller.set(.on)
        await settle()
        let rise = LogoEffect.breathe.cycle(startingLit: true)[0]
        let afterSwitchingOn = Array(f.daemon.log.drop(while: { $0 != "mode=2" }).dropFirst())
        t.expectEqual(Array(afterSwitchingOn.prefix(2)), ["fade=\(rise.fade)", "unblank"])
        t.expect(!f.daemon.log.contains("fade=1.0"), "no separate fade in before the effect")
    }

    await t.test("an effect restarts with a fall when a wake has relit the logo") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        f.controller.setEffect(.pulse)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.daemon.setHeld(at: 1, state: 2) // corebrightnessd relights the logo on wake
        f.mac.displayAwake = true
        f.daemon.log.removeAll()
        f.clock.budget = 2
        f.controller.displayDidWake()
        await settle()
        let fall = LogoEffect.pulse.cycle(startingLit: false)[0]
        // The heading is unknown after a wake, so it turns round first (ignored here).
        t.expectEqual(Array(f.daemon.log.prefix(4)), ["fade=1000000000.0", "unblank", "fade=\(fall.fade)", "blank"])
    }

    await t.test("plays the effect's steps in a loop") {
        let f = Fixture(direct: true)
        f.clock.budget = 8
        f.controller.setEffect(.breathe)
        t.expect(f.controller.animator!.isPlaying)
        await settle()
        t.expectEqual(Array(f.daemon.log.prefix(10)),
                      ["fade=1000000000.0", "unblank", // the heading isn't known yet
                       "fade=2.0", "blank", "fade=3.5", "unblank", "fade=2.0", "blank", "fade=3.5", "unblank"])
        t.expectEqual(Array(f.clock.slept.prefix(4)), [2.0, 0.5, 3.5, 0.3])
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

    await t.test("stops when the display goes away without a sleep notification, and keeps the choice") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setEffect(.pulse)
        await settle()
        f.mac.displayAwake = false // e.g. the lid closed with an external display attached
        await settle()
        t.expect(!f.controller.animator!.isPlaying)
        let count = f.daemon.log.count
        await settle()
        t.expectEqual(f.daemon.log.count, count)
        t.expectEqual(f.controller.effect, .pulse)
    }

    await t.test("choosing None stops the effect and fades back to the chosen brightness") {
        let f = Fixture(direct: true)
        f.controller.setEffect(.pulse)
        f.daemon.setHeld(at: 0, state: 1) // caught mid-effect, dark
        f.daemon.log.removeAll()
        f.controller.setEffect(.none)
        await settle()
        t.expect(!f.controller.animator!.isPlaying)
        // With the slower transition, so the logo doesn't snap on from dark.
        t.expectEqual(f.daemon.log, ["fade=1000000000.0", "blank", "fade=0.8", "unblank"])
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

    await t.test("turning on at a brightness fades once, with no correction after") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        try await f.controller.set(.on)
        let count = f.daemon.log.count
        await settle()
        t.expectEqual(f.daemon.log.count, count)
        t.expect(!f.controller.animator!.isAnimating)
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

    await t.test("animates only while a fade runs or an effect plays") {
        let f = Fixture(direct: true, timeDriven: true)
        let animator = f.controller.animator!
        t.expect(!animator.isAnimating)
        f.controller.setBrightness(0.5)
        t.expect(animator.isAnimating)
        await settle()
        t.expect(!animator.isAnimating, "done once the level is held")
        f.controller.setEffect(.heartbeat)
        t.expect(animator.isAnimating)
        f.controller.displayDidSleep()
        t.expect(!animator.isAnimating)
    }

    await t.test("a 60 Hz slider drag ends on target, with few stops on the way") {
        for (from, to) in [(0.8, 0.2), (0.2, 0.8)] {
            let f = Fixture(direct: true, timeDriven: true)
            f.controller.setBrightness(from)
            await settle()
            f.daemon.log.removeAll()
            for i in 1...60 {
                f.controller.setBrightness(from + (to - from) * Double(i) / 60)
                // A 60th of a second passes. While the logo fades, its own polls pass the time.
                let next = f.clock.now + 1.0 / 60
                while f.clock.now < next {
                    if f.controller.animator!.isAnimating { await Task.yield() }
                    else { try await f.clock.sleep(next - f.clock.now) }
                }
            }
            await settle()
            let target = LogoAnimator.level(forBrightness: to)
            t.expect(abs(f.daemon.level - target) <= 0.01, "\(from) to \(to): ended at \(f.daemon.level), not \(target)")
            t.expect(f.daemon.isHolding)
            // Every new fade (and every hold) is a direction flip. Restarting at each step, as
            // this used to, took 14 or 15.
            let flips = f.daemon.log.filter { $0 == "blank" || $0 == "unblank" }.count
            t.expect(flips <= 6, "\(from) to \(to): \(flips) flips")
        }
    }

    await t.test("changes during a fade end on the newest value") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.8)
        for _ in 0..<5 { await Task.yield() }
        f.controller.setBrightness(0.6)
        for _ in 0..<5 { await Task.yield() }
        f.controller.setBrightness(0.5)
        await settle()
        let target = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.level - target) <= 0.02, "held at \(f.daemon.level), not \(target)")
        t.expect(f.daemon.isHolding)
    }

    await t.test("a held level comes back after the display sleeps and wakes") {
        // This models what corebrightnessd is assumed to do, which hasn't been traced on the
        // MacBook yet: blank the logo with the display, and relight it fully on wake.
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        await settle()
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.daemon.setHeld(at: 0, state: 1)
        f.mac.displayAwake = true
        f.daemon.setHeld(at: 1, state: 2)
        f.controller.displayDidWake()
        await settle()
        t.expect(abs(f.daemon.level - 0.265) <= 0.02, "held at \(f.daemon.level)")
        t.expect(f.daemon.isHolding)
        t.expectEqual(f.daemon.keyboardState, 2)
    }

    await t.test("a drag that turns round ends on the newest value") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.3)
        for _ in 0..<10 { await Task.yield() }
        t.expect(f.daemon.level < 0.99 && f.daemon.level > 0.3, "should be part way down: \(f.daemon.level)")
        f.controller.setBrightness(0.9)
        await settle()
        let target = LogoAnimator.level(forBrightness: 0.9)
        t.expect(abs(f.daemon.level - target) <= 0.02, "held at \(f.daemon.level), not \(target)")
        t.expect(f.daemon.isHolding)
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
        f.clock.budget = 4 // from dark it starts with a rise, and stops during the second dark step
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

    await t.test("handles a scheduled wake once, after the delay, however often it's asked for") {
        let f = Fixture(direct: true)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.mac.displayAwake = true
        let wakes = Counter()
        f.controller.scheduleWake(after: 1) { wakes.count += 1 }
        f.controller.scheduleWake(after: 1) { wakes.count += 1 }
        t.expectEqual(f.daemon.keyboardState, 1) // not yet
        await settle()
        t.expectEqual(wakes.count, 1)
        t.expectEqual(f.daemon.keyboardState, 2)
        t.expect(f.clock.slept.contains(1), "should wait with the injected sleep")
    }

    await t.test("the display sleeping again cancels a scheduled wake") {
        let f = Fixture(direct: true)
        f.controller.setEffect(.pulse)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.mac.displayAwake = true
        let wakes = Counter()
        f.controller.scheduleWake(after: 1) { wakes.count += 1 }
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        await settle()
        t.expectEqual(wakes.count, 0)
        t.expect(!f.controller.animator!.isAnimating)
        t.expectEqual(f.daemon.keyboardState, 1)
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

@MainActor
func launchTests(_ t: TestHarness) async {
    print("\nLaunch")

    await t.test("after a run killed while holding a level reached going up, goes straight to the saved level") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.setHeld(at: 0.5, state: 1) // held in Blank
        f.daemon.fadeDuration = 1e9
        f.daemon.setKeyboardValue(2, forKey: "DisplayLogicalState") // which is what reads back
        f.controller.start(brightness: 0.3, effect: .none)
        f.daemon.elapse(0.02) // the rest of the app's launch, before anything else runs
        await settle()
        let level = LogoAnimator.level(forBrightness: 0.3)
        t.expect(abs(f.daemon.level - level) <= 0.02, "held at \(f.daemon.level), not \(level)")
        t.expect(f.daemon.isHolding)
        t.expect(f.daemon.peak <= 0.501, "went up to \(f.daemon.peak) first")
    }

    await t.test("after a run killed while holding a level reached going down, goes straight to the saved level") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.setHeld(at: 0.265, state: 2) // held in Unblank
        f.daemon.fadeDuration = 1e9
        f.controller.start(brightness: 0.8, effect: .none)
        f.daemon.elapse(0.02) // the rest of the app's launch, before anything else runs
        await settle()
        let level = LogoAnimator.level(forBrightness: 0.8)
        t.expect(abs(f.daemon.level - level) <= 0.02, "held at \(f.daemon.level), not \(level)")
        t.expect(f.daemon.isHolding)
        t.expect(f.daemon.peak <= level + 0.03, "went up to \(f.daemon.peak) first")
    }

    await t.test("with an effect chosen, starts playing it") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.setHeld(at: 0.265, state: 2)
        f.daemon.fadeDuration = 1e9
        f.clock.budget = 4
        f.controller.start(brightness: 0.5, effect: .breathe)
        t.expect(f.controller.animator!.isPlaying)
        t.expectEqual(f.controller.effect, .breathe)
        await settle()
        t.expect(f.daemon.log.contains("blank") && f.daemon.log.contains("unblank"), "should fade both ways")
    }

    t.test("at full brightness with no effect, returns the logo to normal") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.setHeld(at: 0.265, state: 2)
        f.daemon.fadeDuration = 1e9
        f.controller.start(brightness: 1, effect: .none)
        t.expectEqual(f.daemon.fadeDuration, 0)
        t.expectEqual(f.daemon.state, 2)
        t.expectEqual(f.daemon.log.last, "unblank")
    }

    t.test("with the logo off, only ends a leftover hold and keeps the choices") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        f.daemon.fadeDuration = 1e9
        f.controller.start(brightness: 0.5, effect: .pulse)
        t.expect(!f.controller.animator!.isAnimating)
        t.expectEqual(f.daemon.fadeDuration, 0)
        t.expectEqual(f.controller.effect, .pulse)
        t.expectEqual(f.controller.brightness, 0.5)
    }

    t.test("without a saved brightness, keeps full brightness") {
        let f = Fixture(direct: true)
        f.controller.start(brightness: nil, effect: .none)
        t.expectEqual(f.controller.brightness, 1)
        t.expectEqual(f.daemon.fadeDuration, 0)
    }
}

@MainActor
func switchingTests(_ t: TestHarness) async {
    print("\nSwitching on and off while other things happen")

    await t.test("records an effect and a brightness chosen while switching off") {
        let f = Fixture(direct: true, timeDriven: true)
        let midway = Midway()
        midway.run(f, when: { $0 == 1.0 }) {
            f.controller.setEffect(.breathe)
            f.controller.setBrightness(0.3)
        }
        try await f.controller.set(.off)
        await settle()
        t.expect(midway.ran && !midway.animated, "nothing should start during the switch")
        t.expect(!f.controller.animator!.isAnimating)
        t.expectEqual(f.controller.effect, .breathe)
        t.expectEqual(f.controller.brightness, 0.3)
        t.expectEqual(f.daemon.log, ["fade=1000000000.0", "unblank", "fade=1.0", "blank", "mode=0", "fade=0.0", "unblank"])
    }

    await t.test("plays an effect chosen while switching on, once it's on") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        let midway = Midway()
        midway.run(f, when: { _ in f.daemon.mode == 2 }) { f.controller.setEffect(.pulse) }
        try await f.controller.set(.on)
        t.expect(midway.ran && !midway.animated, "nothing should start during the switch")
        t.expect(f.controller.animator!.isPlaying)
        f.controller.restoreNormalLighting()
    }

    await t.test("fades to a brightness chosen while switching on, once it's on") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        let midway = Midway()
        midway.run(f, when: { _ in f.daemon.mode == 2 }) { f.controller.setBrightness(0.5) }
        try await f.controller.set(.on)
        await settle()
        t.expect(midway.ran && !midway.animated, "nothing should start during the switch")
        t.expect(abs(f.daemon.level - 0.265) <= 0.02, "held at \(f.daemon.level)")
        t.expect(f.daemon.isHolding)
    }

    await t.test("a wake while switching off doesn't restart the effect") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setEffect(.breathe)
        let midway = Midway()
        midway.run(f, when: { $0 == 1.0 }) { f.controller.displayDidWake() }
        try await f.controller.set(.off)
        await settle()
        t.expect(midway.ran && !midway.animated, "nothing should start during the switch")
        // After the wake the heading isn't known, so restoring turns the logo round first
        // (ignored, as it's already in Blank).
        t.expectEqual(f.daemon.log, ["fade=1000000000.0", "unblank", "fade=1.0", "blank", "mode=0",
                                     "fade=1000000000.0", "blank", "fade=0.0", "unblank"])
    }

    await t.test("a wake while switching on lets the switch finish first") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        let midway = Midway()
        midway.run(f, when: { $0 == 0.01 && f.daemon.mode == 2 }) { f.controller.displayDidWake() }
        try await f.controller.set(.on)
        await settle()
        t.expect(midway.ran && !midway.animated, "nothing should start during the switch")
        t.expect(abs(f.daemon.level - 0.265) <= 0.02, "held at \(f.daemon.level)")
    }

    await t.test("the display sleeping while switching on leaves the keyboard dark and no hold") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        let midway = Midway()
        midway.run(f, when: { $0 == 0.01 && f.daemon.mode == 2 }) {
            f.mac.displayAwake = false
            f.controller.displayDidSleep()
        }
        try await f.controller.set(.on)
        await settle()
        t.expect(midway.ran)
        t.expectEqual(f.daemon.mode, 2)
        t.expectEqual(f.daemon.keyboardState, 1)
        t.expectEqual(f.daemon.fadeDuration, 0)
        t.expect(!f.controller.animator!.isAnimating)
    }
}

@MainActor
private final class Counter {
    var count = 0
}

/// Does something once, part way through an operation: during the first sleep that matches.
@MainActor
private final class Midway {
    private(set) var ran = false
    /// Whether the animator was running just after the action.
    private(set) var animated = false

    func run(_ f: Fixture, when condition: @escaping @MainActor (Double) -> Bool,
             _ action: @escaping @MainActor () -> Void) {
        let elapse = f.clock.onSleep
        f.clock.onSleep = { [self] seconds in
            elapse?(seconds)
            guard !ran, condition(seconds) else { return }
            ran = true
            action()
            animated = f.controller.animator?.isAnimating ?? false
        }
    }
}
