import AppIntents
import AppKit
import SwiftUI
import WidgetKit

// The Control Center control (macOS 26 and later): one switch for the logo, which can also be placed in
// the menu bar. It runs in this sandboxed extension, which can't touch the logo, so it asks the running
// LogoLight over `ControlLink` (Sources/LogoLightCore/ControlLink.swift, compiled in too).
// scripts/build-app.sh builds it into LogoLight.app/Contents/PlugIns.

@main
struct LogoLightControls: WidgetBundle {
    var body: some Widget {
        BacklightControl()
    }
}

// MARK: - Backlight

struct BacklightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlLink.kind, provider: BacklightValue()) { isOn in
            ControlWidgetToggle(isOn: isOn, action: SetBacklightIntent()) {
                Label("LogoLight", systemImage: isOn ? "lightbulb.fill" : "lightbulb.slash")
            }
            .tint(.blue)
        }
        .displayName("LogoLight")
        .description("Turns the logo on the back of the lid on or off.")
    }
}

/// What the switch shows: the app's switch, or while the app isn't running, what it showed last.
struct BacklightValue: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        // The logo is lit unless something turned it off.
        await ContainingApp.currentState()?.isOn ?? true
    }
}

struct SetBacklightIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn LogoLight On or Off"
    static let description = IntentDescription("Turns the logo on the back of the lid on or off, through LogoLight.")

    @Parameter(title: "LogoLight")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        // LogoLight drops a change it can't take yet (it's waiting for a password or `sudo`), and
        // answers with the switch as it is.
        guard try await ContainingApp.ask(value ? .turnOn : .turnOff).isOn == value else { throw ControlError.busy }
        return .result()
    }
}

// MARK: - Talking to LogoLight

enum ControlError: Error, CustomLocalizedStringResourceConvertible {
    case notResponding
    case busy
    case unavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notResponding: "LogoLight didn't respond. Open LogoLight and try again."
        case .busy: "LogoLight is busy, e.g. waiting for your password. Try again in a moment."
        case .unavailable: "This Mac has no illuminated logo."
        }
    }
}

/// LogoLight, the app this extension is inside.
enum ContainingApp {
    /// The extension's bundle ID without `ControlLink.extensionSuffix`.
    static var bundleID: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return id.hasSuffix(ControlLink.extensionSuffix) ? String(id.dropLast(ControlLink.extensionSuffix.count)) : id
    }

    /// LogoLight.app, three levels up from LogoLight.app/Contents/PlugIns/LogoLightControls.appex.
    static var url: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// What LogoLight says, or while it isn't running, what it said last (`nil` if never).
    static func currentState() async -> ControlLink.State? {
        guard case .answered(let state) = ControlLink.send(.state, toApp: bundleID) else { return lastKnownState }
        lastKnownState = state
        return state
    }

    /// Sends `request` to LogoLight and returns its answer. If LogoLight isn't running, it's opened in
    /// the background first, and the request is sent once it's there (for up to 5 s). A request that
    /// reached LogoLight but wasn't answered in time isn't sent again: it may still be handled.
    static func ask(_ request: ControlLink.Request) async throws -> ControlLink.State {
        var outcome = ControlLink.send(request, toApp: bundleID)
        if outcome == .notRunning {
            let deadline = ContinuousClock.now + .seconds(5)
            await open()
            while outcome == .notRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
                outcome = ControlLink.send(request, toApp: bundleID)
            }
        }
        switch outcome {
        case .answered(let state):
            guard state.isAvailable else { throw ControlError.unavailable }
            lastKnownState = state
            return state
        case .notRunning:
            throw ControlError.notResponding
        case .noAnswer:
            throw ControlError.busy
        }
    }

    /// What LogoLight last said, kept in the extension's own defaults for when it isn't running.
    private static var lastKnownState: ControlLink.State? {
        get { (UserDefaults.standard.data(forKey: "LastKnownState")).flatMap(ControlLink.State.init(data:)) }
        set { UserDefaults.standard.set(newValue?.data, forKey: "LastKnownState") }
    }

    /// Opens LogoLight without bringing it to the front, and returns once it has launched (or failed to).
    private static func open() async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                continuation.resume()
            }
        }
    }
}
