import Foundation
import MachO
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
var slide = 0
for i in 0..<_dyld_image_count() where String(cString: _dyld_get_image_name(i)).hasSuffix("/CoreBrightness") {
    slide = _dyld_get_image_vmaddr_slide(i)
}
for arg in CommandLine.arguments.dropFirst() {
    let addr = Int(arg, radix: 16)! + slide
    let object = unsafeBitCast(UnsafeRawPointer(bitPattern: addr)!, to: NSString.self)
    print("\(arg) -> \"\(object)\"")
}
