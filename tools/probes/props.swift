import Foundation
import ObjectiveC

dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let cls = NSClassFromString("BrightnessSystemClient") as! NSObject.Type
let client = cls.init()
for key in CommandLine.arguments.dropFirst() {
    let value = client.perform(NSSelectorFromString("copyPropertyForKey:"), with: key)?.takeUnretainedValue()
    let text = value.map { "\($0)" } ?? "nil"
    print("== \(key): \(text.count > 1500 ? String(text.prefix(1500)) + "…" : text)")
}
