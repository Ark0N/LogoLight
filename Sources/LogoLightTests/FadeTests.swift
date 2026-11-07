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

@MainActor
func fadeTests(_ t: TestHarness) async {
    print("\nFades: stopping, holding and following")

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
