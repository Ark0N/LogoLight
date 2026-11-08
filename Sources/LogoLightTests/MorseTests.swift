import Foundation
import LogoLightCore

private func settle() async {
    for _ in 0..<500 { await Task.yield() }
}

/// Yields until `condition` holds (the fake clock's sleeps return at once, so a whole message plays
/// in a few thousand turns), or gives up.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// The lit spans in a trace (above half), as (start, length) in seconds.
private func flashes(_ trace: [(time: Double, level: Double)]) -> [(start: Double, length: Double)] {
    var result: [(Double, Double)] = []
    var start: Double?
    for sample in trace {
        if sample.level > 0.5, start == nil { start = sample.time }
        if sample.level <= 0.5, let s = start {
            result.append((s, sample.time - s))
            start = nil
        }
    }
    return result
}

@MainActor
func morseTests(_ t: TestHarness) async {
    print("\nMorse code")

    t.test("encodes letters, digits and punctuation, ignoring case and unknown characters") {
        t.expectEqual(MorseCode.notation("SOS"), "... --- ...")
        t.expectEqual(MorseCode.notation("sos"), "... --- ...")
        t.expectEqual(MorseCode.notation("Hi 42!"), ".... .. / ....- ..--- -.-.--")
        t.expectEqual(MorseCode.notation("  a   b "), ".- / -...")
        t.expectEqual(MorseCode.notation("a ☃ b"), ".- / -...")
        t.expect(!MorseCode.canSend(""))
        t.expect(!MorseCode.canSend("   ☃ "))
        t.expectEqual(MorseCode.steps(for: "☃"), [])
    }

    t.test("every letter and digit has a code") {
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            t.expect(MorseCode.table[c] != nil, "\(c)")
        }
        t.expectEqual(Set(MorseCode.table.values).count, MorseCode.table.count) // no two alike
    }

    t.test("steps alternate lit and dark with the standard timing") {
        let u = 0.1, f = 0.02
        let steps = MorseCode.steps(for: "ET A", unit: u, edgeFade: f)
        t.expect(zip(steps, steps.dropFirst()).allSatisfy { $0.lit != $1.lit }, "alternates")
        t.expectEqual(steps.first?.lit, true)
        func length(_ s: FadeStep) -> Double { ((s.fade + s.hold) / u * 1000).rounded() / 1000 }
        // E: dot, letter gap; T: dash, word gap; A: dot, gap, dash, closing word gap.
        t.expectEqual(steps.map(length), [1, 3, 3, 7, 1, 1, 3, 7])
        t.expect(steps.allSatisfy { $0.fade == f && $0.hold >= 0 })
    }

    t.test("PARIS takes 50 units, the standard word") {
        let seconds = MorseCode.duration(of: "PARIS", unit: 1)
        t.expect(abs(seconds - 50) < 1e-9, "\(seconds)")
    }

    t.test("the panel's state shows which button is sending") {
        let status = LogoStatus(isSupported: true, setting: .on, source: .daemon, isLit: true, outputLevel: 0.2)
        let once = PanelState(status: status, canControlDirectly: true, effect: .none, brightness: 1,
                              morse: MorseMessage(text: "SOS", loops: false))
        t.expect(once.isSendingMorse && !once.morseLoops)
        let loop = PanelState(status: status, canControlDirectly: true, effect: .none, brightness: 1,
                              morse: MorseMessage(text: "SOS", loops: true), morseLoops: true)
        t.expect(loop.isSendingMorse && loop.morseLoops)
        let idle = PanelState(status: status, canControlDirectly: true, effect: .none, brightness: 1, morseLoops: true)
        t.expect(!idle.isSendingMorse && idle.morseLoops, "the loop switch shows while nothing is sent")
        let fallback = PanelState(status: status, canControlDirectly: false, effect: .none, brightness: 1,
                                  morse: MorseMessage(text: "SOS", loops: true))
        t.expect(!fallback.isSendingMorse, "no Morse without direct control")
    }

    await t.test("won't start with the logo off, or with nothing to send") {
        let off = Fixture(backlightMode: 0, direct: true)
        t.expect(!off.controller.playMorse("SOS", loops: false))
        t.expectEqual(off.controller.morse, nil)
        let on = Fixture(direct: true)
        t.expect(!on.controller.playMorse(" ☃ ", loops: true))
        t.expectEqual(on.controller.morse, nil)
        t.expect(!Fixture(direct: false).controller.playMorse("SOS", loops: false), "needs direct control")
    }

    await t.test("sends SOS once at full brightness with the right flash lengths, then goes back") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        t.expect(await waitUntil { !f.controller.animator!.isAnimating })
        var ended = 0
        f.controller.onMorseEnded = { ended += 1 }
        f.daemon.trace = []
        f.daemon.peak = 0
        t.expect(f.controller.playMorse("SOS", loops: false))
        t.expectEqual(f.controller.morse, MorseMessage(text: "SOS", loops: false))
        t.expect(await waitUntil { f.controller.morse == nil }, "should finish")
        t.expectEqual(ended, 1)
        t.expect(await waitUntil { !f.controller.animator!.isAnimating }, "settles at the brightness")

        let lit = flashes(f.daemon.trace ?? [])
        t.expectEqual(lit.count, 9)
        let units = lit.map { ($0.length / MorseCode.unit).rounded() }
        t.expectEqual(units, [1, 1, 1, 3, 3, 3, 1, 1, 1])
        for (flash, expected) in zip(lit, units) {
            // Each flash within a daemon frame or so of its length.
            t.expect(abs(flash.length - expected * MorseCode.unit) < 0.03, "flash of \(flash.length) s")
        }
        // Gaps: within a letter 1 unit, between letters 3.
        let gaps = zip(lit, lit.dropFirst()).map { (($1.start - $0.start - $0.length) / MorseCode.unit).rounded() }
        t.expectEqual(gaps, [1, 1, 3, 1, 1, 3, 1, 1])
        t.expect(f.daemon.peak > 0.99, "flashes at full brightness, not the slider's level")
        // Back at the chosen brightness.
        t.expect(abs((f.daemon.level) - LogoAnimator.level(forBrightness: 0.5)) < 0.03, "level \(f.daemon.level)")
    }

    await t.test("keeps every flash its length when corebrightnessd holds back each rise from dark") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.riseDelay = 0.15 // the display-ready gate, with an idle screen
        f.daemon.setHeld(at: 0, state: 1)
        f.daemon.trace = []
        t.expect(f.controller.playMorse("SOS", loops: false))
        t.expect(await waitUntil { f.controller.morse == nil }, "should finish")
        let lit = flashes(f.daemon.trace ?? [])
        t.expectEqual(lit.count, 9)
        for (flash, units) in zip(lit, [1.0, 1, 1, 3, 3, 3, 1, 1, 1]) {
            t.expect(abs(flash.length - units * MorseCode.unit) < 0.03, "a flash of \(flash.length) s, not \(units) units")
        }
        // Each gap gets longer by the delay, never shorter.
        let gaps = zip(lit, lit.dropFirst()).map { $1.start - $0.start - $0.length }
        for (gap, units) in zip(gaps, [1.0, 1, 3, 1, 1, 3, 1, 1]) {
            t.expect(gap >= units * MorseCode.unit - 0.03, "a gap of \(gap) s, under \(units) units")
        }
    }

    await t.test("starts from dark, after a word gap, when the logo is lit") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.trace = []
        f.controller.playMorse("E", loops: false)
        t.expect(await waitUntil { f.controller.morse == nil })
        let lit = flashes(f.daemon.trace ?? [])
        // The logo was lit at the start of the trace: that counts as a span, then the one dot.
        t.expectEqual(lit.count, 2)
        if lit.count == 2 {
            let darkBefore = lit[1].start - lit[0].length
            t.expect(darkBefore >= 7 * MorseCode.unit - 0.05, "dark for \(darkBefore) s first")
        }
    }

    await t.test("a loop keeps going until it's stopped, then returns to the effect") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setEffect(.pulse) // chosen beforehand, so it comes back afterwards
        f.daemon.trace = []
        t.expect(f.controller.playMorse("E", loops: true))
        // "E" is 1 lit + 7 dark units: let several passes go by.
        t.expect(await waitUntil { flashes(f.daemon.trace ?? []).count >= 5 }, "should repeat")
        t.expectEqual(f.controller.morse?.loops, true)
        t.expect(f.controller.animator!.isPlaying)
        f.controller.stopMorse()
        t.expectEqual(f.controller.morse, nil)
        t.expectEqual(f.controller.effect, .pulse)
        t.expect(f.controller.animator!.isPlaying, "Pulse plays again")
        f.controller.restoreNormalLighting()
    }

    for delay in [0.0, 0.15] {
        await t.test("a loop of SOS keeps going for many passes (rises from dark held back \(delay) s)") {
            let f = Fixture(direct: true, timeDriven: true)
            f.daemon.riseDelay = delay
            f.daemon.trace = []
            t.expect(f.controller.playMorse("SOS", loops: true))
            // A pass takes longer by a frame or two, and the delay, at each of its 9 rises.
            let pass = MorseCode.duration(of: "SOS") + 9 * (delay + 0.04)
            let start = f.clock.now
            // Five passes and the lead-in, on the fake's clock.
            t.expect(await waitUntil { f.clock.now - start > 5 * pass + 2 || !f.controller.animator!.isPlaying })
            t.expect(f.controller.animator!.isPlaying, "stopped playing after \(f.clock.now - start) s")
            t.expectEqual(f.controller.morse?.loops, true)
            let count = flashes(f.daemon.trace ?? []).count
            t.expect(count >= 5 * 9, "only \(count) flashes in five passes")
            f.controller.restoreNormalLighting()
        }
    }

    await t.test("switching the loop on while a message is sent once keeps it going") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.trace = []
        t.expect(f.controller.playMorse("E", loops: false))
        t.expect(await waitUntil { flashes(f.daemon.trace ?? []).count >= 1 })
        f.controller.setMorseLoops(true)
        // "E" is 1 lit + 7 dark units: well past the end of the first pass.
        t.expect(await waitUntil { flashes(f.daemon.trace ?? []).count >= 4 || f.controller.morse == nil })
        t.expectEqual(f.controller.morse?.loops, true)
        t.expect(f.controller.animator!.isPlaying, "still sending")
        f.controller.restoreNormalLighting()
    }

    await t.test("switching the loop off ends a message after its pass, back to the brightness") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        t.expect(await waitUntil { !f.controller.animator!.isAnimating })
        f.daemon.trace = []
        var ended = 0
        f.controller.onMorseEnded = { ended += 1 }
        t.expect(f.controller.playMorse("E", loops: true))
        t.expect(await waitUntil { flashes(f.daemon.trace ?? []).count >= 2 })
        f.controller.setMorseLoops(false)
        t.expect(await waitUntil { f.controller.morse == nil }, "should end after the pass")
        t.expectEqual(ended, 1)
        t.expectEqual(flashes(f.daemon.trace ?? []).count, 2)
        t.expect(await waitUntil { !f.controller.animator!.isAnimating })
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.level - level) < 0.03, "at \(f.daemon.level), not \(level)")
    }

    await t.test("choosing an effect stops a message") {
        let f = Fixture(direct: true, timeDriven: true)
        f.clock.budget = 50
        f.controller.playMorse("SOS", loops: true)
        f.controller.setEffect(.breathe)
        t.expectEqual(f.controller.morse, nil)
        t.expectEqual(f.controller.effect, .breathe)
        f.controller.restoreNormalLighting()
    }

    await t.test("turning the logo off drops a message sent once, but keeps a loop for when it's back on") {
        let once = Fixture(direct: true, timeDriven: true)
        var ended = 0
        once.controller.onMorseEnded = { ended += 1 }
        once.controller.playMorse("SOS", loops: false)
        try await once.controller.set(.off)
        t.expectEqual(once.controller.morse, nil)
        t.expectEqual(ended, 1)

        let loop = Fixture(direct: true, timeDriven: true)
        loop.controller.playMorse("SOS", loops: true)
        try await loop.controller.set(.off)
        t.expectEqual(loop.controller.morse?.loops, true)
        t.expect(!loop.controller.animator!.isPlaying)
        loop.clock.budget = loop.clock.slept.count + 200
        try await loop.controller.set(.on)
        t.expect(loop.controller.animator!.isPlaying, "the loop resumes")
        t.expectEqual(loop.controller.morse?.loops, true)
        loop.controller.restoreNormalLighting()
    }

    t.test("a display sleep pauses a loop, and a wake resumes it") {
        let f = Fixture(direct: true)
        f.controller.playMorse("SOS", loops: true)
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        t.expect(!f.controller.animator!.isPlaying)
        t.expectEqual(f.controller.morse?.loops, true)
        f.mac.displayAwake = true
        f.controller.displayDidWake()
        t.expect(f.controller.animator!.isPlaying)
        f.controller.restoreNormalLighting()
    }
}
