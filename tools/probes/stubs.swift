import Foundation
import MachO
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
var slide = 0
for i in 0..<_dyld_image_count() where String(cString: _dyld_get_image_name(i)).hasSuffix("/CoreBrightness") { slide = _dyld_get_image_vmaddr_slide(i) }
func sext(_ v: Int, _ bits: Int) -> Int { (v << (64 - bits)) >> (64 - bits) }
for arg in CommandLine.arguments.dropFirst() {
    let pc = Int(arg.replacingOccurrences(of: "0x", with: ""), radix: 16)! + slide
    let insns = UnsafePointer<UInt32>(bitPattern: pc)!
    let adrp = Int(insns[0]), add = Int(insns[1])
    guard adrp & 0x9F00_001F == 0x9000_0001, add & 0xFF80_03FF == 0x9100_0021 else { print("\(arg): (not a msgSend stub)"); continue }
    let page = (pc & ~0xFFF) + (sext((((adrp >> 5) & 0x7FFFF) << 2) | ((adrp >> 29) & 3), 21) << 12)
    let imm = ((add >> 10) & 0xFFF) << (((add >> 22) & 1) * 12)
    print("\(arg): \(String(cString: UnsafePointer<CChar>(bitPattern: page + imm)!))")
}
