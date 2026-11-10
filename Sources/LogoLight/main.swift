import AppKit

// The lid guard (see `LidSleepBlocker`): no app, it only waits for the app that started it to exit.
if let index = CommandLine.arguments.firstIndex(of: LidSleep.guardArgument),
   CommandLine.arguments.indices.contains(index + 1), let pid = pid_t(CommandLine.arguments[index + 1]) {
    LidSleep.runGuard(for: pid)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only: no Dock icon, no main menu. (The bundled app also sets LSUIElement.)
app.setActivationPolicy(.accessory)

// Quit through AppKit on `kill`/`pkill` (as `make run`, `install` and `uninstall` do), Ctrl-C and a
// closed terminal, so the logo is returned to normal first (`applicationWillTerminate`). By default
// these signals end the process on the spot. Kept here so the sources live as long as the app.
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    source.resume()
    return source
}

app.run()
