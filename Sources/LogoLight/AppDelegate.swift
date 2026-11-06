import AppKit
import LogoLightCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(controller: LogoController())

        #if DEBUG
        // Opens the menu on launch, for checking the UI without clicking (debug builds only).
        if ProcessInfo.processInfo.environment["LOGOLIGHT_OPEN_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusItemController?.openMenu()
            }
        }
        #endif
    }
}
