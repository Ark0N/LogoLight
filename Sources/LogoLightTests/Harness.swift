import Foundation

/// A tiny test harness, so tests run with just the Command Line Tools
/// (XCTest and swift-testing ship only with Xcode).
@MainActor
final class TestHarness {
    private var passed = 0
    private var skipped = 0
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
        print("\n\(passed) passed, \(failures.count) failed, \(skipped) skipped")
        for failure in failures { print("  ✗ \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Private

    private struct Skip: Error { let reason: String }

    private func begin(_ name: String) {
        currentTest = name
        currentTestFailed = false
    }

    private func end() {
        guard !currentTestFailed else { return }
        passed += 1
        print("  ✓ \(currentTest)")
    }

    private func handle(_ error: Error) {
        if let skip = error as? Skip {
            skipped += 1
            print("  - \(currentTest) (skipped: \(skip.reason))")
        } else {
            fail("threw \(error)")
        }
    }

    private func fail(_ message: String) {
        currentTestFailed = true
        failures.append("\(currentTest): \(message)")
        print("  ✗ \(currentTest): \(message)")
    }
}
