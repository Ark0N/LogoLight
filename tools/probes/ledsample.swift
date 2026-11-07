import Foundation
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let client = (NSClassFromString("BrightnessSystemClient") as! NSObject.Type).init()
func factor() -> Double {
    let v = client.perform(NSSelectorFromString("copyPropertyForKey:"), with: "LEPWMState")?.takeRetainedValue() as? [String: Any]
    return (v?["Factor"] as? NSNumber)?.doubleValue ?? -1
}
func pwm(_ name: String) -> (Bool, Double) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg"); p.arguments = ["-r", "-n", name, "-w0"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    func num(_ k: String) -> Double { s.range(of: "\"\(k)\" = (\\d+)", options: .regularExpression).map { Double(s[$0].split(separator: " ").last!)! } ?? -1 }
    let hi = num("high-period"), lo = num("low-period")
    return (s.contains("\"enabled\" = Yes"), hi + lo > 0 ? hi / (hi + lo) : -1)
}
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "9")!
let t0 = Date()
while Date().timeIntervalSince(t0) < seconds {
    let f = factor(); let k = pwm("kbd-backlight@0"); let l = pwm("bklb-backlight@0")
    print(String(format: "+%4.1fs  logoFactor=%.3f  logoLED=%@ %5.1f%%   keyboardLED=%@ %5.1f%%", Date().timeIntervalSince(t0), f, l.0 ? "on " : "off", l.1 * 100, k.0 ? "on " : "off", k.1 * 100))
    Thread.sleep(forTimeInterval: 0.2)
}
