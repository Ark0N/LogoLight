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
        t.expectEqual(f.daemon.log, ["fade=0.01", "blank", "mode=2", "fade=1.0", "unblank", "fade=0.0", "unblank"])
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
        t.expect(f.controller.effects == nil)
        f.controller.setEffect(.breathe)
        t.expectEqual(f.controller.effect, .none)
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
        f.clock.budget = 4
        f.controller.setEffect(.breathe)
        t.expect(f.controller.effects!.isRunning)
        await settle()
        t.expectEqual(Array(f.daemon.log.prefix(8)),
                      ["fade=2.2", "blank", "fade=2.2", "unblank", "fade=2.2", "blank", "fade=2.2", "unblank"])
        t.expectEqual(f.clock.slept.prefix(2).map { ($0 * 100).rounded() / 100 }, [2.5, 3.4])
    }

    await t.test("waits for the logo to be on before playing") {
        let f = Fixture(backlightMode: 0, direct: true)
        f.controller.setEffect(.pulse)
        t.expectEqual(f.controller.effect, .pulse)
        t.expect(!f.controller.effects!.isRunning, "shouldn't play while the logo is off")
        f.clock.budget = 20
        try await f.controller.set(.on)
        t.expect(f.controller.effects!.isRunning, "should start once the logo is on")
        f.controller.restoreNormalLighting()
    }

    await t.test("stops when the logo is turned off, and keeps the choice") {
        let f = Fixture(direct: true)
        f.controller.setEffect(.breathe)
        try await f.controller.set(.off)
        t.expect(!f.controller.effects!.isRunning)
        t.expectEqual(f.controller.effect, .breathe)
        t.expectEqual(f.daemon.mode, 0)
    }

    t.test("pauses without relighting when the display sleeps, and resumes on wake") {
        let f = Fixture(direct: true)
        f.controller.setEffect(.heartbeat)
        f.mac.displayAwake = false
        f.daemon.log.removeAll()
        f.controller.displayDidSleep()
        t.expect(!f.controller.effects!.isRunning)
        t.expectEqual(f.daemon.log, ["fade=0.0"])

        f.mac.displayAwake = true
        f.controller.displayDidWake()
        t.expect(f.controller.effects!.isRunning)
        f.controller.restoreNormalLighting()
    }

    t.test("choosing None stops the effect and restores normal lighting") {
        let f = Fixture(direct: true)
        f.controller.setEffect(.pulse)
        f.daemon.log.removeAll()
        f.controller.setEffect(.none)
        t.expect(!f.controller.effects!.isRunning)
        t.expectEqual(f.daemon.log, ["fade=0.0", "unblank"])
        t.expect(f.daemon.lit)
    }

    t.test("restoreNormalLighting resets the fade and relights the logo") {
        let f = Fixture(direct: true)
        f.controller.setEffect(.breathe)
        f.daemon.log.removeAll()
        f.controller.restoreNormalLighting()
        t.expect(!f.controller.effects!.isRunning)
        t.expectEqual(f.daemon.fadeDuration, 0)
        t.expect(f.daemon.lit)
        t.expectEqual(f.controller.effect, .breathe)
    }
}

/// Lets pending main-actor tasks (such as an effect loop) run.
@MainActor
private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}
