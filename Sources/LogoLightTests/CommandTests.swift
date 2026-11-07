import Foundation
@testable import LogoLightCore

@MainActor
func commandTests(_ t: TestHarness) {
    print("\nCommands")

    t.test("turning off runs exactly the command from Apple's support article") {
        t.expectEqual(CoreBrightnessSetting.command(for: .off).shellString,
                      "/usr/bin/defaults write com.apple.CoreBrightness LEBacklightMode -int 0")
    }

    t.test("turning on runs exactly the command from Apple's support article") {
        t.expectEqual(CoreBrightnessSetting.command(for: .on).shellString,
                      "/usr/bin/defaults delete com.apple.CoreBrightness LEBacklightMode")
    }

    t.test("quotes shell words that need it") {
        let command = PrivilegedCommand(executable: "/bin/echo", arguments: ["it's", "a b", "", "$HOME", "plain-1.0"])
        t.expectEqual(command.shellString, #"/bin/echo 'it'\''s' 'a b' '' '$HOME' plain-1.0"#)
    }

    t.test("quoted words survive a round trip through /bin/sh") {
        let tricky = ["it's", "a \"b\"", "$(whoami)", "back\\slash", "new\nline"]
        let script = PrivilegedCommand(executable: "/usr/bin/printf", arguments: ["%s\\0"] + tricky).shellString
        let result = runSync("/bin/sh", ["-c", script])
        t.expectEqual(result.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init), tricky)
    }

    t.test("recognises defaults' 'nothing to delete' errors as benign") {
        let benign = [
            // macOS 27
            "Error: Could not find key 'LEBacklightMode' in domain 'com.apple.CoreBrightness'.\nDefaults have not been changed.",
            "Error: Domain 'com.apple.CoreBrightness' not found.\nDefaults have not been changed.",
            // Earlier macOS
            "The domain/default pair of (com.apple.CoreBrightness, LEBacklightMode) does not exist",
            "Domain (com.apple.CoreBrightness) not found.",
        ]
        for message in benign {
            t.expect(CoreBrightnessSetting.isMissingKeyError(LogoLightError.commandFailed(exitCode: 1, message: message)),
                     message)
        }
    }

    t.test("treats other failures as real errors") {
        let failures = [
            "sudo: a password is required",
            "sudo: /usr/bin/defaults: command not found",
            "Error: Domain 'com.example.other' not found.",
        ]
        for message in failures {
            t.expect(!CoreBrightnessSetting.isMissingKeyError(LogoLightError.commandFailed(exitCode: 1, message: message)),
                     message)
        }
        t.expect(!CoreBrightnessSetting.isMissingKeyError(LogoLightError.cancelled))
    }

    t.test("escapes AppleScript string literals") {
        t.expectEqual(AppleScriptAdminShell.literal(#"say "hi" \ bye"#), #""say \"hi\" \\ bye""#)
    }

    t.test("generated admin AppleScripts compile") {
        // Compiling checks the escaping without running anything or showing a dialog.
        let rule = try PasswordlessRule(userName: "lee")
        for script in [CoreBrightnessSetting.command(for: .off).shellString, rule.installScript, PasswordlessRule.removeScript,
                       rule.installScript(thenRunning: CoreBrightnessSetting.command(for: .on))] {
            let source = AppleScriptAdminShell.source(script: script, prompt: #"A "quoted" prompt"#)
            var error: NSDictionary?
            let compiled = NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false
            t.expect(compiled, "\(error ?? [:])")
        }
    }
}

@MainActor
func passwordlessRuleTests(_ t: TestHarness) {
    print("\nPassword-free rule")

    t.test("accepts normal macOS short names") {
        for name in ["lee", "john.appleseed", "_svc", "user-2", "Jane"] {
            t.expect((try? PasswordlessRule(userName: name)) != nil, name)
        }
    }

    t.test("rejects names that could inject sudoers syntax") {
        for name in ["", "-lee", "1lee", "lee smith", "lee'", "lee,root", "lee\nALL", "%admin", "lee ALL=(ALL) ALL"] {
            t.expectThrows { _ = try PasswordlessRule(userName: name) }
        }
    }

    t.test("allows only the two logo commands, as root, without a password") {
        let rule = try PasswordlessRule(userName: "lee")
        t.expectEqual(rule.lines.last!,
                      "lee ALL = (root) NOPASSWD: "
                          + "/usr/bin/defaults write com.apple.CoreBrightness LEBacklightMode -int 0, "
                          + "/usr/bin/defaults delete com.apple.CoreBrightness LEBacklightMode")
    }

    t.test("escapes sudoers special characters in arguments") {
        let command = PrivilegedCommand(executable: "/bin/x", arguments: ["a,b", "c:d", "e=f", #"g\h"#])
        t.expectEqual(PasswordlessRule.sudoersCommand(command), #"/bin/x a\,b c\:d e\=f g\\h"#)
    }

    t.test("the generated rule passes visudo") {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("logolight-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try PasswordlessRule(userName: "lee").contents.write(to: file, atomically: true, encoding: .utf8)
        t.expectEqual(runSyncStatus("/usr/sbin/visudo", ["-c", "-q", "-f", file.path]), 0)
    }

    t.test("the install script is valid sh and validates before installing") {
        let script = try PasswordlessRule(userName: "lee").installScript
        t.expectEqual(runSyncStatus("/bin/sh", ["-n", "-c", script]), 0)
        let visudo = script.range(of: "/usr/sbin/visudo")!.lowerBound
        let install = script.range(of: "/usr/bin/install")!.lowerBound
        t.expect(visudo < install, "visudo must run before install")
        t.expect(script.contains("-m 0440 -o root -g wheel"), "rule file must be root-owned and read-only")
        t.expect(script.contains(" && "), "each step must stop the script if it fails")
    }

    t.test("installing the rule then running a command is valid sh, and ends with the command") {
        let command = CoreBrightnessSetting.command(for: .off)
        let script = try PasswordlessRule(userName: "lee").installScript(thenRunning: command)
        t.expectEqual(runSyncStatus("/bin/sh", ["-n", "-c", script]), 0)
        t.expect(script.hasSuffix("; " + command.shellString), script)
    }

    t.test("a script that installs the rule first gives the command's result, whatever the install did") {
        // Stand-ins: an install that's noisy, changes the umask and fails, then a command that fails.
        let script = PasswordlessRule.script(installing: "echo noise; echo noise >&2; umask 077; exit 1",
                                             thenRunning: "umask; echo out; echo err >&2; exit 3")
        let result = runSyncAll("/bin/sh", ["-c", script])
        t.expectEqual(result.status, 3)
        t.expectEqual(result.output, runSync("/bin/sh", ["-c", "umask"]) + "out\n")
        t.expectEqual(result.error, "err\n")
    }

    t.test("the install script writes exactly the rule's contents") {
        // Run only the printf step, redirected to a scratch file, and compare.
        let rule = try PasswordlessRule(userName: "lee")
        let printStep = rule.installScript.components(separatedBy: " && ")
            .first { $0.hasPrefix("/usr/bin/printf") }!
            .replacingOccurrences(of: #" > "$tmp/rule""#, with: "")
        t.expectEqual(runSync("/bin/sh", ["-c", printStep]), rule.contents)
    }
}

// MARK: - Helpers

func runSync(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Runs a program and returns its exit status, standard output and standard error.
func runSyncAll(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe(), error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try? process.run()
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
}

func runSyncStatus(_ executable: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
