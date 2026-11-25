import Foundation
import IOKit
import IOKit.pwr_mgt

/// Tells when the lid closes or opens, from the power management root domain (the notification
/// corebrightnessd itself goes by). With an external display the app sees the built-in display go
/// away; without one, and the Mac kept awake, nothing else says the lid has moved.
///
/// The kernel sends the same message when the Mac is plugged in or unplugged. Each one says whether
/// a closed lid puts the Mac to sleep as things stand (`causesSleep`), the only time the kernel says
/// so: nothing reads lid sleep back in between (see `LidSleepBlocker`).
@MainActor
final class LidObserver {
    /// `kIOPMMessageClamshellStateChange` (IOPM.h), a macro Swift doesn't import.
    private static let clamshellStateChange: UInt32 = 0xE003_4100
    /// `kClamshellSleepBit` (IOPM.h) in the message's argument: closing the lid causes sleep.
    private static let clamshellSleepBit: UInt = 1 << 1

    private let onChange: @MainActor (_ causesSleep: Bool) -> Void
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(onChange: @escaping @MainActor (_ causesSleep: Bool) -> Void) {
        self.onChange = onChange
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        defer { IOObjectRelease(root) }
        IONotificationPortSetDispatchQueue(port, .main)
        // The observer lives as long as the app, so the callback's pointer to it stays good.
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, type, argument in
            guard type == LidObserver.clamshellStateChange, let context else { return }
            let observer = Unmanaged<LidObserver>.fromOpaque(context).takeUnretainedValue()
            let causesSleep = UInt(bitPattern: argument) & LidObserver.clamshellSleepBit != 0
            MainActor.assumeIsolated { observer.onChange(causesSleep) }
        }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
        if result == KERN_SUCCESS { self.port = port } else { IONotificationPortDestroy(port) }
    }
}
