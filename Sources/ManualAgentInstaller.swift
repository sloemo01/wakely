// Manual per-user watchdog installation for ad-hoc builds.
//
// SMAppService agents are validated by BackgroundTaskManagement and rejected
// for an ad-hoc app. This installs the same watchdog as an ordinary user
// LaunchAgent instead: no Apple ID, no administrator prompt, no BTM.
import Foundation

enum ManualAgentInstaller {
    static let label = HelperService.agentLabel
    static let plistName = HelperService.agentPlistName

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Wakely", isDirectory: true)
    }

    static func installedWatchdogURL() -> URL {
        supportDirectory().appendingPathComponent("WakelyWatchdog")
    }

    static func launchAgentURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistName)")
    }

    /// Copy the watchdog and load the user agent. Safe to call on every launch:
    /// only changed bytes are replaced, and an already-loaded job is restarted
    /// without `-k` so a live watcher is not killed unnecessarily.
    @discardableResult
    static func installIfNeeded() -> Bool {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WakelyWatchdog")
        guard let data = try? Data(contentsOf: source), !data.isEmpty else {
            Diagnostics.log("manual login agent: watchdog executable missing")
            return false
        }
        let support = supportDirectory()
        let destination = installedWatchdogURL()
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let existing = try? Data(contentsOf: destination)
            if existing != data {
                let temporary = support.appendingPathComponent("WakelyWatchdog.new")
                try data.write(to: temporary, options: .atomic)
                _ = try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
        } catch {
            Diagnostics.log("manual login agent: could not install watchdog: \(error.localizedDescription)")
            return false
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [destination.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "ThrottleInterval": 10,
        ]
        let plistURL = launchAgentURL()
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            Diagnostics.log("manual login agent: could not write plist: \(error.localizedDescription)")
            return false
        }

        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(label)"
        _ = runLaunchctl(["bootout", target])
        _ = runLaunchctl(["bootstrap", domain, plistURL.path])
        _ = runLaunchctl(["enable", target])
        _ = runLaunchctl(["kickstart", target])
        let loaded = isLoaded()
        Diagnostics.log("manual login agent: \(loaded ? "loaded" : "not loaded") at \(plistURL.path)")
        return loaded
    }

    static func kickstart() {
        let target = "gui/\(getuid())/\(label)"
        _ = runLaunchctl(["kickstart", target])
    }

    static func isLoaded() -> Bool {
        let target = "gui/\(getuid())/\(label)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", target]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
