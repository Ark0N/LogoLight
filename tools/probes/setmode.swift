import Foundation
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let client = (NSClassFromString("BrightnessSystemClient") as! NSObject.Type).init()

func get(_ key: String) -> Any? { client.perform(NSSelectorFromString("copyPropertyForKey:"), with: key)?.takeUnretainedValue() }
typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
let setSel = NSSelectorFromString("setProperty:forKey:")
let setImp = unsafeBitCast(client.method(for: setSel), to: SetFn.self)
func set(_ value: AnyObject, _ key: String) -> Bool { setImp(client, setSel, value, key as NSString) }

func led() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg"); p.arguments = ["-r", "-n", "bklb-backlight@0", "-w0"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let enabled = s.contains("\"enabled\" = Yes") ? "on " : "off"
    let hi = s.range(of: #""high-period" = (\d+)"#, options: .regularExpression).map { String(s[$0]).split(separator: " ").last! } ?? "?"
    return "led=\(enabled) hi=\(hi)"
}
func state() -> String {
    let st = get("LEPWMState") as? [String: Any] ?? [:]
    return "mode=\(get("LEBacklightMode") ?? "nil") factor=\(st["Factor"] ?? "?") final=\(st["FinalNits"] ?? "?") applied=\(st["AppliedNits"] ?? "?") \(led())"
}

let target = Int(CommandLine.arguments[1])!
print("before        \(state())")
let ok = set(NSNumber(value: target), "LEBacklightMode")
print("set(\(target)) -> \(ok)")
let t0 = Date()
for _ in 0..<15 { Thread.sleep(forTimeInterval: 0.1); print(String(format: "  +%.1fs  ", Date().timeIntervalSince(t0)) + state()) }
