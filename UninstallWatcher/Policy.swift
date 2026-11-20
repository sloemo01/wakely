// UninstallWatcherPolicy — the pure decisions behind the deletion watcher.
//
// The watcher is a small per-user launchd agent whose binary lives OUTSIDE
// the app bundle (~/Library/Application Support/Wakely). That is the whole
// point: when the user drags Wakely.app to the Trash, nothing inside the
// bundle can run anymore, so the only way "delete the app wipes everything"
// can work is a survivor that notices the app is gone and cleans up after it.
//
// Everything in this file is deterministic so it can be tested without
// launchd, the file system or a live process. The I/O (process scan, file
// probes, launchctl, defaults, tccutil) lives in UninstallWatcher/main.swift
// and UninstallWatcher/Presence.swift.
//
// Safety rule: the watcher only wipes after the app has been absent for a
// bounded number of consecutive checks. An app update swaps the bundle in
// seconds and the updater relaunches the app within its wait cap, so a
// multi-minute grace makes a false wipe impossible in practice. The checks
// also require that NO Wakely process is running and that NONE of the
// candidate install locations exists.

import Foundation

enum UninstallWatcherDecision: Equatable {
    /// Keep observing; the app is present, running, or still inside its grace.
    case keepWatching
    /// The app has been gone long enough: remove every Wakely leftover.
    case wipe
}

enum UninstallWatcherPolicy {
    static let bundleID = "dev.wakely.app"

    /// Label and plist name of the watcher agent itself. Distinct from the
    /// crash-recovery agent (dev.wakely.agent) on purpose: that one lives
    /// inside the bundle for signed builds and cannot survive deletion.
    static let agentLabel = "dev.wakely.uninstall-watcher"
    static let agentPlistName = "dev.wakely.uninstall-watcher.plist"

    /// Name of the install-location record the app publishes on every launch.
    /// Mirrored by Sources/InstallRecord.swift; the test suite checks agreement.
    static let installRecordFileName = "install.json"

    /// Support-directory file names the cleanup removes wholesale. The whole
    /// directory goes, so this list is documentation, not deletion logic.
    static let supportDirectoryName = "Wakely"

    // MARK: - Cadence

    /// How often the watcher probes. 20 s keeps the post-delete cleanup
    /// prompt enough without waking the disk constantly.
    static let pollInterval: TimeInterval = 20

    /// Consecutive absent probes before the wipe. 6 × 20 s = 2 minutes,
    /// far longer than an update swap plus relaunch wait (seconds to ~30 s).
    static let absentChecksBeforeWipe = 6

    /// The privileged helper polls more slowly and waits longer: it is root,
    /// a false wipe there is costlier, and it has nothing to do until a
    /// reboot anyway (its binary lives in the bundle for signed builds).
    static let daemonPollInterval: TimeInterval = 60
    static let daemonAbsentChecksBeforeWipe = 5

    /// Decide from the three facts one probe can establish. Pure: the caller
    /// does the process scan and path probes.
    static func decide(appRunning: Bool,
                       appCandidatesPresent: Bool,
                       consecutiveAbsentChecks: Int,
                       requiredAbsentChecks: Int = absentChecksBeforeWipe) -> UninstallWatcherDecision {
        guard !appRunning, !appCandidatesPresent else { return .keepWatching }
        guard consecutiveAbsentChecks >= requiredAbsentChecks else { return .keepWatching }
        return .wipe
    }

    // MARK: - Test-only environment seams

    /// Absolute-path overrides honoured ONLY when set explicitly, mirroring
    /// the crash watchdog's WAKELY_SUPPORT_DIR seam. They let the live test
    /// script run the real binary against a throwaway directory with a short
    /// grace; an installed plist never sets them.
    static func pollIntervalFromEnvironment(_ environment: [String: String]) -> TimeInterval {
        guard let raw = environment["WAKELY_UNINSTALL_WATCHER_POLL_SECONDS"],
              let value = TimeInterval(raw), value >= 1, value <= 3600 else {
            return pollInterval
        }
        return value
    }

    static func absentChecksFromEnvironment(_ environment: [String: String]) -> Int {
        guard let raw = environment["WAKELY_UNINSTALL_WATCHER_ABSENT_CHECKS"],
              let value = Int(raw), value >= 1, value <= 1000 else {
            return absentChecksBeforeWipe
        }
        return value
    }
}
