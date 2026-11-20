// WakelyUninstallWatcher — the deletion sentinel.
//
// A per-user launchd agent whose binary lives OUTSIDE the app bundle, so it
// survives the user dragging Wakely.app to the Trash. It polls until the app
// has been absent (not running, not at any candidate install location) for
// the policy's grace window, then removes everything Wakely left behind:
//
//   user level (this process):
//     - TCC grants            (tccutil reset All dev.wakely.app)
//     - defaults              (defaults delete + Preferences plist)
//     - ~/Library/Application Support/Wakely   (settings, components, screens)
//     - caches / HTTP storage / saved state
//     - the crash-watchdog agent plist + job (dev.wakely.agent)
//     - this agent's own plist and job
//
//   root level is handled by the privileged helper itself
//   (Helper/AppRemoval.swift): its LaunchDaemon plist, PrivilegedHelperTools
//   binary and peer config, root-owned data, and its own job.
//
// What this cannot remove: the BackgroundTaskManagement entries for the
// SMAppService login item and crash agent. Those belong to the app bundle;
// the in-app Settings > General > Delete Wakely flow unregisters them while
// the bundle still exists. Once the bundle is gone macOS drops the dead
// entries on its own.
//
// launchd contract: RunAtLoad + KeepAlive (always). The job only exits after
// a completed wipe (0) or on a signal; it bootouts itself before exiting so
// KeepAlive does not resurrect it. Test seams: WAKELY_UNINSTALL_WATCHER_POLL_SECONDS
// and WAKELY_UNINSTALL_WATCHER_ABSENT_CHECKS shorten the grace for the live
// test; WAKELY_SUPPORT_DIR redirects the support directory for tests, exactly
// like the crash watchdog's seam.

import Darwin
import Foundation

private let logFileName = "uninstall-watcher.log"

// MARK: - Locations

/// Same resolution order as the app and the crash watchdog. The test-only
/// WAKELY_SUPPORT_DIR override must be absolute; a relative value is ignored.
private func supportDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["WAKELY_SUPPORT_DIR"],
       override.hasPrefix("/") {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("Wakely", isDirectory: true)
}

private func logLine(_ text: String) {
    let directory = supportDirectory()
    try? FileManager.default.createDirectory(at: directory,
                                             withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let file = directory.appendingPathComponent(logFileName)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(text)\n"
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: file, options: .atomic)
    }
}

// MARK: - Cleanup primitives

@discardableResult
private func run(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
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

private func removeItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        logLine("could not remove \(url.path): \(error.localizedDescription)")
    }
}

// MARK: - The wipe

/// Remove every user-level Wakely leftover, then retire this agent.
///
/// Order matters: file removals happen while this process is still alive
/// (its binary sits inside the support directory being deleted, which is
/// safe on macOS — unlinking a running executable keeps the inode), and the
/// self-bootout is LAST so KeepAlive cannot restart a half-cleaned agent.
private func wipeEverything() -> Int32 {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let library = home.appendingPathComponent("Library", isDirectory: true)
    let uid = getuid()

    logLine("app is gone; wiping every user-level Wakely leftover")

    // macOS privacy grants (Accessibility, Screen Recording, ...).
    _ = run("/usr/bin/tccutil", ["reset", "All", UninstallWatcherPolicy.bundleID])

    // Persistent settings: this is what made a reinstall "remember" modules.
    _ = run("/usr/bin/defaults", ["delete", UninstallWatcherPolicy.bundleID])
    removeItem(library.appendingPathComponent("Preferences/\(UninstallWatcherPolicy.bundleID).plist"))

    // The crash-recovery agent (ad-hoc builds keep a plist here; signed builds
    // are booted out by label either way) and this agent's own plist. The
    // self-bootout is deliberately NOT here: it would kill this process
    // before the remaining removals ran. It is the last action below.
    _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/dev.wakely.agent"])
    removeItem(home.appendingPathComponent("Library/LaunchAgents/dev.wakely.agent.plist"))
    removeItem(home.appendingPathComponent("Library/LaunchAgents/\(UninstallWatcherPolicy.agentPlistName)"))

    // Caches, HTTP storage and saved window state.
    for path in ["Caches/\(UninstallWatcherPolicy.bundleID)",
                 "Caches/Wakely",
                 "HTTPStorages/\(UninstallWatcherPolicy.bundleID)",
                 "Saved Application State/\(UninstallWatcherPolicy.bundleID).savedState"] {
        removeItem(library.appendingPathComponent(path))
    }

    // The big one: settings, components, screens, diagnostics, the watchdog
    // binary and this binary. Deleted while running; the inode survives until
    // exit. No logLine after this: it would recreate the directory.
    logLine("removing \(supportDirectory().path) and retiring the watcher")
    removeItem(supportDirectory())

    // Last: bootout kills this process (KeepAlive must not resurrect it), so
    // nothing may run after this line.
    _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(UninstallWatcherPolicy.agentLabel)"])
    return 0
}

