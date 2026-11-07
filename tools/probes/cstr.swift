import Foundation
import MachO
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
var slide = 0
for i in 0..<_dyld_image_count() where String(cString: _dyld_get_image_name(i)).hasSuffix("/CoreBrightness") {
    slide = _dyld_get_image_vmaddr_slide(i)
}
print("slide: 0x\(String(slide, radix: 16))")
for arg in CommandLine.arguments.dropFirst() {
    let parts = arg.split(separator: ":")
    let addr = Int(parts[0], radix: 16)! + slide
    let len = Int(parts[1])!
    let ptr = UnsafePointer<UInt8>(bitPattern: addr)!
    print("\(parts[0]) -> \"\(String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self))\"")
}
