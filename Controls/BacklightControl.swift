import AppIntents
import AppKit
import SwiftUI
import WidgetKit

// The Control Center controls (macOS 26 and later), which can also be placed in the menu bar: a switch
// for the logo, and Brighter and Dimmer buttons. Apple doesn't let apps add a slider to Control
// Center, only switches and buttons. They run in this sandboxed extension, which can't touch the logo,
// so they ask the running LogoLight over `ControlLink` (Sources/LogoLightCore/ControlLink.swift,
// compiled in too). scripts/build-app.sh builds it into LogoLight.app/Contents/PlugIns.

@main
struct LogoLightControls: WidgetBundle {
    var body: some Widget {
        BacklightControl()
        BrightnessSliderControl()
        BrighterControl()
        DimmerControl()
    }
}

// MARK: - Backlight

struct BacklightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlLink.backlightKind, provider: BacklightValue()) { isOn in
            ControlWidgetToggle(isOn: isOn, action: SetBacklightIntent()) {
                Label("Backlight", systemImage: isOn ? "lightbulb.fill" : "lightbulb.slash")
            }
            .tint(.blue)
        }
        .displayName("Backlight")
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
    static let title: LocalizedStringResource = "Turn Backlight On or Off"
    static let description = IntentDescription("Turns the logo on the back of the lid on or off, through LogoLight.")

    @Parameter(title: "Backlight")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        // LogoLight drops a change it can't take yet (it's waiting for a password or `sudo`), and
        // answers with the switch as it is.
        guard try await ContainingApp.ask(value ? .turnOn : .turnOff).isOn == value else { throw ControlError.busy }
        return .result()
    }
}

// MARK: - Brighter and Dimmer

struct BrighterControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlLink.brighterKind, provider: BrightnessValue()) { percent in
            ControlWidgetButton(action: BrighterIntent()) {
                BrightnessLabel(title: "Brighter", symbol: "sun.max.fill", percent: percent)
            }
        }
        .displayName("Backlight Brighter")
        .description("Makes the logo brighter, and turns it on if it's off.")
    }
}

struct DimmerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlLink.dimmerKind, provider: BrightnessValue()) { percent in
            ControlWidgetButton(action: DimmerIntent()) {
                BrightnessLabel(title: "Dimmer", symbol: "sun.min", percent: percent)
            }
        }
        .displayName("Backlight Dimmer")
        .description("Makes the logo dimmer.")
    }
}

/// Opens LogoLight's menu, with its brightness slider: Apple doesn't let apps put a slider in
/// Control Center itself.
struct BrightnessSliderControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlLink.sliderKind, provider: BrightnessValue()) { percent in
            ControlWidgetButton(action: ShowSliderIntent()) {
                BrightnessLabel(title: "Brightness", symbol: "slider.horizontal.below.sun.max", percent: percent)
            }
        }
        .displayName("Backlight Brightness")
        .description("Opens LogoLight's brightness slider, under the menu bar.")
    }
}

struct ShowSliderIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Backlight Brightness"
    static let description = IntentDescription("Opens LogoLight's menu, with its brightness slider.")

    func perform() async throws -> some IntentResult {
        _ = try await ContainingApp.ask(.showMenu)
        return .result()
    }
}

/// A button's title, with the brightness under it.
struct BrightnessLabel: View {
    let title: String
    let symbol: String
    /// The brightness in percent, or `nil` if it isn't known (LogoLight isn't running) or can't be
    /// changed.
    let percent: Int?

    var body: some View {
        Label {
            Text(title)
            if let percent { Text("\(percent)%") }
        } icon: {
            Image(systemName: symbol)
        }
    }
}

/// The brightness the buttons show.
struct BrightnessValue: ControlValueProvider {
    var previewValue: Int? { 100 }

    func currentValue() async throws -> Int? {
        guard let state = await ContainingApp.currentState(), state.canAdjust else { return nil }
        return state.brightnessPercent
    }
}

struct BrighterIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Backlight Brighter"
    static let description = IntentDescription("Makes the logo on the back of the lid brighter, through LogoLight.")

    func perform() async throws -> some IntentResult {
        try await ContainingApp.adjust(.brighter)
        return .result()
    }
}

struct DimmerIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Backlight Dimmer"
    static let description = IntentDescription("Makes the logo on the back of the lid dimmer, through LogoLight.")

    func perform() async throws -> some IntentResult {
        try await ContainingApp.adjust(.dimmer)
        return .result()
    }
}

// MARK: - Talking to LogoLight

enum ControlError: Error, CustomLocalizedStringResourceConvertible {
    case notResponding
    case busy
    case unavailable
    case cantAdjust

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notResponding: "LogoLight didn't respond. Open LogoLight and try again."
        case .busy: "LogoLight is busy, e.g. waiting for your password. Try again in a moment."
        case .unavailable: "This Mac has no illuminated logo."
        case .cantAdjust: "LogoLight can't change the brightness on this Mac."
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

    /// Asks for a brightness step.
    static func adjust(_ request: ControlLink.Request) async throws {
        guard try await ask(request).canAdjust else { throw ControlError.cantAdjust }
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
