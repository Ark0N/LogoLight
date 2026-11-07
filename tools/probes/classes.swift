import Foundation
import ObjectiveC

dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
var count: UInt32 = 0
let image = "/System/Library/PrivateFrameworks/CoreBrightness.framework/Versions/A/CoreBrightness"
guard let names = objc_copyClassNamesForImage(image, &count) else { print("no classes"); exit(1) }
let all = (0..<Int(count)).map { String(cString: names[$0]) }.sorted()
print("\(all.count) classes")
print(all.filter { $0.contains("Client") || $0.contains("LE") || $0.hasPrefix("CBLE") }.joined(separator: "\n"))
