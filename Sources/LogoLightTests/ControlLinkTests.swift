import Foundation
import LogoLightCore

/// Holds clients' answers, written on other threads.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [ControlLink.Outcome] = []
    func append(_ outcome: ControlLink.Outcome) { lock.withLock { outcomes.append(outcome) } }
    var all: [ControlLink.Outcome] { lock.withLock { outcomes } }
    var states: [ControlLink.State?] {
        all.map { if case .answered(let state) = $0 { state } else { nil } }
    }
}

/// Serves the main run loop, as the app does, until `done` or 5 s.
@MainActor
private func serve(until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !done(), Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.01, false)
    }
}

@MainActor
func controlLinkTests(_ t: TestHarness) {
    t.test("the control's answer survives the trip as data") {
        for state in [ControlLink.State(isOn: true, isAvailable: true, canAdjust: true, brightness: 0.55),
                      .init(isOn: false, isAvailable: true, canAdjust: false, brightness: 0),
                      .init(isOn: true, isAvailable: true, canAdjust: true, brightness: 1),
                      .init(isOn: false, isAvailable: false)] {
            t.expectEqual(ControlLink.State(data: state.data), state)
        }
        t.expectEqual(ControlLink.State(isOn: true, isAvailable: true, brightness: 0.554).brightnessPercent, 55)
        t.expectEqual(ControlLink.State(isOn: true, isAvailable: true, brightness: 2).brightnessPercent, 100)
        t.expect(ControlLink.State(data: Data([1, 1, 1])) == nil, "too short")
        t.expect(ControlLink.State(data: Data([1, 1, 1, 50, 0])) == nil, "too long")
        t.expect(ControlLink.State(data: Data([1, 1, 1, 101])) == nil, "over 100%")
    }

    t.test("Brighter and Dimmer step to the next tenth that way") {
        let cases: [(ControlLink.Request, Double, Double)] = [
            (.brighter, 0.5, 0.6), (.brighter, 0.55, 0.6), (.brighter, 0.95, 1), (.brighter, 1, 1),
            (.brighter, 0, 0.1), (.brighter, 0.3 - 1e-12, 0.4),
            (.dimmer, 0.5, 0.4), (.dimmer, 0.55, 0.5), (.dimmer, 0.05, 0), (.dimmer, 0, 0),
            (.dimmer, 1, 0.9), (.dimmer, 0.7 + 1e-12, 0.6),
        ]
        for (request, from, expected) in cases {
            let after = ControlLink.brightness(after: request, from: from)
            t.expect(abs(after - expected) < 1e-9, "\(request) from \(from): \(after), expected \(expected)")
        }
    }

    t.test("the port is named after the app") {
        t.expectEqual(ControlLink.portName(forApp: "app.logolight.LogoLight"), "app.logolight.LogoLight.control")
    }

    t.test("nothing answers when the app isn't running") {
        t.expectEqual(ControlLink.send(.state, toApp: "test.logolight.nobody.\(getpid())", timeout: 0.2), .notRunning)
    }

    t.test("the app's server answers each request with the state after it") {
        let app = "test.logolight.\(getpid())"
        var isOn = true
        var brightness = 0.5
        var requests: [ControlLink.Request] = []
        guard let server = ControlLinkServer(appBundleID: app, handler: { request in
            requests.append(request)
            switch request {
            case .state: break
            case .turnOn, .turnOff: isOn = request == .turnOn
            case .brighter, .dimmer: brightness = ControlLink.brightness(after: request, from: brightness)
            }
            return ControlLink.State(isOn: isOn, isAvailable: true, canAdjust: true, brightness: brightness)
        }) else { return t.expect(false, "couldn't register the port") }
        defer { server.invalidate() }
        t.expect(ControlLinkServer(appBundleID: app) { _ in .init(isOn: false, isAvailable: false) } == nil,
                 "a second copy can't take the name")

        // The client blocks, so it runs on another thread while this one serves the main run loop,
        // as the app's does.
        let answers = Answers()
        Thread.detachNewThread {
            for request in [ControlLink.Request.state, .turnOff, .state, .turnOn, .brighter] {
                answers.append(ControlLink.send(request, toApp: app))
            }
        }
        serve { answers.all.count == 5 }
        t.expectEqual(requests, [.state, .turnOff, .state, .turnOn, .brighter])
        t.expectEqual(answers.states.map { $0?.isOn }, [true, false, false, true, true])
        t.expectEqual(answers.states.map { $0?.brightnessPercent }, [50, 50, 50, 50, 60])
    }

    t.test("requests sent at once from several threads are each answered, and handled once") {
        // CF gives every caller in a process the same remote port; one that invalidated it while another
        // was waiting would lose that one's answer (and the extension would then send it again).
        let app = "test.logolight.burst.\(getpid())"
        var handled = 0
        guard let server = ControlLinkServer(appBundleID: app, handler: { _ in
            handled += 1
            usleep(5_000)
            return ControlLink.State(isOn: true, isAvailable: true)
        }) else { return t.expect(false, "couldn't register the port") }
        defer { server.invalidate() }
        let answers = Answers()
        for _ in 0..<4 {
            Thread.detachNewThread { answers.append(ControlLink.send(.brighter, toApp: app)) }
        }
        serve { answers.all.count == 4 }
        t.expectEqual(answers.all.count, 4)
        t.expect(answers.states.allSatisfy { $0 != nil }, "every request answered: \(answers.all)")
        t.expectEqual(handled, 4)
    }

    t.test("a request the app is too busy to answer comes back as no answer, not as not running") {
        let app = "test.logolight.busy.\(getpid())"
        guard let server = ControlLinkServer(appBundleID: app, handler: { _ in
            ControlLink.State(isOn: true, isAvailable: true)
        }) else { return t.expect(false, "couldn't register the port") }
        defer { server.invalidate() }
        // The main run loop isn't served meanwhile, as while the app shows the password dialog.
        let answers = Answers()
        Thread.detachNewThread { answers.append(ControlLink.send(.state, toApp: app, timeout: 0.2)) }
        let deadline = Date().addingTimeInterval(3)
        while answers.all.isEmpty, Date() < deadline { usleep(10_000) }
        t.expectEqual(answers.all, [.noAnswer])
        // Handle the late request, so it doesn't reach the next test.
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
    }
}
