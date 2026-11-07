import Foundation
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let client = (NSClassFromString("BrightnessSystemClient") as! NSObject.Type).init()
let v = client.perform(NSSelectorFromString("copyPropertyForKey:"), with: "StatusInfo")?.takeUnretainedValue()
print(v.map { "\($0)" } ?? "nil")
