import AppKit
import LogoLightCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Draws the control panel to PNGs and quits, without touching the logo (debug builds only).
        if let folder = ProcessInfo.processInfo.environment["LOGOLIGHT_RENDER_PANEL"] {
            PanelRenderer.render(to: folder)
            NSApp.terminate(nil)
            return
        }
        #endif

        var makeController: @MainActor () -> LogoController = { LogoController.live() }
        #if DEBUG
        // A pretend logo, shown in the menu's live view, for Macs without one (debug builds only).
        if ProcessInfo.processInfo.environment["LOGOLIGHT_SIMULATE"] != nil { makeController = { LogoController.simulated() } }
        #endif
        statusItemController = StatusItemController(controller: makeController())

        #if DEBUG
        // Opens the menu on launch, for checking the UI without clicking (debug builds only).
        if ProcessInfo.processInfo.environment["LOGOLIGHT_OPEN_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusItemController?.openMenu()
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.prepareToQuit()
    }
}
