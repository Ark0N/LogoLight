import Foundation
import IOKit.ps
import notify

/// The internal battery, for the battery indicator (the logo's brightness following its charge).
public enum Battery {
    /// The charge from 0 (empty) to 1 (full), the percentage the menu bar's battery shows, or `nil` on a
    /// Mac without a battery or when it can't be read.
    public static func charge() -> Double? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool != false,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0
            else { continue }
            return min(max(Double(current) / Double(capacity), 0), 1)
        }
        return nil
    }
}

/// Calls `onChange` on the main thread when anything about a power source changes, for as long as
/// it's kept. That's more often than the percentage changes (the notification for just that is
/// private), so `onChange` should be cheap and check what changed.
@MainActor
public final class BatteryObserver {
    /// `nil` if registering failed.
    private let token: Int32?

    public init(onChange: @escaping @MainActor () -> Void) {
        var token: Int32 = 0
        let status = notify_register_dispatch(kIOPSNotifyAnyPowerSource, &token, .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
        self.token = status == NOTIFY_STATUS_OK ? token : nil
    }

    deinit {
        if let token { notify_cancel(token) }
    }
}
