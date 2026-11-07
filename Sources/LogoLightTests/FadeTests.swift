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

/// The logo's motion, as the time-driven fake traced it (every millisecond).
private struct Motion {
    let trace: [(time: Double, level: Double)]

    init(_ trace: [(time: Double, level: Double)]?) {
        self.trace = trace ?? []
    }

    /// The level at `time`: the last sample at or before it.
    func level(at time: Double) -> Double {
        var low = 0, high = trace.count
        while low < high {
            let middle = (low + high) / 2
            if trace[middle].time <= time + 1e-9 { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? trace.first?.level ?? 0 : trace[low - 1].level
    }

    /// The average speed over `window` seconds up to `time`.
    func speed(before time: Double, over window: Double) -> Double {
        abs(level(at: time) - level(at: time - window)) / window
    }

    /// When the logo last moved before `time`.
    func stop(before time: Double = .infinity) -> Double {
        var last = trace.first?.time ?? 0
        for (previous, sample) in zip(trace, trace.dropFirst()) where sample.time < time {
            if abs(sample.level - previous.level) > 1e-7 { last = sample.time }
        }
        return last
    }

    /// The fastest it moved between `start` and `end`, over one of the daemon's frames (17.5 ms).
    func peakSpeed(from start: Double = 0, to end: Double = .infinity) -> Double {
        trace.filter { $0.time >= start + 0.0175 && $0.time <= end }
            .map { speed(before: $0.time, over: 0.0175) }.max() ?? 0
    }
}

/// Settles the logo at one brightness, then moves the slider to another in one change (as a
/// click does), and lets it settle again. The fixture's daemon has the move's trace and writes.
@MainActor
private func click(from: Double, to: Double) async throws -> Fixture {
    let f = Fixture(direct: true, timeDriven: true)
    f.controller.setBrightness(from)
    await settle()
    try await pass(f, 0.5)
    f.daemon.trace = []
    f.daemon.timeline.removeAll()
    f.controller.setBrightness(to)
    await settle()
    try await pass(f, 1.5)
    return f
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

    await t.test("the slider clicked at the bottom, then at 0.65 0.09 s later, lands on 0.65's level") {
        // The logo is falling fast when the second click arrives, only just above the new level.
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0)
        try await pass(f, 0.09)
        f.controller.setBrightness(0.65)
        await settle()
        try await pass(f, 3)
        let target = LogoAnimator.level(forBrightness: 0.65)
        t.expect(!f.controller.animator!.isAnimating, "should have settled")
        t.expect(abs(f.daemon.level - target) <= 0.02, "held at \(f.daemon.level), not \(target)")
        t.expect(f.daemon.isHolding)
    }

    await t.test("two slider clicks 0.05 to 0.15 s apart always land within 0.02") {
        var worst = (error: 0.0, label: "")
        for delay in stride(from: 0.05, through: 0.15, by: 0.02) {
            for brightness in stride(from: 0.3, through: 0.75, by: 0.05) {
                let f = Fixture(direct: true, timeDriven: true)
                f.controller.setBrightness(0)
                try await pass(f, delay)
                f.controller.setBrightness(brightness)
                await settle()
                try await pass(f, 3)
                let error = abs(f.daemon.level - LogoAnimator.level(forBrightness: brightness))
                if error > worst.error { worst = (error, "after \(delay) s, \(brightness)") }
            }
        }
        t.expect(worst.error <= 0.02, "\(worst.label) landed \(worst.error) off")
    }

    await t.test("a followed target that's missed is tried once more, so the adjust loop ends") {
        for step in [0.05, 0.1, 0.2] {
            let f = Fixture(direct: true)
            f.daemon.stepPerRead = step
            f.controller.setBrightness(0.6)
            for _ in 0..<3 { await Task.yield() }
            f.controller.setBrightness(0.5)
            await settle()
            t.expect(!f.controller.animator!.isAnimating, "step \(step): still fading")
        }
    }

    await t.test("a slow fade starts again when the target jumps further than it can catch up with") {
        let daemon = FakeDaemon()
        daemon.timeDriven = true
        daemon.stepPerRead = 0
        let clock = FakeClock()
        clock.onSleep = { [daemon] in daemon.elapse($0) }
        let emitter = LightEmitter(service: daemon)
        var target = 0.7
        var reads = 0
        // The 0.8 s transition's stretched fade toward 0.7, then the target drops to 0.05.
        let result = try await emitter.fade(following: {
            reads += 1
            if reads == 5 { target = 0.05 }
            return target
        }, over: 0.8, sleep: { try await clock.sleep($0) })
        t.expect(result == nil, "should stop short for a new fade, got \(String(describing: result))")
        t.expect(clock.now < 0.1, "crawled for \(clock.now) s")
    }

    await t.test("with the heading unknown, a fade within reach of its target is frozen either way") {
        for (state, from) in [(1, 0.6), (2, 0.3)] {
            let daemon = FakeDaemon()
            daemon.timeDriven = true
            daemon.stepPerRead = 0
            daemon.setHeld(at: from, state: 3 - state)
            _ = daemon.setValue(2, forKey: "LEPWMFactorFadeDuration")
            _ = daemon.setValue(NSNumber(value: state), forKey: "DisplayLogicalState") // fading
            daemon.elapse(0.1)
            let at = daemon.level
            let clock = FakeClock()
            clock.onSleep = { [daemon] in daemon.elapse($0) }
            let emitter = LightEmitter(service: daemon) // a fresh one: the heading isn't known
            try await emitter.fade(to: at + (state == 1 ? 0.002 : -0.002), over: 0.25,
                                   sleep: { try await clock.sleep($0) })
            daemon.elapse(10)
            t.expect(abs(daemon.level - at) < 0.01, "heading for \(state): moved from \(at) to \(daemon.level)")
        }
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

@MainActor
func stoppingTests(_ t: TestHarness) async {
    print("\nEffects and switching: stopping")

    await t.test("an effect replaced by another can still be stopped") {
        // The replaced effect's task ends after the new one has started. It mustn't clear the
        // new one's handle, or nothing could cancel it.
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setEffect(.pulse)
        for _ in 0..<20 { await Task.yield() }
        f.controller.setEffect(.breathe)
        for _ in 0..<50 { await Task.yield() }
        t.expect(f.controller.animator!.isPlaying, "Breathe should still count as playing")
        f.controller.setEffect(.none)
        f.controller.displayDidSleep()
        let count = f.daemon.log.count
        await settle()
        t.expectEqual(f.daemon.log.count, count)
    }

    await t.test("the display sleeping during the dark start of turning on stops the fade in") {
        let f = Fixture(backlightMode: 0, direct: true, timeDriven: true)
        f.controller.setBrightness(0.5)
        let race = AtSleep(f, number: 1, when: { f.clock.slept.last == 0.05 }) {
            f.mac.displayAwake = false
            f.controller.displayDidSleep()
        }
        try await f.controller.set(.on)
        await settle()
        t.expect(race.ran)
        t.expectEqual(f.daemon.keyboardState, 1)
        // Nothing after the setting changes starts a fade toward the level: no Unblank, and no
        // duration but the hold's (or 0).
        let after = f.daemon.log.drop(while: { $0 != "mode=2" }).dropFirst()
        t.expect(!after.isEmpty && !after.contains("unblank"), "relit: \(Array(after))")
        t.expect(after.allSatisfy { !$0.hasPrefix("fade=") || $0 == "fade=1000000000.0" || $0 == "fade=0.0" },
                 "started a fade: \(Array(after))")
    }
}

@MainActor
func landingTests(_ t: TestHarness) async {
    print("\nFades: easing onto a level")

    t.test("the spring's inverse gives the share of a fade it takes to cover a share of the way") {
        for share in [0.0005, 0.01, 0.1, 0.5, 0.9, 0.99] {
            let s = FadeCurve.springTime(toReach: share)
            t.expect(abs(FadeCurve.springProgress(s) - share) < 1e-6, "\(share): \(s)")
        }
        // The spring's top speed is at 0.154 of the fade.
        t.expect(abs(FadeCurve.springTime(toReach: FadeCurve.springProgress(0.154)) - 0.154) < 1e-6)
    }

    await t.test("slider clicks both ways ease onto the level, and stop slowly") {
        for (from, to) in [(1.0, 0.5), (0.5, 0.9), (0.9, 0.4), (0.3, 0.8), (0.8, 0.2), (0.2, 0.3), (0.6, 0.55)] {
            let f = try await click(from: from, to: to)
            let target = LogoAnimator.level(forBrightness: to)
            let motion = Motion(f.daemon.trace)
            let stop = motion.stop()
            let peak = motion.peakSpeed()
            let atStop = motion.speed(before: stop, over: 0.06)
            let fades = f.daemon.timeline.filter { $0.entry.hasPrefix("fade=") && $0.entry != "fade=1000000000.0" }
            let flips = f.daemon.timeline.filter { $0.entry == "blank" || $0.entry == "unblank" }
            let label = "\(from) to \(to)"
            t.expect(abs(f.daemon.level - target) <= 0.01, "\(label): held at \(f.daemon.level), not \(target)")
            t.expect(f.daemon.isHolding, "\(label): not held")
            t.expect(atStop < 0.25 * peak, "\(label): \(atStop)/s in the last 60 ms, peak \(peak)/s")
            // The stretched fade, then at most 6 segments. Each starts with a turn-round, and
            // the hold ends it.
            t.expect(fades.count >= 2, "\(label): didn't ease on")
            t.expect(fades.count <= 1 + 6, "\(label): \(fades.count) fades")
            t.expect(flips.count <= 2 + 2 * 6 + 1, "\(label): \(flips.count) flips")
        }
    }

    await t.test("moves to full brightness stay one plain fade") {
        let f = try await click(from: 0.5, to: 1)
        let fades = f.daemon.timeline.filter { $0.entry.hasPrefix("fade=") && $0.entry != "fade=1000000000.0" }
        t.expectEqual(fades.map(\.entry), ["fade=0.25"])
        t.expect(f.daemon.lit && !f.daemon.isHolding)
    }

    await t.test("a drag follows without easing on until the slider stops") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.setBrightness(0.9)
        await settle()
        try await pass(f, 0.5)
        f.daemon.timeline.removeAll()
        var lastChange = 0.0
        for i in 1...45 {
            lastChange = f.daemon.time
            f.controller.setBrightness(0.9 - 0.6 * Double(i) / 45)
            try await pass(f, 1.0 / 60)
        }
        await settle()
        try await pass(f, 1.5)
        let fades = f.daemon.timeline.filter { $0.entry.hasPrefix("fade=") && $0.entry != "fade=1000000000.0" }
        let during = fades.filter { $0.time <= lastChange }.count
        // Following carries one fade along (a couple when it can't keep up); easing on would
        // start several, then stop short at the next change.
        t.expect(during <= 3, "\(during) fades during the drag")
        t.expect(fades.count - during >= 2, "didn't ease on at the end")
        let target = LogoAnimator.level(forBrightness: 0.3)
        t.expect(abs(f.daemon.level - target) <= 0.01, "held at \(f.daemon.level), not \(target)")
    }

    await t.test("a change while easing on stops it, and the logo goes to the new level") {
        for change in 1...4 {
            let f = Fixture(direct: true, timeDriven: true)
            f.controller.setBrightness(0.9)
            await settle()
            try await pass(f, 0.5)
            f.daemon.timeline.removeAll()
            f.daemon.trace = []
            f.controller.setBrightness(0.4)
            // Wait for the `change`th segment of the ease-out.
            let fades = { f.daemon.timeline.filter { $0.entry.hasPrefix("fade=") && $0.entry != "fade=1000000000.0" } }
            while fades().count < 1 + change, f.controller.animator!.isAnimating { await Task.yield() }
            t.expect(fades().count == 1 + change, "only \(fades().count - 1) segments")
            let changedAt = (time: f.daemon.time, level: f.daemon.level)
            f.controller.setBrightness(0.6)
            await settle()
            try await pass(f, 1.5)
            let target = LogoAnimator.level(forBrightness: 0.6)
            t.expect(!f.controller.animator!.isAnimating, "after segment \(change): still fading")
            t.expect(abs(f.daemon.level - target) <= 0.01, "after segment \(change): held at \(f.daemon.level), not \(target)")
            // It turns toward the new level at once, instead of finishing the old one first.
            let lowest = f.daemon.trace!.filter { $0.time >= changedAt.time }.map(\.level).min() ?? 0
            t.expect(lowest > changedAt.level - 0.02, "after segment \(change): went on from \(changedAt.level) to \(lowest)")
        }
    }

    await t.test("an effect's peak below full eases on, and the effect keeps its rhythm") {
        for effect in [LogoEffect.breathe, .pulse, .heartbeat] {
            let f = Fixture(direct: true, timeDriven: true)
            f.controller.setBrightness(0.5)
            await settle()
            try await pass(f, 0.5)
            f.daemon.trace = []
            f.daemon.timeline.removeAll()
            f.controller.setEffect(effect)
            let period = effect.cycle.reduce(0) { $0 + $1.fade + $1.hold }
            try await pass(f, 4.5 * period)
            f.controller.restoreNormalLighting()
            // Each cycle's last fall (a plain fade all the way, at the step's own duration).
            let fall = effect.cycle.last { !$0.lit }!
            let falls = f.daemon.timeline.filter { $0.entry == "fade=\(fall.fade)" }.map(\.time)
            let cycles = zip(falls, falls.dropFirst()).map { $1 - $0 }
            let motion = Motion(f.daemon.trace)
            let stops = falls.dropFirst().map { motion.stop(before: $0 - 0.0001) }
            // The speed in the last 60 ms before each peak's stop, against the fastest the logo
            // moved in the cycle before it.
            let ratios = stops.map { stop in
                motion.speed(before: stop, over: 0.06) / motion.peakSpeed(from: stop - period, to: stop)
            }
            t.expect(cycles.count >= 3, "\(effect): \(cycles.count) cycles")
            t.expect(ratios.allSatisfy { $0 < 0.25 }, "\(effect): stopped at \(ratios) of the peak")
            if effect == .heartbeat {
                // Its holds after the beats (0.05 s) can't make up for easing on (about 0.2 s
                // a beat), so at this brightness it beats about 0.26 s slower than at full.
                t.expect(cycles.allSatisfy { $0 >= period - 0.1 && $0 <= period + 0.3 },
                         "\(effect): cycles of \(cycles), not about \(period)")
            } else {
                t.expect(cycles.allSatisfy { abs($0 - period) <= 0.1 }, "\(effect): cycles of \(cycles), not \(period)")
            }
        }
    }
}
