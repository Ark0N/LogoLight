import Foundation
import ObjectiveC

dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
for name in CommandLine.arguments.dropFirst() {
    guard let cls: AnyClass = NSClassFromString(name) else { print("!! \(name) missing"); continue }
    var n: UInt32 = 0
    let methods = class_copyMethodList(cls, &n)
    let sels = (0..<Int(n)).map { NSStringFromSelector(method_getName(methods![$0])) }.sorted()
    print("== \(name) (\(sels.count))"); print(sels.joined(separator: "  "))
}
