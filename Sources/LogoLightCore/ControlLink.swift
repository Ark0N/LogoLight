import Foundation

/// How the Control Center control talks to the running app: through a Mach port that the app serves,
/// named after its bundle ID.
///
/// The control runs in a sandboxed extension (`Controls/`), which may look up only this one name. Its
/// entitlements, written by `scripts/build-app.sh`, say so. It never touches the logo itself: only the
/// app does, since the app also holds levels and plays effects.
///
/// This file is compiled into the extension as well, so it uses nothing else from LogoLightCore.
public enum ControlLink {
    /// The controls' kinds: the switch, and the brightness buttons. (Apple doesn't offer apps a
    /// slider in Control Center, only switches and buttons.)
    public static let backlightKind = "Backlight"
    public static let brighterKind = "Brighter"
    public static let dimmerKind = "Dimmer"
    /// How much Brighter and Dimmer change the brightness, as a share of the slider.
    public static let brightnessStep = 0.1
    /// What the extension's bundle ID adds to the app's.
    public static let extensionSuffix = ".Controls"

    /// The port's name, for the app with this bundle ID.
    public static func portName(forApp bundleID: String) -> String { bundleID + ".control" }

    public enum Request: Int32, Sendable {
        /// Only asks for the state.
        case state = 1
        case turnOn = 2
        case turnOff = 3
        /// One step brighter, turning the logo on if it's off.
        case brighter = 4
        /// One step dimmer, while the logo is on.
        case dimmer = 5
    }

    /// The brightness after a step from `brightness`: to the next multiple of `brightnessStep`
    /// that way, so a level the slider left in between lines up with the steps.
    public static func brightness(after request: Request, from brightness: Double) -> Double {
        let steps = brightness / brightnessStep
        let step: Double = switch request {
        case .brighter: (steps + 1e-6).rounded(.down) + 1
        case .dimmer: (steps - 1e-6).rounded(.up) - 1
        case .state, .turnOn, .turnOff: steps
        }
        return min(max(step * brightnessStep, 0), 1)
    }

    /// The app's answer, sent after it has started a change, not after the fade.
    public struct State: Equatable, Sendable {
        /// Whether the menu's switch shows on (the setting asked for, while a change is under way).
        public var isOn: Bool
        /// Whether this Mac has the logo.
        public var isAvailable: Bool
        /// Whether the brightness can be changed (it needs direct control).
        public var canAdjust: Bool
        /// The brightness slider's value, in whole percent.
        public var brightnessPercent: Int

        public init(isOn: Bool, isAvailable: Bool, canAdjust: Bool = false, brightness: Double = 1) {
            self.isOn = isOn
            self.isAvailable = isAvailable
            self.canAdjust = canAdjust
            brightnessPercent = Int((min(max(brightness, 0), 1) * 100).rounded())
        }

        public init?(data: Data) {
            guard data.count == 4, data[data.startIndex + 3] <= 100 else { return nil }
            let bytes = Array(data)
            self.init(isOn: bytes[0] != 0, isAvailable: bytes[1] != 0, canAdjust: bytes[2] != 0,
                      brightness: Double(bytes[3]) / 100)
        }

        public var data: Data {
            Data([isOn ? 1 : 0, isAvailable ? 1 : 0, canAdjust ? 1 : 0, UInt8(brightnessPercent)])
        }
    }

    /// How a request went.
    public enum Outcome: Equatable, Sendable {
        case answered(State)
        /// Nothing serves the port: the app isn't running (or quit before it answered).
        case notRunning
        /// The app is running but didn't answer in time, e.g. because it's showing the password dialog.
        /// The request may still be handled later, so it mustn't be sent again.
        case noAnswer
    }

    /// One request at a time in this process. CF hands every caller the same remote port for a name,
    /// and a caller that invalidates it when it's done would lose the other callers' answers.
    private static let sendLock = NSLock()

    /// Sends `request` to the app with this bundle ID. It blocks until the answer comes, for up to twice
    /// `timeout` (one wait to send, one for the answer), plus the time any other request in this
    /// process takes.
    public static func send(_ request: Request, toApp bundleID: String, timeout: Double = 1) -> Outcome {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard let port = CFMessagePortCreateRemote(nil, portName(forApp: bundleID) as CFString) else { return .notRunning }
        defer { CFMessagePortInvalidate(port) }
        var reply: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(port, request.rawValue, nil, timeout, timeout,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        let data = reply?.takeRetainedValue() as Data?
        switch result {
        case kCFMessagePortSuccess:
            return data.flatMap(State.init(data:)).map(Outcome.answered) ?? .noAnswer
        case kCFMessagePortIsInvalid, kCFMessagePortBecameInvalidError:
            return .notRunning
        default:
            // A send or receive timeout, or a transport error.
            return .noAnswer
        }
    }
}

/// Serves the control's requests in the app. It runs on the main run loop in all its common modes,
/// so it still answers while the menu is open.
@MainActor
public final class ControlLinkServer {
    public typealias Handler = @MainActor (ControlLink.Request) -> ControlLink.State

    private let handler: Handler
    private var port: CFMessagePort?

    /// Returns `nil` if the port can't be registered, e.g. because another copy of the app has it
    /// (or another server in this process).
    public init?(appBundleID: String, handler: @escaping Handler) {
        self.handler = handler
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        var shouldFreeInfo: DarwinBoolean = false
        let name = ControlLink.portName(forApp: appBundleID) as CFString
        guard let port = CFMessagePortCreateLocal(nil, name, { _, id, _, info in
            guard let info, let request = ControlLink.Request(rawValue: id) else { return nil }
            let server = Unmanaged<ControlLinkServer>.fromOpaque(info).takeUnretainedValue()
            let state = MainActor.assumeIsolated { server.handler(request) }
            return Unmanaged.passRetained(state.data as CFData)
        }, &context, &shouldFreeInfo) else { return nil }
        // In this process, the name's existing port comes back instead, without this context.
        guard !shouldFreeInfo.boolValue else { return nil }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, port, 0), .commonModes)
    }

    /// Stops serving. The port holds `self` unretained, so this has to happen before `self` goes away.
    public func invalidate() {
        if let port { CFMessagePortInvalidate(port) }
        port = nil
    }
}
