// Standalone tests for ComponentKitLauncher: compiled with
// Sources/ComponentKitLauncher.swift only, no app and no live preferences.
// Everything written here stays inside a temporary directory.

import Foundation

@main
struct ComponentKitLauncherTests {
    struct RunResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            standardError: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(
            "wakely-component-kit-launcher-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        expect(ComponentKitLauncher.kitVersion == "4", "kit version is 4")

        // A normal absolute helper path produces a sh launcher.
        let helperPath = "/Applications/Wakely.app/Contents/Helpers/wakely-component"
        guard let script = ComponentKitLauncher.script(helperPath: helperPath) else {
            fatalError("an absolute helper path must be accepted")
        }
        expect(script.hasPrefix("#!/bin/sh\n"), "script starts with a POSIX sh shebang")
        expect(script.contains("HELPER='\(helperPath)'"), "script names the helper exactly")
        expect(script.contains("exec \"$HELPER\" \"$@\""), "script passes every argument through")
        expect(script.contains("exit 2"), "missing-helper branch exits 2")
        expect(script.contains("was not found at $HELPER"), "missing-helper branch explains the problem")

        // Paths that cannot be embedded are refused.
        let rejected = [
            "",
            "Contents/Helpers/wakely-component",
            "wakely-component",
            "/tmp/wakely\ncomponent/wakely-component",
            "/tmp/wakely\u{0}component/wakely-component",
            "/Applications/Wakely.app/Contents/Helpers/other-helper",
            "/Applications/Wakely.app/wakely-component.bak",
            "/Applications/Wakely.app/wakely-component/other",
        ]
        for path in rejected {
            expect(ComponentKitLauncher.script(helperPath: path) == nil, "path must be rejected: \(path.debugDescription)")
        }

        // A single quote is escaped with the classic close/escaped-quote/open
        // sequence, and the result is still valid shell.
        let quotedPath = "/tmp/Wakely's Helper/wakely-component"
        guard let quotedScript = ComponentKitLauncher.script(helperPath: quotedPath) else {
            fatalError("a path containing a single quote must still be accepted")
        }
        expect(quotedScript.contains("HELPER='/tmp/Wakely'\\''s Helper/wakely-component'"),
               "single quotes are escaped for a single-quoted shell string")
        let quotedURL = temp.appendingPathComponent("quoted-launcher")
        try quotedScript.write(to: quotedURL, atomically: true, encoding: .utf8)
        let syntax = try run("/bin/sh", ["-n", quotedURL.path])
        expect(syntax.status == 0, "/bin/sh -n accepts the escaped script: \(syntax.standardError)")
        expect(syntax.standardError.isEmpty, "escaped script has no shell syntax errors")

        // Running the shim with a missing helper prints the explanation and
        // exits 2 rather than falling through to a confusing exec failure.
        let missingPath = temp.appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("wakely-component").path
        guard let missingScript = ComponentKitLauncher.script(helperPath: missingPath) else {
            fatalError("the missing-helper path is still a valid absolute path")
        }
        let missingURL = temp.appendingPathComponent("missing-launcher")
        try missingScript.write(to: missingURL, atomically: true, encoding: .utf8)
        let missingRun = try run("/bin/sh", [missingURL.path, "check", "demo"])
        expect(missingRun.status == 2, "missing helper exits 2, got \(missingRun.status)")
        expect(missingRun.standardError.contains("was not found at \(missingPath)"),
               "missing helper names the path: \(missingRun.standardError)")
        expect(missingRun.standardOutput.isEmpty, "missing helper writes only to stderr")

        // Arguments reach the helper unchanged, including spaces.
        let fakeDirectory = temp.appendingPathComponent("fake", isDirectory: true)
        try fm.createDirectory(at: fakeDirectory, withIntermediateDirectories: true)
        let fakeHelper = fakeDirectory.appendingPathComponent("wakely-component")
        try "#!/bin/sh\nprintf 'arg:%s\\n' \"$@\"\n".write(to: fakeHelper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHelper.path)
        guard let fakeScript = ComponentKitLauncher.script(helperPath: fakeHelper.path) else {
            fatalError("the fake helper path is valid")
        }
        let fakeURL = temp.appendingPathComponent("fake-launcher")
        try fakeScript.write(to: fakeURL, atomically: true, encoding: .utf8)
        let passed = try run("/bin/sh", [fakeURL.path, "check", "demo component", "--root", temp.path])
        expect(passed.status == 0, "the fake helper runs successfully")
        expect(passed.standardOutput == "arg:check\narg:demo component\narg:--root\narg:\(temp.path)\n",
               "arguments pass through with spaces intact: \(passed.standardOutput)")

        print("ComponentKitLauncher: path validation, quoting, missing helper and argument passthrough PASS")
    }
}
