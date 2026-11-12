import Foundation
import IOKit

/// One of the Mac's display pipes: the driver behind the built-in display, or behind a port an external
/// display can be on (there whether or not one is connected).
public struct DisplayPipe: Equatable, Sendable {
    /// Its I/O Registry entry ID.
    public var id: UInt64
    public var isExternal: Bool
    /// Whether the driver dithers what it sends to the display (`enableDither`), or `nil` where it has
    /// no such switch.
    public var dithers: Bool?

    public init(id: UInt64, isExternal: Bool, dithers: Bool?) {
        self.id = id
        self.isExternal = isExternal
        self.dithers = dithers
    }
}

/// The display drivers' dithering switches (the tests have a fake).
@MainActor
public protocol DisplayPipes {
    func pipes() -> [DisplayPipe]
    /// Returns whether the driver took it.
    func setDithers(_ dithers: Bool, pipe id: UInt64) -> Bool
}

/// Disable Dithering: turns off the temporal dithering Apple silicon's display drivers add (pixels
/// switched between two colours from frame to frame, to show the shades in between), which tires some
/// people's eyes. The switch and the way to it are Stillcolor's (https://github.com/aiaf/Stillcolor,
/// MIT, by Abdullah Arif): an `enableDither` property on each display pipe in the I/O Registry, which
/// any process may set. It takes effect at once, on every display, and is back on after a restart, and
/// with a display that's connected later, so it's turned off again when the displays change.
///
/// While the choice is to leave dithering on, nothing is written, so another tool's setting stands.
@MainActor
public final class DisplayDithering {
    private let hardware: DisplayPipes
    /// The choice: whether dithering is kept off.
    public private(set) var isDisabled = false

    public init(hardware: DisplayPipes = SystemDisplayPipes()) {
        self.hardware = hardware
    }

    /// Whether any display's driver has the switch (Apple silicon).
    public var isAvailable: Bool {
        hardware.pipes().contains { $0.dithers != nil }
    }

    /// At launch, with the saved choice.
    public func start(disabled: Bool) {
        isDisabled = disabled
        reapply()
    }

    /// Turns dithering off, or back on. Returns whether every display's driver now has it so.
    @discardableResult
    public func setDisabled(_ disabled: Bool) -> Bool {
        isDisabled = disabled
        return write(dithers: !disabled)
    }

    /// Turns dithering off again wherever it has come back on, if it's kept off.
    public func reapply() {
        if isDisabled { write(dithers: false) }
    }

    /// Before the app quits: dithering is back on, as it would be after a restart without the app.
    public func restore() {
        if isDisabled { write(dithers: true) }
    }

    @discardableResult
    private func write(dithers: Bool) -> Bool {
        for pipe in hardware.pipes() where pipe.dithers == !dithers {
            _ = hardware.setDithers(dithers, pipe: pipe.id)
        }
        // Read back, rather than trusting what the calls returned.
        return hardware.pipes().allSatisfy { $0.dithers != !dithers }
    }
}

public enum DitheringError: Error, LocalizedError {
    /// The display drivers were asked, and dithering didn't change.
    case notApplied

    public var errorDescription: String? {
        "The display drivers didn't take the change. This version of macOS may not allow it."
    }
}

/// The real display pipes: every `IOMobileFramebufferAP` service, the class both of Apple silicon's
/// display drivers come from (`AppleCLCD2` on some Macs, `IOMobileFramebufferShim` on others, such as
/// the MacBook Pro). An Intel Mac has none.
public struct SystemDisplayPipes: DisplayPipes {
    private static let ditherKey = "enableDither"

    public init() {}

    public func pipes() -> [DisplayPipe] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferAP"),
                                           &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var pipes: [DisplayPipe] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            func property(_ key: String) -> Bool? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool
            }
            pipes.append(DisplayPipe(id: id, isExternal: property("external") ?? false,
                                     dithers: property(Self.ditherKey)))
        }
        return pipes
    }

    public func setDithers(_ dithers: Bool, pipe id: UInt64) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntrySetCFProperty(service, Self.ditherKey as CFString,
                                            dithers ? kCFBooleanTrue : kCFBooleanFalse) == KERN_SUCCESS
    }
}
