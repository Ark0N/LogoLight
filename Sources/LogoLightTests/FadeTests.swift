import Foundation
import LogoLightCore

/// Lets pending main-actor tasks (such as a fade's polls) run.
@MainActor
private func settle() async {
    for _ in 0..<500 { await Task.yield() }
}

/// Lets `seconds` pass on the fixture's clock. While the logo fades, its own polls pass the time.
@MainActor
private func pass(_ f: Fixture, _ seconds: Double) async throws {
    let next = f.clock.now + seconds
    while f.clock.now < next - 1e-9 {
        if f.controller.animator!.isAnimating { await Task.yield() }
        else { try await f.clock.sleep(next - f.clock.now) }
    }
}

/// Does something once, during the `n`th sleep that matches a condition, after its time has passed.
@MainActor
private final class AtSleep {
    private(set) var ran = false
    /// How long the daemon's log was just after the action.
    private(set) var logCount = 0

    init(_ f: Fixture, number n: Int, when condition: @escaping @MainActor () -> Bool = { true },
         _ action: @escaping @MainActor () -> Void) {
        let elapse = f.clock.onSleep
        var seen = 0
        f.clock.onSleep = { [self, daemon = f.daemon] seconds in
            elapse?(seconds)
            guard !ran, condition() else { return }
            seen += 1
            guard seen == n else { return }
            ran = true
            action()
            logCount = daemon.log.count
        }
    }
}

@MainActor
func fadeTests(_ t: TestHarness) async {
    print("\nFades: stopping, holding and following")

    await t.test("a fade cancelled by the display sleeping, as its sleep ends, writes nothing more") {
        // Task.sleep returns normally when it's cancelled after its time is up. Every poll of the
        // fade is tried, including the one where the rise passes its level and holds it.
        var tried = 0
        for n in 1... {
            let f = Fixture(direct: true, timeDriven: true)
            f.clock.returnsWhenCancelledLate = true
            f.daemon.setHeld(at: 0.05, state: 1)
            let race = AtSleep(f, number: n) {
                f.mac.displayAwake = false
                f.controller.displayDidSleep()
            }
            f.controller.setBrightness(0.5)
            await settle()
            guard race.ran else { break }
            tried += 1
            t.expectEqual(Array(f.daemon.log.dropFirst(race.logCount)), [])
            t.expectEqual(f.daemon.fadeDuration, 0)
            t.expectEqual(f.daemon.keyboardState, 1)
        }
        t.expect(tried > 10, "only \(tried) polls")
    }

    await t.test("the switch's fade in, cancelled the same way, leaves the keyboard dark and no hold") {
        var tried = 0
        for n in 1... {
            let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
            f.clock.returnsWhenCancelledLate = true
            f.controller.setBrightness(0.5)
            let race = AtSleep(f, number: n, when: { f.daemon.mode == 2 }) {
                f.mac.displayAwake = false
                f.controller.displayDidSleep()
            }
            try await f.controller.set(.on)
            await settle()
            guard race.ran else { break }
            tried += 1
            let after = f.daemon.log.dropFirst(race.logCount)
            t.expect(!after.contains("unblank"), "poll \(n): relit after the sleep: \(Array(after))")
            t.expectEqual(f.daemon.keyboardState, 1)
            t.expectEqual(f.daemon.fadeDuration, 0)
        }
        t.expect(tried > 10, "only \(tried) polls")
    }

    await t.test("a nudge at the top of the slider and straight back ends fully lit, not held") {
        for nudge in [0.99, 0.97, 0.95] {
            for frames in 1...4 {
                let f = Fixture(direct: true, timeDriven: true)
                f.controller.setBrightness(nudge)
                try await pass(f, Double(frames) / 60)
                f.controller.setBrightness(1)
                await settle()
                f.daemon.elapse(5)
                let label = "\(nudge) for \(frames) frames"
                t.expect(f.daemon.level >= 0.999, "\(label): stuck at \(f.daemon.level)")
                t.expect(!f.daemon.isHolding, "\(label): left at the hold's duration")
            }
        }
    }

    await t.test("a jump down and straight back to full ends fully lit, not held") {
        for polls in 1...6 {
            let f = Fixture(direct: true, timeDriven: true)
            f.controller.setBrightness(0.68)
            while f.clock.slept.count < polls { await Task.yield() }
            f.controller.setBrightness(1)
            await settle()
            f.daemon.elapse(5)
            t.expect(f.daemon.level >= 0.999, "after \(polls) polls: stuck at \(f.daemon.level)")
            t.expect(!f.daemon.isHolding, "after \(polls) polls: left at the hold's duration")
        }
    }
}
