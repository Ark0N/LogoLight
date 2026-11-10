import Foundation
import IOKit
import IOKit.pwr_mgt

/// Tells when the lid closes or opens, from the power management root domain (the notification
/// corebrightnessd itself goes by). With an external display the app sees the built-in display go
/// away; without one, and the Mac kept awake, nothing else says the lid has moved.
@MainActor
final class LidObserver {
    /// `kIOPMMessageClamshellStateChange` (IOPM.h), a macro Swift doesn't import.
    private static let clamshellStateChange: UInt32 = 0xE003_4100

    private let onChange: @MainActor () -> Void
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        defer { IOObjectRelease(root) }
        IONotificationPortSetDispatchQueue(port, .main)
        // The observer lives as long as the app, so the callback's pointer to it stays good.
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, type, _ in
            guard type == LidObserver.clamshellStateChange, let context else { return }
            let observer = Unmanaged<LidObserver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observer.onChange() }
        }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
        if result == KERN_SUCCESS { self.port = port } else { IONotificationPortDestroy(port) }
    }
}

/// Keeps the Mac awake when the lid closes, with a power assertion (`PreventSystemSleep`), so the
/// logo can stay lit without an external display. macOS honours it on power only: on battery a
/// closed lid still puts the Mac to sleep. It also holds off idle sleep while it's held. The
/// assertion goes away with the process, so a crash can't leave the Mac awake in a bag.
@MainActor
final class LidSleepBlocker {
    private var assertion: IOPMAssertionID?

    var isHolding: Bool { assertion != nil }

    func set(_ holds: Bool) {
        if holds, assertion == nil {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "LogoLight keeps the logo lit with the lid closed" as CFString, &id)
            if result == kIOReturnSuccess { assertion = id }
        } else if !holds, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
