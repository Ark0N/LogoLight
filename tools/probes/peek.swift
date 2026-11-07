import Foundation
import MachO
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
var slide = 0
for i in 0..<_dyld_image_count() where String(cString: _dyld_get_image_name(i)).hasSuffix("/CoreBrightness") { slide = _dyld_get_image_vmaddr_slide(i) }
let pc = Int(CommandLine.arguments[1], radix: 16)! + slide
let p = UnsafePointer<UInt32>(bitPattern: pc)!
print((0..<6).map { String(format: "%08x", p[$0]) }.joined(separator: " "))
