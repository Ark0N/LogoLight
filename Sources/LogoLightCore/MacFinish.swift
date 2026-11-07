import Foundation
import IOKit
import UniformTypeIdentifiers

/// The colour of this Mac's case, so the live view can look like the real lid.
public enum MacFinish: Sendable, Equatable {
    case spaceBlack
    case silver

    /// This Mac's finish, or `nil` if it can't be told.
    ///
    /// The device tree's `chosen` node has the enclosure colour code in `housing-color`. Launch
    /// Services maps "<model>@ECOLOR=<code>" to a device type such as
    /// `com.apple.macbookpro-dynamic-island-2026-14-space-black`: the same mapping that picks this
    /// Mac's picture in System Settings. All of it is public API and needs no privileges.
    public static func current() -> MacFinish? {
        guard let model = modelIdentifier(), let data = housingColor(),
              let code = enclosureColorCode(fromHousingColor: data),
              let type = UTType(tag: "\(model)@ECOLOR=\(code)",
                                tagClass: UTTagClass(rawValue: "com.apple.device-model-code"),
                                conformingTo: nil)
        else { return nil }
        return MacFinish(deviceTypeIdentifier: type.identifier)
    }

    /// The finish named at the end of a device type identifier, e.g. `…-space-black` or `…-silver`.
    /// `nil` for anything else, including the dynamic types made up for unknown tags.
    public init?(deviceTypeIdentifier identifier: String) {
        let name = identifier.lowercased()
        if ["-space-black", "-midnight", "-space-gray", "-space-grey"].contains(where: name.hasSuffix) {
            self = .spaceBlack
        } else if ["-silver", "-starlight"].contains(where: name.hasSuffix) {
            self = .silver
        } else {
            return nil
        }
    }

    /// The enclosure colour code: the last of the little-endian 32-bit words in `housing-color`
    /// (`01 00 00 00  00 00 00 00  00 00 00 00  09 00 00 00` on a space black MacBook Pro).
    public static func enclosureColorCode(fromHousingColor data: Data) -> UInt32? {
        guard data.count >= 4, data.count % 4 == 0 else { return nil }
        return UInt32(littleEndian: data.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }

    private static func housingColor() -> Data? {
        let chosen = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
        guard chosen != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(chosen) }
        return IORegistryEntryCreateCFProperty(chosen, "housing-color" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
    }

    /// e.g. "Mac17,13".
    private static func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var name = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &name, &size, nil, 0) == 0 else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