// MARK: - Watch loop

private func runWatcher() -> Int32 {
    let environment = ProcessInfo.processInfo.environment
    let poll = UninstallWatcherPolicy.pollIntervalFromEnvironment(environment)
    let requiredAbsent = UninstallWatcherPolicy.absentChecksFromEnvironment(environment)
    let home = FileManager.default.homeDirectoryForCurrentUser

    var absentStreak = 0
    var announced = false
    var blockedLogged = false

    while true {
        Thread.sleep(forTimeInterval: poll)

        let directory = supportDirectory()
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let recorded = WakelyPresence.recordedAppPath(supportDirectory: directory)
        let candidates = WakelyPresence.candidateAppPaths(recordedPath: recorded,
                                                          homeDirectory: home)
        let running = WakelyPresence.appIsRunning()
        // Spotlight covers what the path list cannot: the app moved to an
        // arbitrary folder or renamed (the bundle id survives both). The
        // Trash is not indexed, so a real deletion still reads as absent.
        let present = WakelyPresence.anyCandidateExists(candidates)
            || WakelyPresence.spotlightFindsApp(homeDirectory: home)
        // Absence is not proof of deletion: only a Wakely bundle found in the
        // Trash confirms the user actually deleted the app. A move into a
        // Spotlight-excluded folder, a missing index or a rename keeps data.
        let confirmed = WakelyPresence.trashContainsApp(homeDirectory: home)

        let decision = UninstallWatcherPolicy.decide(appRunning: running,
                                                     appCandidatesPresent: present,
                                                     deletionConfirmed: confirmed,
                                                     consecutiveAbsentChecks: absentStreak + 1,
                                                     requiredAbsentChecks: requiredAbsent)
        switch decision {
        case .keepWatching:
            if running || present {
                if absentStreak != 0 || announced {
                    logLine("app is present again; absence streak reset")
                }
                absentStreak = 0
                announced = false
                blockedLogged = false
            } else {
                absentStreak += 1
                let shown = min(absentStreak, requiredAbsent)
                if absentStreak >= requiredAbsent && !confirmed {
                    if !blockedLogged {
                        logLine("app absent for the full grace but no trashed Wakely.app found; keeping all data")
                        blockedLogged = true
                    }
                } else if !announced {
                    logLine("app absent (\(shown)/\(requiredAbsent) checks); wiping after the grace window once the Trash confirms the deletion")
                    announced = true
                } else {
                    logLine("app still absent (\(shown)/\(requiredAbsent) checks)")
                }
            }
        case .wipe:
            // Tell the root helper daemon (which cannot read the user's
            // Trash) that this wipe is Trash-confirmed, before user state
            // that might carry the news is removed.
            WakelyPresence.writeDeletionMarker()
            return wipeEverything()
        }
    }
}

exit(runWatcher())
