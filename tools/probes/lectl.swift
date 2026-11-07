import Foundation
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let client = (NSClassFromString("BrightnessSystemClient") as! NSObject.Type).init()
func get(_ key: String) -> Any? { client.perform(NSSelectorFromString("copyPropertyForKey:"), with: key)?.takeUnretainedValue() }
typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
let setSel = NSSelectorFromString("setProperty:forKey:")
let setImp = unsafeBitCast(client.method(for: setSel), to: SetFn.self)

func pwm() -> (Bool, Int) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg"); p.arguments = ["-r", "-n", "bklb-backlight@0", "-w0"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let hi = s.range(of: #""high-period" = (\d+)"#, options: .regularExpression).map { Int(s[$0].split(separator: " ").last!)! } ?? -1
    return (s.contains("\"enabled\" = Yes"), hi)
}
func state() -> String {
    let st = get("LEPWMState") as? [String: Any] ?? [:]
    let (on, hi) = pwm()
    let bar = on ? String(repeating: "█", count: max(0, hi / 20)) : "(off)"
    return "factor=\(st["Factor"] ?? "?") final=\(st["FinalNits"] ?? "?") pwm=\(on ? "\(hi)" : "off") \(bar)"
}
// args: key=value[@seconds] ...   e.g. DisplayLogicalState=3@3 DisplayLogicalState=4@3
print("start          \(state())")
for step in CommandLine.arguments.dropFirst() {
    let parts = step.split(separator: "@")
    let kv = parts[0].split(separator: "=")
    let seconds = parts.count > 1 ? Double(parts[1])! : 2
    let value: AnyObject = kv[1].contains(".") ? NSNumber(value: Double(kv[1])!) : NSNumber(value: Int(kv[1])!)
    let ok = setImp(client, setSel, value, String(kv[0]) as NSString)
    print("set \(kv[0])=\(kv[1]) -> \(ok)")
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        Thread.sleep(forTimeInterval: 0.1)
        print(String(format: "  +%.1fs ", Date().timeIntervalSince(t0)) + state())
    }
}
