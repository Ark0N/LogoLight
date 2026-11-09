import Foundation
import LogoLightCore

private func settle() async {
    for _ in 0..<500 { await Task.yield() }
}

/// Lets `seconds` pass on the fixture's clock while the Sound effect (or anything else) animates.
@MainActor
private func pass(_ f: Fixture, _ seconds: Double) async throws {
    let next = f.clock.now + seconds
    while f.clock.now < next - 1e-9 {
        if f.controller.animator!.isAnimating { await Task.yield() }
        else { try await f.clock.sleep(next - f.clock.now) }
    }
}

/// Lets the logo's fades run until the animator has stopped (for up to 10 s on the fixture's clock).
@MainActor
private func finish(_ f: Fixture) async {
    let deadline = f.clock.now + 10
    while f.controller.animator?.isAnimating == true, f.clock.now < deadline { await Task.yield() }
    await settle()
}

/// A fixture with the logo on and the Sound effect chosen, its fades time-driven and traced.
@MainActor
private func soundFixture(brightness: Double = 1) -> Fixture {
    let f = Fixture(direct: true, timeDriven: true)
    f.daemon.trace = []
    f.controller.setBrightness(brightness)
    return f
}

/// The RMS of a sine at `dBFS` (its peak is √2 higher).
private func rms(dBFS: Double) -> Double { pow(10, dBFS / 20) }

