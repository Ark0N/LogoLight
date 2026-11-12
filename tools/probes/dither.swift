// dither: reads, and can set, the display drivers' temporal dithering (as Stillcolor does,
// https://github.com/aiaf/Stillcolor).
//
// Each display pipe is an IOMobileFramebufferAP service in the I/O Registry (AppleCLCD2 or
// IOMobileFramebufferShim, depending on the Mac), with an `enableDither` property that can be set
// from user space, with no privileges. It takes effect at once and goes back to Yes at a restart.
//
//   ./dither            # prints each display pipe and its enableDither
//   ./dither off|on     # sets it on every pipe, and prints what each then reads
//   ./dither try        # off, reads it back, then on again after a second
//
// This changes the screen (gradients may band slightly while it's off), not the logo.
import Foundation
import IOKit

func pipes() -> [io_service_t] {
    var iterator = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferAP"), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    var services: [io_service_t] = []
    while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL { services.append(service) }
    return services
}

func property(_ key: String, _ service: io_service_t) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func describe(_ service: io_service_t) -> String {
    var className = [CChar](repeating: 0, count: 128)
    IOObjectGetClass(service, &className)
    let name = property("IONameMatched", service) as? String ?? "?"
    let external = property("external", service) as? Bool ?? false
    let dither = (property("enableDither", service) as? Bool).map { $0 ? "Yes" : "No" } ?? "missing"
    return "\(String(cString: className)) \(name) (\(external ? "external" : "built-in")): enableDither = \(dither)"
}

func set(_ enabled: Bool) {
    for service in pipes() {
        let result = IORegistryEntrySetCFProperty(service, "enableDither" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
        print("  set \(enabled ? "Yes" : "No") -> \(String(cString: mach_error_string(result))) (\(String(result, radix: 16)))")
        IOObjectRelease(service)
    }
}

func show() {
    let all = pipes()
    if all.isEmpty { print("no IOMobileFramebufferAP services") }
    for service in all {
        print(describe(service))
        IOObjectRelease(service)
    }
}

switch CommandLine.arguments.dropFirst().first {
case nil:
    show()
case "off":
    set(false); show()
case "on":
    set(true); show()
case "try":
    show()
    print("off:"); set(false); show()
    Thread.sleep(forTimeInterval: 1)
    print("on:"); set(true); show()
default:
    print("usage: dither [off|on|try]"); exit(2)
}
