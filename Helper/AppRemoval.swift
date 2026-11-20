// AppRemoval — the privileged helper's own deletion sentinel.
//
// The daemon's binary lives inside the app bundle (SMAppService daemon) or
// in /Library/PrivilegedHelperTools (administrator install). Either way it
// keeps running after the user trashes Wakely.app — until logout — and its
// LaunchDaemon plist, peer config and root-owned data would survive forever.
// Nehal's rule: deleting the app wipes the helper too. So the daemon polls
// for the app's absence on the same evidence the user-level watcher uses
// (UninstallWatcher/Presence.swift, shared) and, after a longer grace,
// removes its own root-level footprint and exits.
//
// Order is safety-critical: every file is removed FIRST, and the self-bootout
// is LAST, because bootout terminates this process. Until the bootout, the
// daemon still serves the app normally; the app is gone, so there is no
// client to interrupt.
//
// The daemon polls slowly (60 s) and waits longer (5 checks) than the user
// watcher: it is root, a false wipe is costlier, and its only irrecoverable
// loss is the helper itself, which the app reinstalls on next launch (with
// the usual administrator prompt for privileged components).

import Darwin
import Foundation

/// Root-level footprint of one helper install. Both install paths (SMAppService
/// daemon and the administrator fallback) share the plist name and label; the
/// administrator path additionally owns the PrivilegedHelperTools binary and
/// peer config. Removing absent files is a no-op, so one list covers both.
enum HelperAppRemoval {
    static let daemonLabel = HelperService.daemonLabel
    static let daemonPlistPath = "/Library/LaunchDaemons/" + HelperService.daemonPlistName
    static let installedHelperPath = "/Library/PrivilegedHelperTools/" + HelperService.daemonLabel
    static let peerConfigPath = "/Library/PrivilegedHelperTools/dev.wakely.helper.peer"
    static let rootDataPath = "/Library/Application Support/dev.wakely.helper"

    /// The console user's home. A LaunchDaemon's own home is /var/root, which
    /// would never see the user's install record or ~/Applications copy, so
    /// the probes must target the person at the console. /dev/console is owned
    /// by that user; macOS keeps homes at /Users/<name>.
    static func consoleHomeDirectory() -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        process.arguments = ["-f", "%Su", "/dev/console"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let _ = try? process.run() else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let name = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, !name.contains("/") else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        let home = URL(fileURLWithPath: "/Users/\(name)", isDirectory: true)
        return FileManager.default.fileExists(atPath: home.path)
            ? home
            : FileManager.default.homeDirectoryForCurrentUser
    }

    /// User-level install record, read as root. Root can read the user's
    /// Application Support; a missing record just means no recorded path.
    static func userSupportDirectory(homeDirectory: URL) -> URL {
        return homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(UninstallWatcherPolicy.supportDirectoryName, isDirectory: true)
    }

    /// One probe: is the app running or present anywhere it could be installed?
    static func appPresent(homeDirectory: URL) -> Bool {
        let support = userSupportDirectory(homeDirectory: homeDirectory)
        let recorded = WakelyPresence.recordedAppPath(supportDirectory: support)
        let candidates = WakelyPresence.candidateAppPaths(recordedPath: recorded,
                                                          homeDirectory: homeDirectory)
        // Spotlight covers moves and renames, exactly like the user watcher.
        return WakelyPresence.appIsRunning()
            || WakelyPresence.anyCandidateExists(candidates)
            || WakelyPresence.spotlightFindsApp(homeDirectory: homeDirectory)
    }

    /// The watch loop body: poll, count consecutive absences, wipe at the
    /// policy's daemon threshold. Runs on a background queue; never touches
    /// the XPC listener's thread. The console home is re-read every poll so a
    /// different user logging in is probed correctly.
    static func watchUntilAppReturnsOrWipe() {
        let poll = UninstallWatcherPolicy.daemonPollInterval
        let required = UninstallWatcherPolicy.daemonAbsentChecksBeforeWipe
        var absentStreak = 0

        while true {
            Thread.sleep(forTimeInterval: poll)
            let home = consoleHomeDirectory()
            if appPresent(homeDirectory: home) {
                if absentStreak != 0 {
                    HelperLog.write("app is present; absence streak reset")
                }
                absentStreak = 0
                continue
            }
            absentStreak += 1
            HelperLog.write("app absent (\(absentStreak)/\(required) checks)")
            guard absentStreak >= required else { continue }

            wipeAndExit()
            // wipeAndExit ends in exit(0); this is unreachable.
            return
        }
    }

    /// Remove the daemon's whole root-level footprint, then bootout self.
    /// Never returns: the bootout (or the exit fallback) ends the process.
    static func wipeAndExit() {
        HelperLog.write("app is gone; removing the helper's root-level footprint")

        let manager = FileManager.default
        for path in [daemonPlistPath, installedHelperPath, peerConfigPath] {
            try? manager.removeItem(atPath: path)
        }
        try? manager.removeItem(atPath: rootDataPath)

        // Restore any persistent settings this daemon still holds leases for?
        // No: the app restores its settings before Delete Wakely, and a manual
        // Trash has no client left to ask. The daemon's leases are exactly the
        // values it changed; leaving them is the same state a crash leaves,
        // which the watchdog's session restore already covers on next install.

        HelperLog.write("footprint removed; booting out \(daemonLabel)")
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "system/\(daemonLabel)"]
        bootout.standardOutput = FileHandle.nullDevice
        bootout.standardError = FileHandle.nullDevice
        try? bootout.run()
        bootout.waitUntilExit()
        // If bootout somehow did not kill us (job already gone), leave anyway:
        // the plist and binary are deleted, so a launchd restart is impossible
        // and an idle daemon with no app is pure cost.
        exit(0)
    }
}
