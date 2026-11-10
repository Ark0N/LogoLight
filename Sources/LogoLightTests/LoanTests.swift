import Darwin
import Foundation
import LogoLightCore

/// Lets pending main-actor tasks (such as an effect loop) run.
@MainActor
private func settle() async {
    for _ in 0..<500 { await Task.yield() }
}

/// Lets the fake's time run for `seconds`, or until nothing is animating if that comes first.
@MainActor
private func run(_ f: Fixture, for seconds: Double) async {
    let start = f.clock.now
    while f.controller.animator?.isAnimating == true, f.clock.now - start < seconds { await Task.yield() }
}

/// What the watcher's stand-ins answer: who has the logo, and the time.
@MainActor
private final class FakeLoan {
    var borrower: pid_t?
    var now = 0.0
    var changes = 0

    init(borrower: pid_t?) { self.borrower = borrower }

    func watcher(for controller: LogoController) -> LoanWatcher {
        let watcher = LoanWatcher(controller: controller, borrower: { [unowned self] in borrower },
                                  clock: { [unowned self] in now })
        watcher.onChange = { [unowned self] in changes += 1 }
        return watcher
    }
}

@MainActor
func loanTests(_ t: TestHarness) async {
    print("\nLending the logo to Codeman")

    await t.test("lending pauses an effect and leaves the logo alone") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .pulse)
        await run(f, for: 3)
        t.expect(f.controller.animator?.isPlaying == true, "Pulse should be playing")
        f.controller.lend()
        await settle()
        f.daemon.log.removeAll()
        f.daemon.elapse(5)
        await settle()
        t.expect(f.controller.isLent)
        t.expect(f.controller.animator?.isAnimating == false, "nothing should be animating while lent")
        t.expectEqual(f.daemon.log, [])
    }

    await t.test("an effect and a brightness chosen while lent are kept, and shown once it's back") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .none)
        await run(f, for: 3)
        f.controller.lend()
        f.daemon.log.removeAll()
        f.controller.setBrightness(0.5)
        f.controller.setEffect(.breathe)
        await settle()
        t.expectEqual(f.daemon.log, [])
        t.expectEqual(f.controller.effect, .breathe)
        t.expectEqual(f.controller.brightness, 0.5)

        f.controller.takeBack()
        await settle()
        t.expect(!f.controller.isLent)
        t.expect(f.controller.animator?.isPlaying == true, "Breathe should play once the logo is back")
        t.expect(!f.daemon.log.isEmpty, "taking the logo back should move it")
    }

    await t.test("taking it back returns to the chosen brightness") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: 0.5, effect: .none)
        await run(f, for: 3)
        f.controller.lend()
        // Codeman's last word: back to normal, fully lit, at the automatic duration.
        f.daemon.setHeld(at: 1, state: 2)
        f.daemon.fadeDuration = 0
        f.controller.takeBack()
        await run(f, for: 5)
        let level = LogoAnimator.level(forBrightness: 0.5)
        t.expect(abs(f.daemon.level - level) <= 0.02, "at \(f.daemon.level), not \(level)")
    }

    await t.test("a sleep and a wake while lent change nothing") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .heartbeat)
        await run(f, for: 3)
        f.controller.lend()
        f.daemon.log.removeAll()
        f.mac.displayAwake = false
        f.controller.displayDidSleep()
        f.mac.displayAwake = true
        f.controller.displayDidWake()
        f.controller.scheduleWake(after: 1) {}
        await settle()
        f.daemon.elapse(3)
        await settle()
        t.expectEqual(f.daemon.log, [])
        t.expect(f.controller.animator?.isAnimating == false, "the wake shouldn't resume the effect while lent")
    }

    await t.test("quitting while lent leaves the logo to Codeman") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: 0.5, effect: .pulse)
        await run(f, for: 3)
        f.controller.lend()
        f.daemon.log.removeAll()
        f.controller.restoreNormalLighting()
        await settle()
        t.expectEqual(f.daemon.log, [])
    }

    await t.test("launching while lent leaves the logo alone") {
        let f = Fixture(direct: true, timeDriven: true)
        f.daemon.setHeld(at: 0.4, state: 1) // where Codeman's blink has it
        f.controller.lend()
        f.controller.start(brightness: 0.5, effect: .pulse)
        await settle()
        f.daemon.elapse(2)
        await settle()
        t.expectEqual(f.daemon.log, [])
        t.expectEqual(f.controller.effect, .pulse)
    }

    await t.test("switching the logo off while lent changes only the setting") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .breathe)
        await run(f, for: 3)
        f.controller.lend()
        f.daemon.log.removeAll()
        let status = try await f.controller.set(.off)
        t.expectEqual(status.setting, .off)
        t.expectEqual(f.daemon.log, ["mode=0"])
        t.expect(f.admin.scripts.isEmpty, "no password dialog expected")

        // Codeman stops when it sees the logo off. Taken back, the logo stays off.
        f.controller.takeBack()
        await settle()
        t.expect(f.controller.animator?.isAnimating == false, "an effect shouldn't play with the logo off")
    }

    // MARK: - LoanWatcher

    t.test("lends while Codeman blinks, and takes the logo back once it has been free for a moment") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .pulse)
        let loan = FakeLoan(borrower: 4242)
        let watcher = loan.watcher(for: f.controller)
        watcher.check()
        t.expect(f.controller.isLent)
        t.expectEqual(loan.changes, 1)
        watcher.check()
        t.expectEqual(loan.changes, 1)

        loan.borrower = nil
        watcher.check()
        loan.now = 1
        watcher.check()
        t.expect(f.controller.isLent, "still lent \(loan.now) s after the logo was freed")
        loan.now = LoanWatcher.returnDelay
        watcher.check()
        t.expect(!f.controller.isLent, "taken back \(loan.now) s after the logo was freed")
        t.expectEqual(loan.changes, 2)
    }

    t.test("keeps the loan when Codeman goes straight on to another blink") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .none)
        let loan = FakeLoan(borrower: 4242)
        let watcher = loan.watcher(for: f.controller)
        watcher.check()
        loan.borrower = nil // between two blinks
        watcher.check()
        loan.now = 1
        loan.borrower = 4242
        watcher.check()
        loan.borrower = nil
        loan.now = 2
        watcher.check()
        loan.now = 2 + LoanWatcher.returnDelay - 0.1
        watcher.check()
        t.expect(f.controller.isLent, "the free time counts from the last blink")
        loan.now = 2 + LoanWatcher.returnDelay
        watcher.check()
        t.expect(!f.controller.isLent)
        t.expectEqual(loan.changes, 2)
    }

    t.test("does nothing while the logo is free") {
        let f = Fixture(direct: true, timeDriven: true)
        f.controller.start(brightness: nil, effect: .none)
        let loan = FakeLoan(borrower: nil)
        let watcher = loan.watcher(for: f.controller)
        watcher.check()
        watcher.check()
        t.expect(!f.controller.isLent)
        t.expectEqual(loan.changes, 0)
    }

    // MARK: - CodemanLoan

    t.test("reads the borrower from Codeman's marker") {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("logolight-loan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("logo-fade")

        t.expectEqual(CodemanLoan.borrower(markerAt: marker, isCodeman: { _ in true }), nil)
        t.expectEqual(CodemanLoan.borrower(markerAt: nil, isCodeman: { _ in true }), nil)

        try Data("4242\n".utf8).write(to: marker)
        t.expectEqual(CodemanLoan.borrower(markerAt: marker, isCodeman: { $0 == 4242 }), 4242)
        // A process that has ended, or that isn't Codeman's.
        t.expectEqual(CodemanLoan.borrower(markerAt: marker, isCodeman: { _ in false }), nil)

        // What a Codeman from before this contract leaves, and what isn't a process ID.
        for text in ["", "\n", "-3", "0", "abc", "4242 4343"] {
            try Data(text.utf8).write(to: marker)
            t.expectEqual(CodemanLoan.borrower(markerAt: marker, isCodeman: { _ in true }), nil)
        }
    }

    t.test("tells a Codeman process from others") {
        t.expect(!CodemanLoan.isCodeman(getpid()), "this test runner isn't Codeman")
        t.expect(!CodemanLoan.isCodeman(1), "launchd isn't Codeman")
        t.expect(!CodemanLoan.isCodeman(Int32.max), "no process has this ID")
    }

    t.test("says in the app's Info.plist that it steps aside for Codeman") {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        // The template's $(...) placeholders are still in it, but they're plain strings to the parser.
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        t.expectEqual(info?["LogoLightStepsAsideForCodeman"] as? Int, 1)
    }
}