@MainActor
func soundTests(_ t: TestHarness) async {
    print("\nSound: the loudness meter")

    t.test("silence is 0, and a steady sound is as loud as it gets") {
        var meter = LoudnessMeter()
        for _ in 0..<50 { meter.add(rms: 0, seconds: 0.01) }
        t.expectEqual(meter.loudness, 0)
        for _ in 0..<50 { meter.add(rms: rms(dBFS: -20), seconds: 0.01) }
        t.expect(meter.loudness > 0.99, "\(meter.loudness)")
    }

    t.test("a drop of 12 dB shows as about half, and the ceiling only slowly follows it down") {
        var meter = LoudnessMeter()
        for _ in 0..<50 { meter.add(rms: rms(dBFS: -20), seconds: 0.01) }
        for _ in 0..<50 { meter.add(rms: rms(dBFS: -32), seconds: 0.01) } // 0.5 s
        t.expect(meter.loudness > 0.45 && meter.loudness < 0.6, "\(meter.loudness)")
        for _ in 0..<2000 { meter.add(rms: rms(dBFS: -32), seconds: 0.01) } // 20 s: the new normal
        t.expect(meter.loudness > 0.99, "\(meter.loudness)")
    }

    t.test("a beat shows at once and dies away quickly") {
        var meter = LoudnessMeter()
        for _ in 0..<50 { meter.add(rms: rms(dBFS: -20), seconds: 0.01) }
        for _ in 0..<30 { meter.add(rms: 0, seconds: 0.01) } // 0.3 s of silence after it
        t.expect(meter.loudness < 0.2, "after 0.3 s: \(meter.loudness)")
        meter.add(rms: rms(dBFS: -20), seconds: 0.01)
        t.expect(meter.loudness > 0.99, "on the beat: \(meter.loudness)")
    }

    t.test("quiet music fills the range too, down to the ceiling's floor") {
        var meter = LoudnessMeter()
        for _ in 0..<100 { meter.add(rms: rms(dBFS: -40), seconds: 0.01) }
        t.expect(meter.loudness > 0.99, "-40 dBFS: \(meter.loudness)")
        for _ in 0..<3000 { meter.add(rms: rms(dBFS: -51), seconds: 0.01) }
        // The ceiling stops at -45 dBFS, so this is 6 dB below it: a quarter of the 24 dB range down.
        t.expect(abs(meter.loudness - 0.75) < 0.02, "-51 dBFS: \(meter.loudness)")
        for _ in 0..<100 { meter.add(rms: rms(dBFS: -65), seconds: 0.01) }
        t.expectEqual(meter.loudness, 0)
    }

    t.test("the RMS of samples") {
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        t.expectEqual(samples.withUnsafeBufferPointer { LoudnessMeter.rms(of: $0) }, 0.5)
        t.expectEqual([Float]().withUnsafeBufferPointer { LoudnessMeter.rms(of: $0) }, 0)
    }

    print("\nSound: the follower")

    t.test("a louder sound starts a rise, which runs until the logo has caught up, then holds") {
        var follower = SoundFollower()
        t.expectEqual(follower.decide(now: 0, target: 0.5), .move(up: true, target: 0.5, time: follower.riseTime))
        t.expectEqual(follower.motion, .rising)
        t.expectEqual(follower.decide(now: 0.2, target: 0.5), .none)
        t.expectEqual(follower.decide(now: 0.4, target: 0.5), .none)
        t.expectEqual(follower.decide(now: 0.47, target: 0.5), .hold)
        t.expectEqual(follower.motion, .still)
        t.expect(follower.decide(now: 0.49, target: 0.52) == .none, "within the deadband")
    }

    t.test("a sound that drops while the logo rises turns it round, and a fall to silence ends by itself") {
        var follower = SoundFollower()
        _ = follower.decide(now: 0, target: 0.8)
        t.expectEqual(follower.decide(now: 0.4, target: 0), .move(up: false, target: 0, time: follower.fallTime))
        t.expectEqual(follower.motion, .falling)
        t.expectEqual(follower.decide(now: 0.2, target: 0), .none)
        t.expect(follower.decide(now: 0.03, target: 0) == .none, "no hold near dark: the fade ends there")
        t.expectEqual(follower.motion, .falling)
        t.expectEqual(follower.decide(now: 0, target: 0), .none)
        t.expectEqual(follower.motion, .still)
        t.expect(follower.decide(now: 0, target: 0.03) == .none, "a whisper stays dark")
    }

    t.test("a fall to a level in between holds there, and a rise to full needs no hold") {
        var follower = SoundFollower()
        t.expectEqual(follower.decide(now: 1, target: 0.3), .move(up: false, target: 0.3, time: follower.fallTime))
        t.expectEqual(follower.decide(now: 0.6, target: 0.3), .none)
        t.expectEqual(follower.decide(now: 0.33, target: 0.3), .hold)
        t.expectEqual(follower.decide(now: 0.33, target: 1), .move(up: true, target: 1, time: follower.riseTime))
        t.expectEqual(follower.decide(now: 0.97, target: 1), .none)
        t.expectEqual(follower.motion, .rising)
        t.expectEqual(follower.decide(now: 1, target: 1), .none)
        t.expectEqual(follower.motion, .still)
    }

    t.test("levels for loudness: dark for silence, the peak for full, perceptually even in between") {
        let follower = SoundFollower()
        t.expectEqual(follower.level(forLoudness: 0, peak: 0.6), 0)
        t.expectEqual(follower.level(forLoudness: 1, peak: 0.6), 0.6)
        t.expectEqual(follower.level(forLoudness: 0.5, peak: 1), 0.25)
    }

    print("\nSound: the effect")

    await t.test("choosing Sound starts listening, and the logo follows the beats") {
        let f = soundFixture()
        // Beats twice a second, each 0.12 s loud.
        f.sound.script = { $0.truncatingRemainder(dividingBy: 0.5) < 0.12 ? 1 : 0 }
        f.controller.setEffect(.sound)
        t.expectEqual(f.sound.starts, 1)
        t.expect(f.controller.animator!.isPlaying)
        try await pass(f, 3)
        let trace = f.daemon.trace ?? []
        // Peaks: the logo rose above 0.7 and fell below 0.1 again, once per beat.
        var peaks = 0, lit = false
        for sample in trace {
            if !lit, sample.level > 0.7 { lit = true; peaks += 1 }
            if lit, sample.level < 0.1 { lit = false }
        }
        t.expect(peaks >= 5 && peaks <= 6, "\(peaks) peaks in 3 s of beats at 2 Hz")
        // Each beat costs one fade toward dark (the fall), and the fade before the first beat.
        let blanks = f.daemon.log.filter { $0 == "blank" }.count
        t.expect(blanks <= 8, "\(blanks) fades toward dark for 6 beats: \(f.daemon.log)")
        t.expect(f.sound.isListening)
    }

    await t.test("a steady sound settles at the brightness and then writes nothing") {
        let f = soundFixture(brightness: 0.5)
        f.sound.level = 1
        f.controller.setEffect(.sound)
        try await pass(f, 1)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.level - level) <= 0.07, "at \(f.daemon.level), not \(level)")
        t.expect(f.daemon.isHolding)
        let written = f.daemon.log.count
        try await pass(f, 2)
        t.expectEqual(f.daemon.log.count, written)
        t.expect(abs(f.daemon.level - level) <= 0.07, "still at \(f.daemon.level)")
    }

    await t.test("at full brightness a steady sound ends fully lit, with no hold") {
        let f = soundFixture()
        f.controller.setBrightness(0.3)
        await finish(f)
        f.controller.setBrightness(1)
        f.sound.level = 1
        f.controller.setEffect(.sound)
        try await pass(f, 1)
        t.expect(f.daemon.lit, "at \(f.daemon.level)")
        t.expect(!f.daemon.isHolding)
        let written = f.daemon.log.count
        try await pass(f, 1)
        t.expectEqual(f.daemon.log.count, written)
    }

    await t.test("silence takes the logo to dark, where it stays") {
        let f = soundFixture()
        f.sound.level = 0
        f.controller.setEffect(.sound)
        try await pass(f, 1)
        t.expect(f.daemon.level <= 0.001, "at \(f.daemon.level)")
        let written = f.daemon.log.count
        try await pass(f, 1)
        t.expectEqual(f.daemon.log.count, written)
        // A beat then rises from dark: a change of state, with nothing to turn round first.
        let blanks = f.daemon.log.filter { $0 == "blank" }.count
        f.sound.level = 1
        try await pass(f, 0.3)
        t.expect(f.daemon.level > 0.9, "at \(f.daemon.level)")
        t.expectEqual(f.daemon.log.filter { $0 == "blank" }.count, blanks)
    }

    await t.test("the sound's level is squared, so half as loud is a quarter of the peak") {
        let f = soundFixture()
        f.sound.level = 0.5
        f.controller.setEffect(.sound)
        try await pass(f, 1)
        t.expect(abs(f.daemon.level - 0.25) <= 0.07, "at \(f.daemon.level)")
    }

    await t.test("another effect, turning the logo off and a display sleep stop listening; a wake resumes") {
        let f = soundFixture()
        f.sound.level = 1
        f.controller.setEffect(.sound)
        try await pass(f, 0.5)
        f.controller.setEffect(.pulse)
        t.expectEqual(f.sound.stops, 1)
        t.expect(!f.sound.isListening)
        f.controller.setEffect(.sound)
        t.expectEqual(f.sound.starts, 2)
        try await f.controller.set(.off)
        t.expect(!f.sound.isListening)
        try await f.controller.set(.on)
        await settle()
        t.expectEqual(f.sound.starts, 3)
        t.expectEqual(f.controller.effect, .sound)
        f.controller.displayDidSleep()
        t.expect(!f.sound.isListening)
        f.controller.displayDidWake()
        t.expectEqual(f.sound.starts, 4)
        t.expect(f.sound.isListening)
        f.controller.restoreNormalLighting()
        t.expect(!f.sound.isListening)
        t.expect(f.controller.effect == .sound, "kept for next time")
    }

    await t.test("a brightness change while following moves the peak") {
        let f = soundFixture(brightness: 1)
        f.sound.level = 1
        f.controller.setEffect(.sound)
        try await pass(f, 0.5)
        t.expect(f.daemon.lit)
        f.controller.setBrightness(0.5)
        try await pass(f, 1)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.level - level) <= 0.07, "at \(f.daemon.level), not \(level)")
    }

    await t.test("a Morse message takes over, and the sound comes back after it") {
        let f = soundFixture()
        f.sound.level = 1
        f.controller.setEffect(.sound)
        try await pass(f, 0.3)
        f.controller.playMorse("E", loops: false)
        t.expect(!f.sound.isListening)
        t.expectEqual(f.controller.morse?.text, "E")
        try await pass(f, 5) // the lead-in, the dot and the word gap after it take about 3.3 s
        t.expectEqual(f.controller.morse, nil)
        t.expectEqual(f.controller.effect, .sound)
        t.expect(f.sound.isListening)
    }

    await t.test("without permission to hear the sound, the effect is dropped and reported") {
        let f = soundFixture(brightness: 0.5)
        await finish(f)
        f.sound.error = SoundError.cannotListen(status: 1)
        var reported: Error?
        f.controller.onSoundFailed = { reported = $0 }
        f.controller.setEffect(.sound)
        t.expectEqual(reported as? SoundError, .cannotListen(status: 1))
        t.expectEqual(f.controller.effect, .none)
        t.expect(!f.sound.isListening)
        await finish(f)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.level - level) <= 0.02, "back at \(f.daemon.level)")
    }

    t.test("without a sound source, Sound isn't offered") {
        let f = Fixture(direct: true, timeDriven: true)
        t.expect(f.controller.canFollowSound)
        let plain = LogoController(reader: LogoStatusReader(hardware: f.mac),
                                   emitter: LightEmitter(service: f.daemon, clock: { f.daemon.time }),
                                   admin: f.admin, sudo: f.sudo, isRuleInstalled: { false },
                                   sleep: { try await f.clock.sleep($0) }, batteryCharge: { nil })
        t.expect(!plain.canFollowSound)
    }
}
