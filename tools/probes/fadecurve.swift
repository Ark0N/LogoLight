import Foundation
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let client = (NSClassFromString("BrightnessSystemClient") as! NSObject.Type).init()
typealias CopyFn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
let copySel = NSSelectorFromString("copyPropertyForKey:"), setSel = NSSelectorFromString("setProperty:forKey:")
let copyImp = unsafeBitCast(client.method(for: copySel), to: CopyFn.self)
let setImp = unsafeBitCast(client.method(for: setSel), to: SetFn.self)
func get(_ k: String) -> Any? { copyImp(client, copySel, k as NSString)?.takeRetainedValue() }
@discardableResult func set(_ v: Double, _ k: String) -> Bool { setImp(client, setSel, NSNumber(value: v), k as NSString) }
func factor() -> Double { ((get("LEPWMState") as? [String: Any])?["Factor"] as? NSNumber)?.doubleValue ?? -1 }
func trace(_ label: String, _ seconds: Double) {
    let t0 = Date(); var line = label + ":"
    while Date().timeIntervalSince(t0) < seconds {
        line += String(format: " %.2f", factor()); Thread.sleep(forTimeInterval: 0.1)
    }
    print(line)
}
print("DisplayLogicalState readable:", get("DisplayLogicalState") as Any, " fade:", get("LEPWMFactorFadeDuration") as Any)
set(2, "LEPWMFactorFadeDuration"); set(1, "DisplayLogicalState"); trace("blank 2s from 1 (0.1s steps)", 2.3)
set(2, "LEPWMFactorFadeDuration"); set(2, "DisplayLogicalState")
let t0 = Date(); while factor() < 0.5 { Thread.sleep(forTimeInterval: 0.01) }
print(String(format: "unblank 2s: 0 -> 0.5 took %.2fs", Date().timeIntervalSince(t0)))
set(1e9, "LEPWMFactorFadeDuration"); print("1e9 accepted, readback:", get("LEPWMFactorFadeDuration") as Any); set(1, "DisplayLogicalState")
trace("held (1e9)", 2)
set(2, "LEPWMFactorFadeDuration"); set(2, "DisplayLogicalState"); trace("unblank 2s from held", 2.3)
set(0.5, "LEPWMFactorFadeDuration"); set(1, "DisplayLogicalState"); Thread.sleep(forTimeInterval: 0.05); set(2, "DisplayLogicalState")
Thread.sleep(forTimeInterval: 0.8); set(0, "LEPWMFactorFadeDuration")
print("restored factor:", factor())
