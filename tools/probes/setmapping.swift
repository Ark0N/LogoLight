import Foundation
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let client = (NSClassFromString("BrightnessSystemClient") as! NSObject.Type).init()
typealias CopyFn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
let copySel = NSSelectorFromString("copyPropertyForKey:"), setSel = NSSelectorFromString("setProperty:forKey:")
let copyImp = unsafeBitCast(client.method(for: copySel), to: CopyFn.self)
let setImp = unsafeBitCast(client.method(for: setSel), to: SetFn.self)
func get(_ k: String) -> Any? { copyImp(client, copySel, k as NSString)?.takeRetainedValue() }
func set(_ v: Any, _ k: String) -> Bool { setImp(client, setSel, v as AnyObject, k as NSString) }
func st() -> String {
    let s = get("LEPWMState") as? [String: Any] ?? [:]
    return ["PWMNitsPreRestriction", "MaxNitsRestriction", "MinNitsRestriction", "AppliedNits", "Factor", "FinalNits"].map { "\($0)=\(s[$0] ?? "-")" }.joined(separator: " ")
}
let key = CommandLine.arguments[1]
let original = get(key)!
let data = CommandLine.arguments[2].data(using: .utf8)!
let value = try JSONSerialization.jsonObject(with: data)
print("before:", st())
print("set ->", set(value, key))
print("readback:", (get(key) as AnyObject).description.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: ""))
for i in 1...10 { Thread.sleep(forTimeInterval: 0.5); print("+\(Double(i)/2)s", st()) }
print("restore ->", set(original, key))
Thread.sleep(forTimeInterval: 1)
print("after:", st())
print("readback:", (get(key) as AnyObject).description.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: ""))
