import Foundation

/// A tiny test harness, so tests run with just the Command Line Tools
/// (XCTest and swift-testing ship only with Xcode).
@MainActor
final class TestHarness {
    /// Ends the run if one test takes longer than this (the slowest takes a few seconds).
    static let testTimeout = 60.0

    private let watchdog = Watchdog(limit: TestHarness.testTimeout)
    private var passed = 0
    private var skipped = 0
    private var failed = 0
    /// Every failed expectation, for the summary (a test can have several).
    private var failures: [String] = []
    private var currentTest = ""
    private var currentTestFailed = false

    func test(_ name: String, _ body: () throws -> Void) {
        begin(name)
        do { try body(); end() } catch { handle(error) }
    }

    func test(_ name: String, _ body: () async throws -> Void) async {
        begin(name)
        do { try await body(); end() } catch { handle(error) }
    }

    /// Stops the current test and records it as skipped (e.g. the hardware isn't present).
    func skip(_ reason: String) throws -> Never {
        throw Skip(reason: reason)
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String = "",
                file: StaticString = #fileID, line: UInt = #line) {
        if !condition { fail("\(file):\(line) expectation failed. \(message())") }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                                   file: StaticString = #fileID, line: UInt = #line) {
        if actual != expected { fail("\(file):\(line) expected \(expected), got \(actual)") }
    }

    func expectThrows(file: StaticString = #fileID, line: UInt = #line, _ body: () throws -> Void) {
        do { try body(); fail("\(file):\(line) expected an error to be thrown") } catch {}
    }

    /// Prints the summary and exits with a failing status if any test failed.
    func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
        for failure in failures { print("  ✗ \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Private

    private struct Skip: Error { let reason: String }

    private func begin(_ name: String) {
        currentTest = name
        currentTestFailed = false
        watchdog.watch(name)
    }

    private func end() {
        watchdog.rest()
        guard !currentTestFailed else { return }
        passed += 1
        print("  ✓ \(currentTest)")
    }

    private func handle(_ error: Error) {
        watchdog.rest()
        if let skip = error as? Skip {
            skipped += 1
            print("  - \(currentTest) (skipped: \(skip.reason))")
        } else {
            fail("threw \(error)")
        }
    }

    private func fail(_ message: String) {
        if !currentTestFailed { failed += 1 }
        currentTestFailed = true
        failures.append("\(currentTest): \(message)")
        print("  ✗ \(currentTest): \(message)")
    }
}

/// Ends the run when a test doesn't finish, and says which one. The tests wait on a fake clock by
/// yielding, so one that waits for something that never happens spins forever on the main actor; this
/// watches from its own queue.
private final class Watchdog: @unchecked Sendable {
    private let limit: Double
    private let lock = NSLock()
    private var running: (name: String, since: DispatchTime)?
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "watchdog"))

    init(limit: Double) {
        self.limit = limit
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [self] in check() }
        timer.resume()
    }

    func watch(_ name: String) {
        lock.withLock { running = (name, .now()) }
    }

    func rest() {
        lock.withLock { running = nil }
    }

    private func check() {
        guard let running = lock.withLock({ running }) else { return }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - running.since.uptimeNanoseconds) / 1e9
        guard seconds > limit else { return }
        print("  ✗ \(running.name): still running after \(Int(limit)) s. Stopping the run here.")
        exit(1)
    }
}
