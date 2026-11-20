// UninstallWatcherInstaller — keeps the deletion sentinel installed.
//
// Unlike the crash watchdog (SMAppService agent for signed builds, manual
// LaunchAgent for ad-hoc ones), the uninstall watcher ALWAYS installs as a
// plain per-user LaunchAgent whose binary is copied OUTSIDE the bundle into
// ~/Library/Application Support/Wakely. That is the only way it can still
// run after the user drags Wakely.app to the Trash — the thing it exists to
// detect.
//
// Safe to call on every launch: only changed bytes are replaced, and the job
// is only re-bootstrapped when the plist or binary actually changed, so a
// running watcher is never killed for no reason.

import Foundation

enum UninstallWatcherInstaller {
    // Mirrored from UninstallWatcher/Policy.swift (agentLabel /
    // agentPlistName); Tests/test_uninstall_watcher.py keeps them in agreement.
    static let label = "dev.wakely.uninstall-watcher"
    static let plistName = "dev.wakely.uninstall-watcher.plist"

    static func supportDirectory() -> URL { SupportPaths.baseDirectory }

    static func installedWatcherURL() -> URL {
        supportDirectory().appendingPathComponent("WakelyUninstallWatcher", isDirectory: false)
    }

    static func launchAgentURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistName)")
    }

    /// Copy the watcher binary and (re)load the LaunchAgent. Returns true
    /// when the job is loaded afterwards. Never prompts and never blocks:
    /// failures are logged and the app launches regardless — a missing
    /// watcher only means deletion cleanup won't happen automatically.
    @discardableResult
    static func installIfNeeded() -> Bool {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WakelyUninstallWatcher")
        guard let data = try? Data(contentsOf: source), !data.isEmpty else {
            Diagnostics.log("uninstall watcher: executable missing from the bundle")
            return false
        }
        let support = supportDirectory()
        let destination = installedWatcherURL()
        var binaryChanged = false
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let existing = try? Data(contentsOf: destination)
            if existing != data {
                binaryChanged = true
                let temporary = support.appendingPathComponent("WakelyUninstallWatcher.new")
                try data.write(to: temporary, options: .atomic)
                _ = try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
        } catch {
            Diagnostics.log("uninstall watcher: could not install binary: \(error.localizedDescription)")
            return false
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [destination.path],
            "RunAtLoad": true,
            // Always-on: the watcher must still be running while the app is
            // gone, which is exactly when it has work to do.
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 10,
        ]
        let plistURL = launchAgentURL()
        var plistRewritten = false
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            // Skip the rewrite when nothing changed: bootstrapping an
            // already-loaded job would bounce the watcher for no reason.
            if (try? Data(contentsOf: plistURL)) != data {
                plistRewritten = true
                try data.write(to: plistURL, options: .atomic)
                _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
                _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
                _ = runLaunchctl(["enable", "gui/\(getuid())/\(label)"])
                _ = runLaunchctl(["kickstart", "gui/\(getuid())/\(label)"])
            }
        } catch {
            Diagnostics.log("uninstall watcher: could not write plist: \(error.localizedDescription)")
            return false
        }

        // Recovery: the plist comparison above only rewrites on change, so a
        // job that failed to bootstrap earlier (or was unloaded externally)
        // would otherwise stay unloaded forever. And when only the binary
        // changed, the running watcher still executes the old code — restart
        // it so the update takes effect without waiting for logout.
        if !plistRewritten {
            if !isLoaded() {
                _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
                _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
                _ = runLaunchctl(["enable", "gui/\(getuid())/\(label)"])
                _ = runLaunchctl(["kickstart", "gui/\(getuid())/\(label)"])
            } else if binaryChanged {
                _ = runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
            }
        }

        let loaded = isLoaded()
        Diagnostics.log("uninstall watcher: \(loaded ? "loaded" : "not loaded") at \(plistURL.path)")
        return loaded
    }

    /// Retire the watcher. Used by Delete Wakely, which removes everything
    /// itself; leaving the watcher running would race the uninstaller.
    static func uninstall() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: launchAgentURL())
        try? FileManager.default.removeItem(at: installedWatcherURL())
    }

    static func isLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        // Never an unread Pipe: `launchctl print` can write more than a pipe
        // holds, then blocks on the write while waitUntilExit waits forever,
        // which hung app launch before the menu bar appeared.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
        // Never an unread Pipe: `launchctl print` can write more than a pipe
        // holds, then blocks on the write while waitUntilExit waits forever,
        // which hung app launch before the menu bar appeared.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
