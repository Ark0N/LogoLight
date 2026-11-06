import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only: no Dock icon, no main menu. (The bundled app also sets LSUIElement.)
app.setActivationPolicy(.accessory)
app.run()
