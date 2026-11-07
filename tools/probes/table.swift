import Foundation
import MachO
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
var slide = 0
for i in 0..<_dyld_image_count() where String(cString: _dyld_get_image_name(i)).hasSuffix("/CoreBrightness") { slide = _dyld_get_image_vmaddr_slide(i) }
for arg in CommandLine.arguments.dropFirst() {
    let base = UnsafePointer<UInt>(bitPattern: Int(arg, radix: 16)! + slide)!
    let names = (0..<7).map { i -> String in
        let raw = base[i] & 0x0000_00FF_FFFF_FFFF  // strip any pointer-auth bits
        return "\(i)=\(unsafeBitCast(UnsafeRawPointer(bitPattern: UInt(raw))!, to: NSString.self))"
    }
    print("\(arg): \(names.joined(separator: " "))")
}
