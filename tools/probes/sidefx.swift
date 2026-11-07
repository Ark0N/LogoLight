import Foundation
import CoreGraphics
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let client = (NSClassFromString("BrightnessSystemClient") as! NSObject.Type).init()
func get(_ key: String) -> Any? { client.perform(NSSelectorFromString("copyPropertyForKey:"), with: key)?.takeUnretainedValue() }
typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
let setSel = NSSelectorFromString("setProperty:forKey:")
let setImp = unsafeBitCast(client.method(for: setSel), to: SetFn.self)
func set(_ v: Int, _ k: String) { _ = setImp(client, setSel, NSNumber(value: v), k as NSString) }
func line(_ label: String) {
    let st = get("LEPWMState") as? [String: Any] ?? [:]
    let display = get("DisplayBrightness").map { "\($0)".replacingOccurrences(of: "\n", with: " ").prefix(60) } ?? "nil"
    print("\(label.padding(toLength: 22, withPad: " ", startingAt: 0)) mode=\(get("LEBacklightMode") ?? "?") factor=\(st["Factor"] ?? "?") final=\(st["FinalNits"] ?? "?") screenAsleep=\(CGDisplayIsAsleep(CGMainDisplayID()) != 0) displayBrightness=\(display)")
}
line("baseline")
set(1, "DisplayLogicalState"); Thread.sleep(forTimeInterval: 0.8); line("logo Blank")
set(2, "DisplayLogicalState"); Thread.sleep(forTimeInterval: 0.8); line("logo Unblank")
set(1, "LEBacklightMode"); Thread.sleep(forTimeInterval: 1.2); line("mode 1")
set(2, "LEBacklightMode"); Thread.sleep(forTimeInterval: 1.2); line("mode 2 (restored)")
